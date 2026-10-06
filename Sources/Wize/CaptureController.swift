import AppKit
import AVFoundation
import ScreenCaptureKit

/// Screenshot / recording of one window. Only that window is captured (window-level capture), so Wize's
/// badge, bar, outline and toast are never in the image or video.
/// - Screenshot: Apple's `screencapture -l <window>` (what ⇧⌘4 → Space does), saved as PNG.
/// - Recording: ScreenCaptureKit stream of that window into an H.264 .mov.
/// Files go to the user's screenshot folder (⇧⌘5 → Options), Desktop by default.
/// Both need Screen Recording permission.
@MainActor
final class CaptureController {
    private let ax: AccessibilityManager
    private let tracker: WindowResizeTracker
    private let toast = Toast()
    private let flash = WindowFlash()
    private let outline = RecordingOutline()
    private var recorder: WindowRecorder?
    private var recordingWindow: (element: AXUIElement, id: CGWindowID)?
    private var started = Date()
    private var timer: Timer?

    var isRecording: Bool { recorder != nil }

    init(ax: AccessibilityManager, tracker: WindowResizeTracker) {
        self.ax = ax
        self.tracker = tracker
    }

    // MARK: Screenshot

    func screenshot(_ window: AXUIElement) {
        guard let (id, frame) = target(window), ensurePermission() else { return }
        let url = Self.folder.appendingPathComponent("Screenshot \(Self.timestamp()).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-l", "\(id)", url.path] // -x: no sound; the flash is the feedback
        task.terminationHandler = { process in
            let ok = process.terminationStatus == 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ok else { return self.toast.show("Couldn't take the screenshot", near: frame, ok: false) }
                    self.flash.show(over: frame)
                    self.toast.show("Screenshot saved to \(Self.folderName)", near: frame)
                }
            }
        }
        do { try task.run() } catch { toast.show("Couldn't take the screenshot", near: frame, ok: false) }
    }

    // MARK: Recording

    func toggleRecording(_ window: AXUIElement) {
        isRecording ? stopRecording() : startRecording(window)
    }

    func startRecording(_ window: AXUIElement) {
        guard !isRecording, let (id, frame) = target(window), ensurePermission() else { return }
        let url = Self.folder.appendingPathComponent("Screen Recording \(Self.timestamp()).mov")
        let recorder = WindowRecorder(windowID: id, url: url)
        self.recorder = recorder
        recordingWindow = (window, id)
        started = .now
        Task {
            do {
                try await recorder.start()
            } catch {
                self.cleanUpRecording()
                self.toast.show("Couldn't start recording", near: frame, ok: false)
                return
            }
            self.tracker.pin(window, time: "0:00")
            // Invalidated in cleanUpRecording(); the controller lives as long as the app.
            self.timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { _ in
                MainActor.assumeIsolated { self.tick() }
            }
            self.tick()
        }
    }

    func stopRecording() {
        guard let recorder, let rw = recordingWindow else { return }
        let frame = AccessibilityManager.windowServerFrame(rw.id)
            .flatMap { AccessibilityManager.placement(forAX: $0)?.frame } ?? .zero
        cleanUpRecording()
        Task {
            let ok = (try? await recorder.stop()) != nil
            self.toast.show(ok ? "Recording saved to \(Self.folderName)" : "Couldn't save the recording",
                            near: frame, ok: ok)
        }
    }

    private func cleanUpRecording() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        recordingWindow = nil
        outline.hide()
        tracker.pin(nil, time: nil)
    }

    /// 30 Hz while recording only: keeps the red outline on the window and the badge's timer current.
    private func tick() {
        guard let rw = recordingWindow else { return }
        guard let axFrame = AccessibilityManager.windowServerFrame(rw.id),
              let (frame, _) = AccessibilityManager.placement(forAX: axFrame) else {
            return stopRecording() // window closed or left the screen
        }
        outline.show(around: frame)
        let s = Int(Date.now.timeIntervalSince(started))
        tracker.pin(rw.element, time: "\(s / 60):" + String(format: "%02d", s % 60))
    }

    // MARK: Helpers

    private func target(_ window: AXUIElement) -> (CGWindowID, CGRect)? {
        guard let axFrame = ax.frame(of: window), let id = ax.windowID(of: window, near: axFrame),
              let (frame, _) = AccessibilityManager.placement(forAX: axFrame) else {
            NSSound.beep()
            return nil
        }
        return (id, frame)
    }

    /// Screen Recording permission: asks once (system prompt), then explains where to turn it on.
    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return false
    }

    /// The user's screenshot folder (⇧⌘5 → Options → Save to), else Desktop.
    static var folder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    static var folderName: String { FileManager.default.displayName(atPath: folder.path) }

    /// "2026-10-06 at 14.20.33", like macOS screenshots.
    static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: .now)
    }
}

// MARK: - Recorder

/// ScreenCaptureKit stream of a single window → AVAssetWriter (.mov, H.264). Frames arrive on `queue`;
/// all writer state is touched only there.
final class WindowRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let windowID: CGWindowID
    private let url: URL
    private let queue = DispatchQueue(label: "dev.wize.recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false

    init(windowID: CGWindowID, url: URL) {
        self.windowID = windowID
        self.url = url
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        // H.264 needs even dimensions.
        config.width = Int(window.frame.width * scale) & ~1
        config.height = Int(window.frame.height * scale) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        self.writer = writer
        self.input = input

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws {
        try? await stream?.stopCapture()
        stream = nil
        let (writer, input, started) = queue.sync { (self.writer, self.input, self.sessionStarted) }
        guard let writer, let input else { throw CocoaError(.fileWriteUnknown) }
        guard started else { // no frame ever arrived: nothing worth keeping
            writer.cancelWriting()
            throw CocoaError(.fileWriteUnknown)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, let writer, let input,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }
}

// MARK: - Visual feedback (never captured: window-level capture excludes Wize's windows)

/// Thin red outline around the window being recorded (design).
@MainActor
private final class RecordingOutline {
    private let panel = OverlayWindow()
    private let border = NSView()

    init() {
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        border.layer?.borderWidth = 1.5
        border.layer?.cornerCurve = .continuous
        panel.contentView = border
    }

    func show(around frame: CGRect) {
        let f = frame.insetBy(dx: -1.5, dy: -1.5)
        if panel.frame != f {
            panel.setFrame(f, display: true)
            // macOS 26 windows have ~16 pt corners, earlier ~10 pt.
            border.layer?.cornerRadius = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 17.5 : 11.5
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel.orderOut(nil) }
}

/// White flash over the window after a screenshot (design: 0.85 → 0 over 0.45 s).
@MainActor
private final class WindowFlash {
    private let panel = OverlayWindow()

    init() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        view.layer?.cornerRadius = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 16 : 10
        view.layer?.cornerCurve = .continuous
        panel.contentView = view
    }

    func show(over frame: CGRect) {
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0.85
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }) { MainActor.assumeIsolated { self.panel.orderOut(nil) } }
    }
}

/// Glass pill above the window: "✓ Screenshot saved to Desktop", 2.2 s (design).
@MainActor
private final class Toast {
    private let panel = OverlayWindow()
    private let chip = GlassChipView()
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    init() {
        label.font = .systemFont(ofSize: 13, weight: .medium)
        chip.content.addSubview(label)
        panel.contentView = chip
        panel.hasShadow = true
    }

    func show(_ message: String, near window: CGRect, ok: Bool = true) {
        let text = NSMutableAttributedString()
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            .applying(.init(paletteColors: [ok ? .systemGreen : .systemOrange]))
        if let image = NSImage(systemSymbolName: ok ? "checkmark" : "exclamationmark.triangle.fill",
                               accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -1.5, width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: "  "))
        }
        text.append(NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor,
        ]))
        label.attributedStringValue = text
        let fit = label.fittingSize
        let size = CGSize(width: ceil(fit.width) + 28, height: 30)
        label.frame = CGRect(x: 14, y: (size.height - ceil(fit.height)) / 2, width: ceil(fit.width), height: ceil(fit.height))
        chip.cornerRadius = size.height / 2
        // Centered 10 pt above the window, kept on screen.
        let screen = NSScreen.screens.first { $0.frame.intersects(window) }?.visibleFrame ?? window
        var origin = CGPoint(x: window.midX - size.width / 2, y: window.maxY + 10)
        if origin.y + size.height > screen.maxY { origin.y = window.maxY - size.height - 40 } // inside, below title bar
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)

        generation += 1
        let current = generation
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        Motion.popIn(chip, from: 0.9)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            MainActor.assumeIsolated {
                guard self.generation == current else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.panel.animator().alphaValue = 0 }) {
                    MainActor.assumeIsolated { if self.generation == current { self.panel.orderOut(nil) } }
                }
            }
        }
    }
}

/// Borderless, click-through, non-activating panel on all Spaces.
private final class OverlayWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

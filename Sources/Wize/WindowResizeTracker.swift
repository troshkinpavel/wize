import AppKit
import QuartzCore

/// Turns AX resize notifications into a short display-synchronized tracking session that drives the overlay
/// and enforces size locks. Idle cost is zero: the display link only exists while a resize is in progress.
///
/// Per frame, the window's frame comes from the window server, not AX: AX calls are synchronous IPC into the
/// app being resized, whose main thread is busy with the live resize, so replies arrive late and in bursts
/// (the badge trailed the corner by up to ~150 pt). AX is only used at session start and for lock writes.
///
/// Locks are enforced once the mouse is released (or the resize settles), never mid-drag: writing AXSize
/// while the app's live-resize loop is tracking the mouse makes the window flicker between two sizes.
/// During the drag the overlay shows the size the window will snap to.
@MainActor
final class WindowResizeTracker {
    private let ax: AccessibilityManager
    private let overlay: OverlayPanel
    private let constraints: WindowConstraintController

    private let settleDelay = 0.2   // stop tracking after this long without a frame change (mouse up)
    private let hideDelay = 0.4     // then hide (≈ 600 ms after the last change)

    private var window: AXUIElement?
    private var windowID: CGWindowID?
    private var isFullScreenWindow = false
    private var link: CADisplayLink?
    private var sessionStart: CGRect?
    private var lastFrame: CGRect?
    private var lastOption = false
    private var lastMouseDown = false
    private var lastFlash = (w: false, h: false)
    /// Extra time the badge stays after activity before fading (design: "awake" for 2 s after an interaction).
    private var linger = 0.0
    private var hoverMonitor: Any?
    private var hoverWindow: (element: AXUIElement, id: CGWindowID?, frame: CGRect?, read: Date)?
    private var lastChange = Date.distantPast
    private var hideWork: DispatchWorkItem?

    init(ax: AccessibilityManager, overlay: OverlayPanel, constraints: WindowConstraintController) {
        self.ax = ax
        self.overlay = overlay
        self.constraints = constraints
    }

    /// The window the badge currently belongs to (for click-to-edit).
    var currentWindow: AXUIElement? { window }
    /// While Edit Size is open its shell owns the badge's spot: no badge, including for its own resizes.
    var suspended = false
    /// The window being recorded: its badge stays up (even with auto-hide or the overlay off) and shows
    /// `recordingTime` with a stop button.
    private(set) var pinned: AXUIElement?
    private var recordingTime: String?
    private var lastRecordingTime: String?

    /// Starts/updates (time) or ends (nil window) the recording badge.
    func pin(_ element: AXUIElement?, time: String?) {
        pinned = element
        recordingTime = time
        if let element { track(element) } else { refresh() }
    }

    /// Brings the badge back right after Edit Size morphed into an identical pill (no fade/pop).
    func reveal(_ element: AXUIElement) {
        guard Settings.overlayEnabled else { return }
        overlay.appearInstantly = true
        hold(element, for: 2)
    }

    /// Shows the badge for `element` and keeps it at least `seconds` after activity stops.
    func hold(_ element: AXUIElement, for seconds: Double) {
        linger = max(linger, seconds)
        track(element)
    }

    /// Design: the badge wakes when the pointer is over the window's resize corner/edge zones. Only the
    /// focused window, only with auto-hide on (otherwise it's already visible). The window-server frame is
    /// cached for 0.2 s so mouse moves stay cheap; nothing runs while the mouse is still.
    func startHoverWake() {
        guard hoverMonitor == nil else { return }
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            let p = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.pointerMoved(p) }
        }
    }

    private func pointerMoved(_ cocoa: CGPoint) {
        guard Settings.overlayEnabled, Settings.autoHide, !suspended, link == nil,
              let focused = ax.focusedWindow, let primary = NSScreen.screens.first else { return }
        if hoverWindow.map({ !CFEqual($0.element, focused) }) ?? true {
            let id = ax.frame(of: focused).flatMap { ax.windowID(of: focused, near: $0) }
            hoverWindow = (focused, id, nil, .distantPast)
        }
        guard var h = hoverWindow, let id = h.id else { return }
        if Date.now.timeIntervalSince(h.read) > 0.2 {
            h.frame = AccessibilityManager.windowServerFrame(id)
            h.read = .now
            hoverWindow = h
        }
        let p = CGPoint(x: cocoa.x, y: primary.frame.height - cocoa.y) // AX coordinates
        guard let frame = h.frame, !Geometry.resizeEdges(at: p, of: frame).isEmpty else { return }
        hold(focused, for: 2)
    }

    func windowDidResize(_ element: AXUIElement) {
        track(element)
    }

    /// A visible badge (persistent, or lingering after a resize/hover) follows its window; an active
    /// session already does. Otherwise moves don't wake the badge.
    func windowDidMove(_ element: AXUIElement) {
        if link == nil, !Settings.autoHide || overlay.isVisible { track(element) }
    }

    /// Focus left the badge's window (app switch, desktop click → macOS slides windows aside): the badge
    /// must not stay behind on its own. Persistent mode re-attaches to the newly focused window.
    func focusDidChange(to element: AXUIElement?) {
        if pinned != nil { return } // the recorded window keeps its badge
        if !Settings.autoHide { return refresh() }
        guard let window else { return }
        if element.map({ !CFEqual($0, window) }) ?? true { stop(animated: true) }
    }

    /// Re-attaches the persistent badge to the focused window (auto-hide off), or clears it.
    func refresh() {
        stop()
        if let pinned { return track(pinned) }
        guard Settings.overlayEnabled, !Settings.autoHide, let window = ax.focusedWindow else { return }
        track(window)
    }

    private func track(_ element: AXUIElement) {
        guard !suspended, Settings.overlayEnabled || constraints.hasLock(element) || pinned != nil else { return }
        if window == nil || !CFEqual(window, element) {
            guard ax.isStandardWindow(element) else { return Settings.autoHide ? () : stop() }
            stopTracking()
            window = element
            windowID = nil
            lastFrame = nil
        }
        hideWork?.cancel()
        lastChange = .now
        if link == nil { startTracking() }
        tick()
    }

    /// Ends any session (settings change, trust revoked, Edit Size taking over the badge's spot).
    func stop(animated: Bool = false) {
        stopTracking()
        hideWork?.cancel()
        window = nil
        overlay.hide(animated: animated)
    }

    private func startTracking() {
        guard let window, let axFrame = ax.frame(of: window) else { return }
        // One-time AX reads per session; everything per-frame comes from the window server.
        isFullScreenWindow = ax.isFullScreen(window)
        if windowID == nil { windowID = ax.windowID(of: window, near: axFrame) }
        let screen = AccessibilityManager.placement(forAX: axFrame)?.screen ?? NSScreen.main
        let proxy = DisplayLinkProxy { [weak self] in self?.tick() }
        guard let l = screen?.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:))) else { return }
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopTracking() {
        link?.invalidate()
        link = nil
        sessionStart = nil
    }

    private func currentFrame() -> CGRect? {
        if let windowID { return AccessibilityManager.windowServerFrame(windowID) } // nil: closed / off-Space
        return window.flatMap(ax.frame(of:)) // no window-server match: fall back to AX
    }

    private func tick() {
        guard let window, let frame = currentFrame() else { return stop() }
        let start = sessionStart ?? frame
        sessionStart = start
        let option = NSEvent.modifierFlags.contains(.option)
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        let flash = constraints.dragFlash
        // Click-through only mid-drag (so it can never catch a resize). Otherwise a click must land on the
        // badge: falling through to the wallpaper triggers macOS's "click wallpaper to reveal desktop".
        overlay.setInteractive(!mouseDown)
        let target = isFullScreenWindow ? nil : constraints.target(for: window, frame: frame, sessionStart: start)

        if !mouseDown, let target, constraints.enforce(target, on: window, frame: frame, sessionStart: start) {
            lastChange = .now // keep tracking to show the result
            return
        }
        if frame != lastFrame || option != lastOption || mouseDown != lastMouseDown || flash != lastFlash
            || recordingTime != lastRecordingTime {
            lastRecordingTime = recordingTime
            if frame != lastFrame { lastChange = .now }
            lastFrame = frame
            lastOption = option
            lastMouseDown = mouseDown
            lastFlash = flash
            // While dragging, preview the size the window will snap to; afterwards show what the app really has.
            render(frame, size: mouseDown ? target ?? frame.size : frame.size, window: window, extended: option,
                   mouseDown: mouseDown)
        } else if !mouseDown, Date.now.timeIntervalSince(lastChange) > settleDelay {
            stopTracking()
            // Persistent or recording badge stays; the next move/resize/tick wakes tracking.
            guard Settings.autoHide, pinned.map({ !CFEqual($0, window) }) ?? true else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.overlay.hide()
                    self?.window = nil
                }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(hideDelay, linger), execute: work)
            linger = 0
        }
    }

    private func render(_ axFrame: CGRect, size: CGSize, window: AXUIElement, extended: Bool, mouseDown: Bool = false) {
        let recording = pinned.map { CFEqual($0, window) } == true
        guard Settings.overlayEnabled || recording,
              let (frame, screen) = AccessibilityManager.placement(forAX: axFrame) else {
            return overlay.hide(animated: false)
        }
        // Maximized (fills the work area) or native fullscreen: stay out of the way.
        if Geometry.covers(frame, screen.visibleFrame) || isFullScreenWindow {
            return overlay.hide(animated: false)
        }
        // Dragging against a lock: flash that number (the window snaps back on release).
        let lock = constraints.lock(for: window)
        let flashW = mouseDown && (constraints.dragFlash.w || lock.width.map { abs(axFrame.width - $0) > 4 } == true)
        let flashH = mouseDown && (constraints.dragFlash.h || lock.height.map { abs(axFrame.height - $0) > 4 } == true)
        overlay.show(size: size, position: extended ? axFrame.origin : nil, lock: lock,
                     flashW: flashW, flashH: flashH, recording: recording ? recordingTime : nil,
                     near: frame, bounds: screen.visibleFrame)
    }
}

/// CADisplayLink retains its target; this proxy keeps the tracker out of that retain.
/// The link is added to the main run loop, so callbacks arrive on the main actor.
@MainActor
private final class DisplayLinkProxy: NSObject {
    private let onTick: @MainActor () -> Void

    init(_ onTick: @escaping @MainActor () -> Void) {
        self.onTick = onTick
    }

    @objc func tick(_ link: CADisplayLink) {
        onTick()
    }
}

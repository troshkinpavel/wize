import AppKit
import ServiceManagement
import SwiftUI

/// Settings window: a grouped form with General, Size overlay and
/// Accessibility sections. Values live in `Settings` (UserDefaults); `onChange` lets the app react.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    var onChange: (() -> Void)?
    private var window: NSWindow?
    private var previousApp: NSRunningApplication?
    private let model = SettingsModel()

    func show() {
        model.onChange = { [weak self] in self?.onChange?() }
        model.reload()
        let window = self.window ?? makeWindow()
        self.window = window
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: SettingsView(model: model))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.title = "Wize Settings"
        window.titlebarAppearsTransparent = true // design: title bar blends into the grey window
        window.backgroundColor = NSColor(name: nil) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
                : NSColor(srgbRed: 0xf4 / 255, green: 0xf4 / 255, blue: 0xf6 / 255, alpha: 1)
        }
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) { model.reload() }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
        previousApp?.activate() // hand focus back to the app the user was working in
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    var onChange: (() -> Void)?

    @Published var launchAtLogin = false
    @Published var accessGranted = AXIsProcessTrusted()
    @Published var overlay = Settings.overlayEnabled { didSet { Settings.overlayEnabled = overlay; onChange?() } }
    @Published var autoHide = Settings.autoHide { didSet { Settings.autoHide = autoHide; onChange?() } }
    @Published var outside = Settings.outside { didSet { Settings.outside = outside; onChange?() } }
    @Published var corner = Settings.corner { didSet { Settings.corner = corner; onChange?() } }
    @Published var shortcut = Shortcut.editSize
    @Published var recording = false
    private var monitor: Any?

    func reload() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accessGranted = AXIsProcessTrusted()
    }

    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        reload()
    }

    func toggleRecording() {
        if recording { return stopRecording() }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Read the event here; only Sendable values cross into the main-actor block.
            let escape = event.keyCode == 53
            let recorded = Shortcut(event: event)
            MainActor.assumeIsolated {
                guard let self else { return }
                if escape { return self.stopRecording() }
                guard let recorded else { return } // needs ⌘, ⌃ or ⌥
                self.shortcut = recorded
                Shortcut.editSize = recorded
                self.stopRecording()
                self.onChange?()
            }
            return nil // swallow keys while recording
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

/// Layout from the design: grey window, white 10 pt cards with hairline edges, 44 pt rows separated by
/// hairlines inset 14 pt, 12 pt grey section headers. Colors adapt to Dark mode.
private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("General") {
                row {
                    Text("Launch Wize at login")
                } control: {
                    toggle(Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }
                divider
                row {
                    Text("Edit size shortcut")
                } control: {
                    Button(model.recording ? "Type shortcut…" : model.shortcut.label) { model.toggleRecording() }
                        .buttonStyle(KeyCapStyle(recording: model.recording))
                }
            }

            section("Size overlay") {
                row { Text("Show size overlay") } control: { toggle($model.overlay) }
                Group {
                    divider
                    row {
                        titled("Auto-hide when idle", "Fades out 2 seconds after the window stops moving")
                    } control: {
                        toggle($model.autoHide)
                    }
                    divider
                    row {
                        Text("Placement")
                    } control: {
                        Picker("Placement", selection: $model.outside) {
                            Text("Inside").tag(false)
                            Text("Outside").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    divider
                    row(minHeight: 72) {
                        titled("Corner", model.corner.title.capitalizedFirst
                               + (model.outside ? ", outside the window" : ", inside the window"))
                    } control: {
                        CornerPicker(corner: $model.corner, outside: model.outside)
                    }
                }
                .disabled(!model.overlay)
                .opacity(model.overlay ? 1 : 0.4)
                .animation(.easeOut(duration: 0.2), value: model.overlay)
            }

            VStack(alignment: .leading, spacing: 6) {
                header("Accessibility")
                card {
                    row(minHeight: 52) {
                        HStack(spacing: 8) {
                            let tint = model.accessGranted ? Color.green : Color.orange
                            Circle().fill(tint).frame(width: 8, height: 8)
                                .background(Circle().fill(tint.opacity(0.2)).frame(width: 14, height: 14))
                            Text(model.accessGranted ? "Access granted" : "Access needed").fontWeight(.medium)
                        }
                    } control: {
                        Button(model.accessGranted ? "Open Privacy Settings…" : "Grant Access…") {
                            AccessibilityManager.openSettings()
                        }
                        .keyboardShortcut(model.accessGranted ? nil : .defaultAction)
                    }
                }
                Text("Wize reads and sets the position and size of windows. It never reads window contents.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
        .font(.system(size: 13))
        .padding(EdgeInsets(top: 6, leading: 20, bottom: 22, trailing: 20))
        .frame(width: 520)
        .background(Palette.window)
    }

    // MARK: Building blocks

    private func section(_ title: String, @ViewBuilder _ rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(title)
            card(rows)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.03), radius: 0.5, y: 1)
    }

    private func row(minHeight: CGFloat = 44, @ViewBuilder _ label: () -> some View,
                     @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            label()
            Spacer(minLength: 0)
            control()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: minHeight)
    }

    private func titled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 0.5).padding(.leading, 14)
    }

    private enum Palette {
        static let window = Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
                : NSColor(srgbRed: 0xf4 / 255, green: 0xf4 / 255, blue: 0xf6 / 255, alpha: 1)
        })
        static let card = Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1) : .white
        })
    }
}

/// Shortcut field from the design: a recessed key cap (26 pt, radius 7, min 72 wide); while recording it
/// turns white with an accent focus ring.
private struct KeyCapStyle: ButtonStyle {
    let recording: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .tracking(0.5)
            .foregroundStyle(recording ? .secondary : .primary)
            .padding(.horizontal, 12)
            .frame(minWidth: 72, minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(recording ? Color(nsColor: .textBackgroundColor) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.12),
                                  lineWidth: recording ? 1 : 0.5)
            )
            .background(
                RoundedRectangle(cornerRadius: 7).inset(by: -3)
                    .fill(Color.accentColor.opacity(recording ? 0.35 : 0))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: recording)
    }
}

/// Mini window with four pill targets (design). Outside placement shrinks the window so the pills sit
/// beyond its edges.
private struct CornerPicker: View {
    @Binding var corner: OverlayCorner
    let outside: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            let inset: CGFloat = outside ? 9 : 0
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.14)))
                .overlay(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Circle().fill(.black.opacity(0.22)).frame(width: 3, height: 3) } }
                            .padding(.leading, 4).frame(maxWidth: .infinity, minHeight: 8, maxHeight: 8, alignment: .leading)
                        Divider()
                    }
                }
                .padding(inset)
            ForEach(OverlayCorner.allCases, id: \.self) { c in
                let (top, left) = position(c)
                Button { corner = c } label: {
                    Capsule()
                        .fill(corner == c ? Color.accentColor : Color.white)
                        .overlay(Capsule().strokeBorder(.black.opacity(corner == c ? 0 : 0.18)))
                        .shadow(color: corner == c ? .accentColor.opacity(0.4) : .clear, radius: 1.5, y: 1)
                        .frame(width: 22, height: 12)
                }
                .buttonStyle(.plain)
                .help(c.title)
                .offset(x: left, y: top)
            }
        }
        .frame(width: 84, height: 54)
        .animation(.easeOut(duration: 0.2), value: outside)
        .animation(.easeOut(duration: 0.15), value: corner)
    }

    private func position(_ c: OverlayCorner) -> (CGFloat, CGFloat) {
        let top = c == .topLeft || c == .topRight, right = c == .topRight || c == .bottomRight
        return outside ? (top ? 0 : 42, right ? 62 : 0) : (top ? 13 : 37, right ? 57 : 5)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst().lowercased() }
}

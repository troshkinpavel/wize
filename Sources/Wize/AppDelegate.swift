import AppKit

enum Settings {
    private static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: ["overlayEnabled": true, "autoHide": true, "overlayCorner": OverlayCorner.bottomRight.rawValue])
    }
    static var overlayEnabled: Bool {
        get { d.bool(forKey: "overlayEnabled") }
        set { d.set(newValue, forKey: "overlayEnabled") }
    }
    /// Off: the badge stays on the focused window instead of only appearing while resizing.
    static var autoHide: Bool {
        get { d.bool(forKey: "autoHide") }
        set { d.set(newValue, forKey: "autoHide") }
    }
    /// Overlay Position → Outside Window: the badge sits just outside the window instead of in its corner.
    static var outside: Bool {
        get { d.bool(forKey: "overlayOutside") }
        set { d.set(newValue, forKey: "overlayOutside") }
    }
    static var corner: OverlayCorner {
        get { OverlayCorner(rawValue: d.string(forKey: "overlayCorner") ?? "") ?? .bottomRight }
        set { d.set(newValue.rawValue, forKey: "overlayCorner") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let ax = AccessibilityManager()
    private let overlay = OverlayPanel()
    private lazy var constraints = WindowConstraintController(ax: ax)
    private lazy var tracker = WindowResizeTracker(ax: ax, overlay: overlay, constraints: constraints)
    private lazy var editor = SizeEditorPanel(ax: ax, constraints: constraints)
    private lazy var liveResize = LockedResizeController(ax: ax, constraints: constraints)
    private var menuBar: MenuBarController?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        menuBar = MenuBarController(ax: ax, constraints: constraints, editor: editor,
                                    onSettingsChanged: { [tracker, weak self] in
                                        tracker.refresh()
                                        self?.hotKey?.register(Shortcut.editSize)
                                    })
        // The HUD sits on the badge's corner: hide the badge while editing, bring it back after.
        // Edit Size morphs out of the badge's pill and back: the badge steps aside while it's open and
        // reappears instantly in the pill's exact spot afterwards.
        editor.onOpen = { [tracker] in
            tracker.stop()
            tracker.suspended = true
        }
        editor.onClose = { [tracker, ax] window in
            tracker.suspended = false
            // Closed by clicking elsewhere (e.g. the desktop): don't bring the badge back on a window
            // that is no longer focused.
            guard let focused = ax.focusedWindow, CFEqual(focused, window) else { return }
            tracker.reveal(window)
        }
        overlay.onClick = { [tracker, editor, ax] in
            guard let window = tracker.currentWindow ?? ax.focusedWindow else { return }
            editor.show(for: window)
        }
        ax.onWindowMoved = { [tracker] in tracker.windowDidMove($0) }
        ax.onFocusedWindowChanged = { [tracker] in tracker.focusDidChange(to: $0) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [tracker] _ in MainActor.assumeIsolated { if !Settings.autoHide { tracker.refresh() } } }
        // Locks are session-only and die with their window or app; no stale AX references are kept.
        ax.onWindowDestroyed = { [constraints] in constraints.forget($0) }
        ax.onAppTerminated = { [constraints] in constraints.forget(pid: $0) }
        ax.onWindowResized = { [tracker] in tracker.windowDidResize($0) }
        ax.onTrustChanged = { [tracker, liveResize] trusted in
            if !trusted { tracker.stop() }
            liveResize.update()
        }
        // Locks hold while dragging: the event tap exists only while some window is locked.
        constraints.onLocksChanged = { [liveResize] in liveResize.update() }
        liveResize.onBegin = { [tracker] window in tracker.hold(window, for: 2) }
        tracker.startHoverWake()
        // Global Edit Size shortcut (recorded in Settings); re-registered whenever settings change.
        let hotKey = HotKey { [tracker, editor, ax] in
            guard ax.isTrusted, let window = ax.refreshFocusedWindow() else { return NSSound.beep() }
            _ = tracker
            editor.show(for: window)
        }
        hotKey.register(Shortcut.editSize)
        self.hotKey = hotKey
        ax.start()
        if !ax.isTrusted { showPermissionAlert() }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Wize needs Accessibility access"
        alert.informativeText = """
            Wize reads the position and size of the window you are resizing through the macOS \
            Accessibility API. It never reads window contents.

            Turn on Wize in System Settings → Privacy & Security → Accessibility. \
            It starts working as soon as access is granted, no restart needed.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { AccessibilityManager.openSettings() }
    }
}

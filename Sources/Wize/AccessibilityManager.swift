import AppKit
import ApplicationServices

/// Owns Accessibility trust, the frontmost app's AXObserver and the focused window.
/// Everything runs on the main run loop; there is no polling once trust is granted.
@MainActor
final class AccessibilityManager {
    var onTrustChanged: ((Bool) -> Void)?
    var onWindowResized: ((AXUIElement) -> Void)?
    var onWindowDestroyed: ((AXUIElement) -> Void)?
    var onWindowMoved: ((AXUIElement) -> Void)?
    var onFocusedWindowChanged: ((AXUIElement?) -> Void)?
    var onAppTerminated: ((pid_t) -> Void)?

    private(set) var isTrusted = AXIsProcessTrusted()
    private(set) var focusedWindow: AXUIElement?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var pid: pid_t = 0
    private var trustTimer: Timer?

    static func openSettings() {
        // Checking trust registers the app in the Accessibility list so the user only has to flip the switch.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            // Our own activation (alerts) must not drop the app being controlled.
            guard pid != getpid() else { return }
            MainActor.assumeIsolated { self.observe(pid: pid) }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let pid else { return }
                if pid == self.pid { self.teardown() }
                self.onAppTerminated?(pid)
            }
        }
        // Posted whenever any app's Accessibility trust changes (covers revocation while running).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { _ in
            // The trust flag updates slightly after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self.checkTrust() } }
        }
        checkTrust(force: true)
    }

    // MARK: Trust

    private func checkTrust(force: Bool = false) {
        let trusted = AXIsProcessTrusted()
        guard force || trusted != isTrusted else { return }
        isTrusted = trusted
        trustTimer?.invalidate()
        trustTimer = nil
        if trusted {
            observe(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        } else {
            teardown()
            // 1 Hz poll only while untrusted; the distributed notification alone isn't guaranteed.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { self.checkTrust() }
            }
        }
        if !force { onTrustChanged?(trusted) }
    }

    // MARK: Observation

    private func observe(pid: pid_t?, attempt: Int = 0) {
        teardown()
        guard isTrusted, let pid, pid != getpid() else { return }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1) // don't hang on unresponsive apps
        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let manager = Unmanaged<AccessibilityManager>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { manager.handle(name, element) }
        }, &created)
        guard status == .success, let created else { return }

        self.pid = pid
        observer = created
        appElement = app
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)

        let err = add(kAXFocusedWindowChangedNotification, to: app)
        if err == .cannotComplete || err == .notImplemented, attempt < 3 {
            // Freshly launched apps often aren't AX-ready at activation time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    self.observe(pid: pid, attempt: attempt + 1)
                }
            }
            return
        }
        setFocusedWindow(copyElement(app, kAXFocusedWindowAttribute))
    }

    private func teardown() {
        setFocusedWindow(nil)
        if let observer {
            if let appElement { remove(kAXFocusedWindowChangedNotification, from: appElement) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        appElement = nil
        pid = 0
    }

    private func setFocusedWindow(_ window: AXUIElement?) {
        let notifications = [kAXWindowResizedNotification, kAXWindowMovedNotification, kAXUIElementDestroyedNotification]
        if let old = focusedWindow {
            for n in notifications { remove(n, from: old) }
        }
        let changed = (focusedWindow == nil) != (window == nil)
            || (focusedWindow.map { old in window.map { !CFEqual(old, $0) } ?? true } ?? false)
        focusedWindow = window
        if let window {
            for n in notifications { add(n, to: window) }
        }
        if changed { onFocusedWindowChanged?(window) }
    }

    private func handle(_ name: String, _ element: AXUIElement) {
        switch name {
        case kAXFocusedWindowChangedNotification:
            setFocusedWindow(element)
        case kAXWindowResizedNotification:
            onWindowResized?(element)
        case kAXWindowMovedNotification:
            onWindowMoved?(element)
        case kAXUIElementDestroyedNotification:
            onWindowDestroyed?(element)
            if let focusedWindow, CFEqual(focusedWindow, element) {
                setFocusedWindow(appElement.flatMap { copyElement($0, kAXFocusedWindowAttribute) })
            }
        default:
            break
        }
    }

    @discardableResult
    private func add(_ notification: String, to element: AXUIElement) -> AXError {
        guard let observer else { return .failure }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        return AXObserverAddNotification(observer, element, notification as CFString, refcon)
    }

    private func remove(_ notification: String, from element: AXUIElement) {
        guard let observer else { return }
        AXObserverRemoveNotification(observer, element, notification as CFString)
    }

    /// Re-reads the focused window (cheap; used when the menu opens in case a notification was missed).
    @discardableResult
    func refreshFocusedWindow() -> AXUIElement? {
        let current = appElement.flatMap { copyElement($0, kAXFocusedWindowAttribute) }
        if let current, let focusedWindow, CFEqual(current, focusedWindow) { return focusedWindow }
        setFocusedWindow(current)
        return current
    }

    // MARK: Window attributes

    /// Window frame in AX coordinates (top-left origin of the primary screen).
    func frame(of window: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let p = axValue(window, kAXPositionAttribute), AXValueGetValue(p, .cgPoint, &origin),
              let s = axValue(window, kAXSizeAttribute), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Returns false if the app rejects the write (fixed-size windows, unsupported apps).
    @discardableResult
    func setSize(_ size: CGSize, of window: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    @discardableResult
    func setPosition(_ point: CGPoint, of window: AXUIElement) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    func isSizeSettable(_ window: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    func title(of window: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Window-server ID for an AX window, matched by owner PID and bounds (front-most closest match).
    /// Note: bounds matching instead of the private _AXUIElementGetWindow; two identical stacked windows can swap.
    func windowID(of window: AXUIElement, near frame: CGRect) -> CGWindowID? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let candidates = list.compactMap { info -> (id: CGWindowID, distance: CGFloat)? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid, info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let r = Self.bounds(info) else { return nil }
            return (id, abs(r.minX - frame.minX) + abs(r.minY - frame.minY)
                        + abs(r.width - frame.width) + abs(r.height - frame.height))
        }
        guard let best = candidates.min(by: { $0.distance < $1.distance }), best.distance < 64 else { return nil }
        return best.id
    }

    /// The frame the window server is displaying right now (same top-left coordinates as AX), or nil if
    /// the window is gone or not on screen (another Space, minimized). No IPC to the target app, so it stays
    /// fast while that app is busy live-resizing.
    static func windowServerFrame(_ id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true else { return nil }
        return bounds(info)
    }

    private static func bounds(_ info: [String: Any]) -> CGRect? {
        (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    }

    /// Converts an AX frame to Cocoa coordinates and finds the screen holding most of it.
    static func placement(forAX axFrame: CGRect) -> (frame: CGRect, screen: NSScreen)? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        let frame = Geometry.cocoaRect(fromAX: axFrame, primaryScreenHeight: primary.frame.height)
        guard let i = Geometry.bestScreenIndex(for: frame, screens: screens.map(\.frame)) else { return nil }
        return (frame, screens[i])
    }

    func isFullScreen(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }

    func isStandardWindow(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &ref) == .success else { return false }
        return (ref as? String) == kAXStandardWindowSubrole
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return (ref as! AXValue)
    }
}

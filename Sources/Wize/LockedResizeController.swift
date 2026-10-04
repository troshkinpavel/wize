import AppKit
import os

private let log = Logger(subsystem: "dev.wize.Wize", category: "live-resize")

/// Makes locks hold *while* dragging instead of snapping on release.
///
/// An app owns its live-resize loop, so Wize can't constrain it from outside: writing AXSize mid-drag
/// fights the app's own mouse tracking and flickers. Instead, a mouse-down on a resize edge/corner of a
/// locked window is taken over: a session event tap swallows that mouse-down and the following drag, so
/// the app never starts its own resize, and Wize sets the constrained frame itself (`Geometry.lockedResize`).
/// Every other click passes through untouched. The tap only exists while some window has a lock.
@MainActor
final class LockedResizeController {
    private let ax: AccessibilityManager
    private let constraints: WindowConstraintController
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private struct Session {
        let window: AXUIElement
        let start: CGRect
        let mouse: CGPoint
        let edges: ResizeEdges
        let lock: WindowLockState
    }
    private var session: Session?
    /// A take-over started: show the badge even if the size never changes (both W and H locked).
    var onBegin: ((AXUIElement) -> Void)?
    private var pending: CGRect?
    private var applyScheduled = false
    private var lastApplied: CGRect?

    init(ax: AccessibilityManager, constraints: WindowConstraintController) {
        self.ax = ax
        self.constraints = constraints
    }

    /// Installs the tap while any lock exists (and Accessibility is granted), removes it otherwise.
    func update() {
        let wanted = ax.isTrusted && constraints.hasAnyLock
        if wanted, tap == nil { install() } else if !wanted, tap != nil, session == nil { uninstall() }
    }

    private func install() {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<LockedResizeController>.fromOpaque(refcon).takeUnretainedValue()
            // The tap's run-loop source is on the main run loop.
            let swallow = MainActor.assumeIsolated { controller.handle(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: refcon) else {
            log.error("event tap creation failed (Accessibility not granted to this build?)")
            return
        }
        log.debug("event tap installed")
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func uninstall() {
        log.debug("event tap removed")
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Returns true to swallow the event. Must stay fast: AX writes are deferred out of the callback.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            log.error("event tap disabled by system (\(type.rawValue)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .leftMouseDown:
            guard session == nil, let s = beginSession(at: event.location, flags: event.flags) else { return false }
            session = s
            lastApplied = s.start
            onBegin?(s.window)
            log.debug("take over resize: edges \(s.edges.rawValue) frame \(String(describing: s.start), privacy: .public)")
            return true
        case .leftMouseDragged:
            guard let s = session else { return false }
            let delta = CGVector(dx: event.location.x - s.mouse.x, dy: event.location.y - s.mouse.y)
            let horizontal = !s.edges.isDisjoint(with: [.left, .right])
            let vertical = !s.edges.isDisjoint(with: [.top, .bottom])
            constraints.dragFlash = (w: s.lock.width != nil && horizontal && abs(delta.dx) > 4,
                                     h: s.lock.height != nil && vertical && abs(delta.dy) > 4)
            schedule(Geometry.lockedResize(s.start, edges: s.edges, delta: delta, lock: s.lock))
            return true
        case .leftMouseUp:
            guard session != nil else { return false }
            flush()
            session = nil
            constraints.dragFlash = (false, false)
            update() // a lock removed mid-drag can drop the tap now
            return true
        default:
            return false
        }
    }

    private func beginSession(at p: CGPoint, flags: CGEventFlags) -> Session? {
        // Modifier-clicks belong to the app (or to other tools).
        guard flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty else { return nil }
        guard let window = ax.focusedWindow else { log.debug("mouse-down: no focused window"); return nil }
        guard constraints.hasLock(window) else { log.debug("mouse-down: focused window has no lock"); return nil }
        let lock = constraints.lock(for: window)
        guard let frame = ax.frame(of: window) else { log.debug("mouse-down: no frame"); return nil }
        let edges = Geometry.resizeEdges(at: p, of: frame)
        // Log near-misses around the window so zone sizes can be tuned from real clicks.
        if edges.isEmpty {
            if frame.insetBy(dx: -24, dy: -24).contains(p), !frame.insetBy(dx: 24, dy: 24).contains(p) {
                log.debug("mouse-down near edge but outside zones: point \(String(describing: p), privacy: .public) frame \(String(describing: frame), privacy: .public)")
            }
            return nil
        }
        guard !ax.isFullScreen(window) else { log.debug("mouse-down: fullscreen"); return nil }
        guard ax.isSizeSettable(window) else { log.debug("mouse-down: size not settable"); return nil }
        guard isFrontmost(window, frame: frame, at: p) else { return nil }
        return Session(window: window, start: frame, mouse: p, edges: edges, lock: lock)
    }

    /// The locked window must be the topmost window at the click, so clicks on anything covering it pass through.
    private func isFrontmost(_ window: AXUIElement, frame: CGRect, at p: CGPoint) -> Bool {
        guard let id = ax.windowID(of: window, near: frame) else { log.debug("mouse-down: no window-server match"); return false }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for info in list { // front to back
            guard (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = (info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { continue }
            // Wize's own UI (ratio/preset menus, Edit Size bar, badge) at any level wins: a click on it
            // must reach it, even where it overlaps the locked window's resize zone.
            if info[kCGWindowOwnerPID as String] as? pid_t == getpid() {
                if b.contains(p) {
                    log.debug("mouse-down: on Wize's own UI")
                    return false
                }
                continue
            }
            // Other apps can cover it only with layers 0–19 (normal, floating, modal). System overlays at
            // 20+ (the Dock's invisible full-screen window, menu bar) span everything and must be ignored.
            guard (0..<20).contains(info[kCGWindowLayer as String] as? Int ?? 0) else { continue }
            if info[kCGWindowNumber as String] as? CGWindowID == id { return b.insetBy(dx: -6, dy: -6).contains(p) }
            if b.contains(p) {
                log.debug("mouse-down: covered by \(info[kCGWindowOwnerName as String] as? String ?? "?", privacy: .public) layer \(info[kCGWindowLayer as String] as? Int ?? -1) bounds \(String(describing: b), privacy: .public)")
                return false
            }
        }
        return false
    }

    /// Coalesces drag events into at most one AX write per main-loop turn.
    private func schedule(_ frame: CGRect) {
        pending = frame
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { MainActor.assumeIsolated { self.flush() } }
    }

    private func flush() {
        applyScheduled = false
        guard let s = session, let frame = pending, frame != lastApplied else { return }
        pending = nil
        // Only move the origin when a left/top edge is dragged; right/bottom drags are a pure size write.
        if frame.origin != lastApplied?.origin { ax.setPosition(frame.origin, of: s.window) }
        if frame.size != lastApplied?.size { ax.setSize(frame.size, of: s.window) }
        lastApplied = frame
    }
}

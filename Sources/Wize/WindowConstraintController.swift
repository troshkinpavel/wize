import AppKit

/// Session-only size locks for one window.
///
/// Precedence (deterministic, no contradictions):
/// 1. W and/or H locked → locked values win, the other dimension is free.
/// 2. Aspect ratio applies only when neither W nor H is locked (otherwise it is "paused").
struct WindowLockState: Equatable {
    var width: CGFloat?
    var height: CGFloat?
    /// Base size whose W:H ratio is kept.
    var aspect: CGSize?

    var isEmpty: Bool { width == nil && height == nil && aspect == nil }
    var aspectIsActive: Bool { aspect != nil && width == nil && height == nil }

    /// Size the window should have, given the user's `size` and the size at the start of the resize.
    func constrain(_ size: CGSize, from start: CGSize) -> CGSize {
        if width != nil || height != nil {
            return CGSize(width: width ?? size.width, height: height ?? size.height)
        }
        guard let aspect, aspect.width > 0, aspect.height > 0 else { return size }
        let ratio = aspect.width / aspect.height
        // The dimension that changed more (relatively) is the one the user is dragging.
        let dw = abs(size.width - start.width) / max(start.width, 1)
        let dh = abs(size.height - start.height) / max(start.height, 1)
        return dw >= dh
            ? CGSize(width: size.width, height: (size.width / ratio).rounded())
            : CGSize(width: (size.height * ratio).rounded(), height: size.height)
    }

    /// An explicit size (editor or preset) re-bases W/H locks to that size. The aspect ratio is kept.
    mutating func rebase(to size: CGSize) {
        if width != nil { width = size.width }
        if height != nil { height = size.height }
    }

    static let commonRatios: [CGSize] = [
        CGSize(width: 16, height: 9), CGSize(width: 16, height: 10), CGSize(width: 4, height: 3),
        CGSize(width: 3, height: 2), CGSize(width: 1, height: 1), CGSize(width: 21, height: 9),
    ]

    /// Common ratios keep their usual names ("16:10", not "8:5") and absorb sizes within 0.5% of them
    /// (1314 × 821 → "16:10"); other exact small ratios reduce ("5:4"); the rest read "1.86:1".
    static func ratioText(_ size: CGSize) -> String {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return "–" }
        let r = Double(w) / Double(h)
        if let near = commonRatios.first(where: { abs($0.width / $0.height - r) / r < 0.005 }) {
            return "\(Int(near.width)):\(Int(near.height))"
        }
        var (a, b) = (w, h)
        while b != 0 { (a, b) = (b, a % b) }
        let (rw, rh) = (w / a, h / a)
        return rw <= 32 && rh <= 32 ? "\(rw):\(rh)" : String(format: "%.2f:1", r)
    }
}

/// Holds per-window locks and applies sizes through Accessibility. No UI.
@MainActor
final class WindowConstraintController {
    private let ax: AccessibilityManager
    /// Called when the set of locked windows changes (the live-resize event tap runs only while any exist).
    var onLocksChanged: (() -> Void)?
    var hasAnyLock: Bool { !locks.isEmpty }
    /// Set by the live-resize take-over while the user drags against a locked W/H (the size can't change,
    /// so the badge flashes that number instead).
    var dragFlash = (w: false, h: false)
    /// Keyed by the window's AX element (CFEqual/CFHash identity). Pruned when windows or apps go away.
    private var locks: [AXUIElement: WindowLockState] = [:] {
        didSet { if oldValue.isEmpty != locks.isEmpty { onLocksChanged?() } }
    }
    /// Last size we wrote while enforcing. If the app answers with something else, we don't retry the same target.
    private var lastWrite: CGSize?

    init(ax: AccessibilityManager) {
        self.ax = ax
    }

    func lock(for window: AXUIElement) -> WindowLockState { locks[window] ?? WindowLockState() }

    func hasLock(_ window: AXUIElement) -> Bool { locks[window] != nil }

    func setLock(_ state: WindowLockState, for window: AXUIElement) {
        locks[window] = state.isEmpty ? nil : state
        lastWrite = nil
    }

    /// Constrained size for a resize in progress, or nil if the window has no locks.
    func target(for window: AXUIElement, frame: CGRect, sessionStart: CGRect) -> CGSize? {
        guard let lock = locks[window] else { return nil }
        return lock.constrain(frame.size.rounded, from: sessionStart.size)
    }

    /// Writes `target` if the window doesn't match it. Returns true if a write happened.
    /// A target the app already rejected once (min/max size, non-resizable) is not retried: no feedback loop.
    func enforce(_ target: CGSize, on window: AXUIElement, frame: CGRect, sessionStart: CGRect) -> Bool {
        guard !frame.size.rounded.equalTo(target) else {
            lastWrite = nil
            return false
        }
        guard lastWrite != target else { return false }
        lastWrite = target
        // Keep the edge the user did NOT drag in place (AX origin is top-left).
        let draggedLeft = abs(frame.minX - sessionStart.minX) > 0.5 && abs(frame.maxX - sessionStart.maxX) <= 0.5
        let draggedTop = abs(frame.minY - sessionStart.minY) > 0.5 && abs(frame.maxY - sessionStart.maxY) <= 0.5
        guard ax.setSize(target, of: window), let actual = ax.frame(of: window)?.size else { return true }
        if draggedLeft || draggedTop {
            ax.setPosition(CGPoint(x: draggedLeft ? frame.maxX - actual.width : frame.minX,
                                   y: draggedTop ? frame.maxY - actual.height : frame.minY), of: window)
        }
        return true
    }

    /// Sets an exact size (editor / preset). With an active aspect lock, W is kept and H follows the ratio;
    /// W/H locks are re-based to the size the app actually accepted.
    @discardableResult
    func apply(_ size: CGSize, to window: AXUIElement) -> Bool {
        var size = size
        if let lock = locks[window], lock.aspectIsActive, let a = lock.aspect {
            size.height = (size.width * a.height / a.width).rounded()
        }
        guard ax.setSize(size, of: window), let actual = ax.frame(of: window)?.size else { return false }
        if var lock = locks[window] {
            lock.rebase(to: actual.rounded)
            locks[window] = lock
        }
        lastWrite = nil
        return true
    }

    func forget(_ window: AXUIElement) {
        locks[window] = nil
    }

    func forget(pid: pid_t) {
        locks = locks.filter { key, _ in
            var p: pid_t = 0
            return AXUIElementGetPid(key, &p) == .success && p != pid
        }
    }

    /// Drops locks for windows that no longer exist.
    func prune() {
        locks = locks.filter { key, _ in ax.frame(of: key) != nil }
    }
}

extension CGSize {
    var rounded: CGSize { CGSize(width: width.rounded(), height: height.rounded()) }
}

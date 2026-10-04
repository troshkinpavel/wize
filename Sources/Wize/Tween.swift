import AppKit
import QuartzCore

/// CSS `cubic-bezier(x1, y1, x2, y2)` timing: progress in, eased value out (may overshoot 1, like the design's
/// `.32, 1.12, .4, 1`). Same approach as WebKit's UnitBezier: Newton's method on x, bisection fallback.
struct CubicBezier {
    let x1, y1, x2, y2: Double

    static let ease = CubicBezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1) // CSS default `ease`
    static let shell = CubicBezier(x1: 0.32, y1: 1.12, x2: 0.4, y2: 1)  // design: glass shell resize
    static let pop = CubicBezier(x1: 0.3, y1: 1.2, x2: 0.4, y2: 1)      // design: bar scale-in

    func value(at x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        return sample(y1, y2, solveT(x))
    }

    private func sample(_ a: Double, _ b: Double, _ t: Double) -> Double {
        ((1 - 3 * b + 3 * a) * t + (3 * b - 6 * a)) * t * t + 3 * a * t
    }

    private func solveT(_ x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let err = sample(x1, x2, t) - x
            if abs(err) < 1e-6 { return t }
            let d = (3 * (1 - 3 * x2 + 3 * x1)) * t * t + (2 * (3 * x2 - 6 * x1)) * t + 3 * x1
            if abs(d) < 1e-6 { break }
            t -= err / d
        }
        var (lo, hi) = (0.0, 1.0)
        t = x
        while hi - lo > 1e-7 {
            let v = sample(x1, x2, t)
            if abs(v - x) < 1e-6 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return t
    }
}

/// Display-synced driver for CSS-style transitions: each track has a delay, duration and curve and receives
/// its eased progress every frame. Used where AppKit's window animations can't express the design
/// (overshooting curves, per-property delays, blur). Runs only while animating.
@MainActor
final class Tween: NSObject {
    struct Track {
        var delay: Double = 0
        var duration: Double
        var curve: CubicBezier = .ease
        var apply: (Double) -> Void
    }

    private var tracks: [Track] = []
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var completion: (() -> Void)?

    /// Starts `tracks` on `view`'s display; replaces any running animation (without calling its completion).
    func run(on view: NSView, _ tracks: [Track], completion: (() -> Void)? = nil) {
        stop()
        self.tracks = tracks
        self.completion = completion
        for track in tracks { track.apply(0) }
        start = CACurrentMediaTime()
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
        completion = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let t = CACurrentMediaTime() - start
        var done = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for track in tracks {
            let p = min(max((t - track.delay) / track.duration, 0), 1)
            if p < 1 { done = false }
            track.apply(track.curve.value(at: p))
        }
        CATransaction.commit()
        guard done else { return }
        let finish = completion
        stop()
        finish?()
    }
}

/// Per-frame styling of a layer-backed view: opacity, Gaussian blur and scale around an anchor point
/// (in the view's own coordinates), like CSS `opacity`, `filter: blur()`, `transform: scale()` + `transform-origin`.
@MainActor
enum Style {
    static func set(_ view: NSView, opacity: Double, blur: Double, scale: Double, origin: CGPoint) {
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        guard let layer = view.layer else { return }
        layer.opacity = Float(opacity)
        layer.filters = blur > 0.05 ? [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])!] : nil
        var t = CATransform3DMakeTranslation(origin.x, origin.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        layer.transform = CATransform3DTranslate(t, -origin.x, -origin.y, 0)
    }
}

func lerp(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }

func lerp(_ a: CGRect, _ b: CGRect, _ p: Double) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, p), y: lerp(a.minY, b.minY, p),
           width: lerp(a.width, b.width, p), height: lerp(a.height, b.height, p))
}

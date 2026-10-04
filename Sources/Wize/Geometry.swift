import CoreGraphics

enum OverlayCorner: String, CaseIterable {
    case bottomRight, bottomLeft, topRight, topLeft

    var title: String {
        switch self {
        case .bottomRight: "Bottom Right"
        case .bottomLeft: "Bottom Left"
        case .topRight: "Top Right"
        case .topLeft: "Top Left"
        }
    }
}

/// Pure geometry helpers, kept free of AppKit state so they can be unit-tested.
enum Geometry {
    /// AX frames use a top-left origin relative to the primary screen; Cocoa uses bottom-left.
    static func cocoaRect(fromAX r: CGRect, primaryScreenHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// True when `window` covers `area` (within `tolerance` points on every edge).
    static func covers(_ window: CGRect, _ area: CGRect, tolerance: CGFloat = 3) -> Bool {
        window.minX <= area.minX + tolerance && window.minY <= area.minY + tolerance
            && window.maxX >= area.maxX - tolerance && window.maxY >= area.maxY - tolerance
    }

    /// Screen (by index) that holds the largest part of `rect`.
    static func bestScreenIndex(for rect: CGRect, screens: [CGRect]) -> Int? {
        let areas = screens.map { s -> CGFloat in
            let i = s.intersection(rect)
            return i.isNull ? 0 : i.width * i.height
        }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
        return best
    }

    /// Overlay origin at `corner` of `window`, clamped fully inside `bounds`. Cocoa coordinates.
    /// Inside: `inset` from the edges (`topInset` at the top, to clear the title bar).
    /// Outside: flush with the window's side edge, `inset` beyond its top/bottom edge.
    static func overlayOrigin(size: CGSize, window w: CGRect, corner: OverlayCorner, inset: CGFloat,
                              bounds b: CGRect, topInset: CGFloat? = nil, outside: Bool = false) -> CGPoint {
        let right = corner == .bottomRight || corner == .topRight
        let top = corner == .topLeft || corner == .topRight
        let x: CGFloat, y: CGFloat
        if outside {
            x = right ? w.maxX - size.width : w.minX
            y = top ? w.maxY + inset : w.minY - inset - size.height
        } else {
            x = right ? w.maxX - inset - size.width : w.minX + inset
            y = top ? w.maxY - (topInset ?? inset) - size.height : w.minY + inset
        }
        return CGPoint(x: min(max(x, b.minX), b.maxX - size.width),
                       y: min(max(y, b.minY), b.maxY - size.height))
    }
}

/// Which window edges a mouse-down grabbed (AX coordinates: top = minY).
struct ResizeEdges: OptionSet, Equatable {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1)
    static let right = ResizeEdges(rawValue: 2)
    static let top = ResizeEdges(rawValue: 4)
    static let bottom = ResizeEdges(rawValue: 8)
}

extension Geometry {
    /// Edges under `p` for window frame `f`. Straight edges: a band `outer` pt outside to `inner` pt inside.
    /// Corners reach further in, like macOS 26's rounded-corner grab areas (a real grab landed 8 pt inside):
    /// `corner` pt at the bottom, `topCorner` at the top so the title-bar buttons stay clickable.
    static func resizeEdges(at p: CGPoint, of f: CGRect, outer: CGFloat = 7, inner: CGFloat = 4,
                            corner: CGFloat = 16, topCorner: CGFloat = 10) -> ResizeEdges {
        guard f.insetBy(dx: -outer, dy: -outer).contains(p) else { return [] }
        let left = p.x <= f.minX + corner, right = p.x >= f.maxX - corner
        let topBand = p.y <= f.minY + topCorner, bottomBand = p.y >= f.maxY - corner
        let topReach = p.x <= f.minX + topCorner || p.x >= f.maxX - topCorner
        if bottomBand && left { return [.left, .bottom] }
        if bottomBand && right { return [.right, .bottom] }
        if topBand && topReach { return p.x < f.midX ? [.left, .top] : [.right, .top] }
        var edges: ResizeEdges = []
        if p.x <= f.minX + inner { edges.insert(.left) }
        if p.x >= f.maxX - inner { edges.insert(.right) }
        if p.y <= f.minY + inner { edges.insert(.top) }
        if p.y >= f.maxY - inner { edges.insert(.bottom) }
        return edges
    }

    /// The frame for dragging `edges` of `start` by `delta`, with `lock` applied live: locked W/H don't move,
    /// an aspect lock derives the other dimension. The edges not being dragged stay put. AX coordinates.
    static func lockedResize(_ start: CGRect, edges: ResizeEdges, delta d: CGVector, lock: WindowLockState,
                             minSize: CGSize = CGSize(width: 120, height: 80)) -> CGRect {
        var size = start.size
        if edges.contains(.right) { size.width += d.dx }
        if edges.contains(.left) { size.width -= d.dx }
        if edges.contains(.bottom) { size.height += d.dy }
        if edges.contains(.top) { size.height -= d.dy }
        size = CGSize(width: max(size.width, minSize.width), height: max(size.height, minSize.height)).rounded
        size = lock.constrain(size, from: start.size)
        let x = edges.contains(.left) ? start.maxX - size.width : start.minX
        let y = edges.contains(.top) ? start.maxY - size.height : start.minY
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

import AppKit

/// Colors from the design (dark values tuned for glass; light values darkened for contrast).
enum Palette {
    /// Locked numbers, active ratio.
    static let accentText = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x6c / 255, green: 0xb4 / 255, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0, green: 0x5f / 255, blue: 0xd0 / 255, alpha: 1)
    }
    /// Dragging against a lock.
    static let flash = NSColor.systemOrange
}

/// Placement shared by the badge and the Edit Size HUD (design: 12 pt inset, 40 pt at the top to clear
/// the title bar; Outside Window sits 10 pt beyond the edge).
enum OverlayPlacement {
    static func origin(size: CGSize, window: CGRect, bounds: CGRect, outside: Bool = Settings.outside) -> CGPoint {
        Geometry.overlayOrigin(size: size, window: window, corner: Settings.corner, inset: outside ? 10 : 12,
                               bounds: bounds, topInset: 40, outside: outside)
    }
}

/// Glass pill that shows the window size. Click-through while a resize is tracked; when idle it can be
/// clicked to open Edit Size (it never activates Wize or takes key).
@MainActor
final class OverlayPanel {
    var onClick: (() -> Void)?
    /// Next appearance skips the fade/pop: the Edit Size shell has just morphed back into an identical pill.
    var appearInstantly = false
    var frame: CGRect { panel.frame }
    var isVisible: Bool { panel.isVisible && panel.alphaValue > 0 }

    private let panel: NSPanel
    private let chip = GlassChipView()
    private let label = NSTextField(labelWithString: "")
    private let clickArea = ClickView()
    private static let pillHeight: CGFloat = 32
    private static let padding = CGSize(width: 13, height: 6) // plus the text cell's own 2 pt inset
    private var generation = 0 // invalidates stale fade-out completions

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none // no system order-in/out animation; fades below are explicit

        label.maximumNumberOfLines = 0
        chip.content.addSubview(label)
        clickArea.autoresizingMask = [.width, .height]
        clickArea.toolTip = "Edit Size"
        clickArea.onClick = { [weak self] in self?.onClick?() }
        chip.addSubview(clickArea)
        panel.contentView = chip
    }

    /// The badge takes clicks except while a mouse button is held (a drag in progress).
    func setInteractive(_ interactive: Bool) {
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }

    /// `window` and `bounds` are Cocoa screen coordinates. `position` (AX) switches to the extended ⌥ layout.
    /// `flashW/H`: the user is dragging against that lock. Called every display frame while tracking:
    /// the position is applied immediately and never animated.
    func show(size: CGSize, position: CGPoint?, lock: WindowLockState, flashW: Bool = false, flashH: Bool = false,
              near window: CGRect, bounds: CGRect) {
        generation += 1
        // Zero-duration, no implicit actions: the chip must move with the window corner in the same frame.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
            NSAnimationContext.endGrouping()
        }

        // Rebuild text/layout only when what it shows changes; otherwise this is a pure move.
        let key = ContentKey(w: Int(size.width.rounded()), h: Int(size.height.rounded()),
                             x: position.map { Int($0.x.rounded()) }, y: position.map { Int($0.y.rounded()) },
                             lock: lock, flashW: flashW, flashH: flashH)
        var chipSize = panel.frame.size
        if key != contentKey {
            contentKey = key
            label.attributedStringValue = Self.content(size: size, position: position, lock: lock,
                                                       flashW: flashW, flashH: flashH)
            let layout = Self.layout(label, extended: position != nil)
            chipSize = layout.size
            label.frame = layout.label
        }
        let origin = OverlayPlacement.origin(size: chipSize, window: window, bounds: bounds)
        if chipSize != panel.frame.size {
            panel.setFrame(CGRect(origin: origin, size: chipSize), display: true, animate: false)
            // Single-line pill: a true capsule (design: border-radius 999px), matching the Edit Size shell at
            // handoff. Two-line ⌥ geometry: a soft 12 pt rect.
            chip.cornerRadius = position == nil ? chipSize.height / 2 : 12
            panel.invalidateShadow()
        } else if origin != panel.frame.origin {
            panel.setFrameOrigin(origin)
        }

        // Appearance only (fade + spring pop); a new animator call also supersedes an in-flight fade-out.
        if !panel.isVisible {
            panel.alphaValue = appearInstantly ? 1 : 0
            panel.orderFrontRegardless()
            if !appearInstantly { Motion.popIn(chip, from: 0.9) }
            appearInstantly = false
        }
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.14; panel.animator().alphaValue = 1 }
        }
    }

    /// Pill size and label frame for `label`'s current text. Shared with the Edit Size shell so its pill
    /// layer is pixel-identical to the badge.
    static func layout(_ label: NSTextField, extended: Bool = false) -> (size: CGSize, label: CGRect) {
        let text = label.fittingSize // intrinsicContentSize omits the cell inset and clips the last glyph
        let height = extended ? ceil(text.height) + padding.height * 2 : pillHeight
        return (CGSize(width: ceil(text.width) + padding.width * 2, height: height),
                CGRect(x: padding.width, y: ((height - ceil(text.height)) / 2).rounded(),
                       width: ceil(text.width), height: ceil(text.height)))
    }

    private struct ContentKey: Equatable {
        var w, h: Int
        var x, y: Int?
        var lock: WindowLockState
        var flashW, flashH: Bool
    }
    private var contentKey: ContentKey?

    /// `1280 × 720` (dimmed ×), lock glyph after each locked dimension, and `· 16:10` in accent while the
    /// aspect ratio is locked. ⌥ adds a second line with `X 320  Y 180`.
    static func content(size: CGSize, position: CGPoint?, lock: WindowLockState,
                        flashW: Bool = false, flashH: Bool = false) -> NSAttributedString {
        // Two-line geometry needs true monospace to keep columns aligned; the compact form reads better in SF.
        let font: NSFont = position == nil
            ? .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
            : .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        // Locked numbers read blue; dragging against a lock flashes them orange.
        let wColor: NSColor = flashW ? Palette.flash : lock.width != nil ? Palette.accentText : .labelColor
        let hColor: NSColor = flashH ? Palette.flash : lock.height != nil ? Palette.accentText : .labelColor
        let out = NSMutableAttributedString()
        func text(_ s: String, _ color: NSColor = .labelColor, weight: NSFont.Weight? = nil) {
            let f = weight.map { NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: $0) } ?? font
            out.append(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .kern: 0.3]))
        }
        func ratio() {
            guard lock.aspectIsActive, let aspect = lock.aspect else { return }
            text("  ·  ", .tertiaryLabelColor, weight: .bold)
            text(WindowLockState.ratioText(aspect), Palette.accentText)
        }
        func badge(_ on: Bool, _ symbol: String) {
            guard on else { return }
            text(" ")
            out.append(symbolBadge(symbol, font: font, color: Palette.accentText))
        }
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        if let position {
            text("W "); text("\(w)", wColor); badge(lock.width != nil, "lock.fill")
            text("  H "); text("\(h)", hColor); badge(lock.height != nil, "lock.fill")
            ratio()
            text(String(format: "\nX %-5d  Y %d", Int(position.x.rounded()), Int(position.y.rounded())))
        } else {
            text("\(w)", wColor); badge(lock.width != nil, "lock.fill")
            text(" × ", .secondaryLabelColor, weight: .medium)
            text("\(h)", hColor); badge(lock.height != nil, "lock.fill")
            ratio()
        }
        return out
    }

    static func symbolBadge(_ name: String, font: NSFont, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.75, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2,
                                   width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    func hide(animated: Bool = true) {
        generation += 1
        guard panel.isVisible else { return }
        guard animated else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        let current = generation
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated {
                guard self.generation == current else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }
}

/// Transparent click catcher on top of the badge. Takes the first click without activating anything.
private final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Glass background with a `content` view to put things in.
/// macOS 26+: Liquid Glass (`NSGlassEffectView`). macOS 14–15: frosted HUD blur with a hairline edge.
/// Both get a light appearance-aware tint so text stays readable over white, black or busy windows.
final class GlassChipView: NSView {
    let content = NSView()
    var cornerRadius: CGFloat = 10 { didSet { applyShape() } }
    private let background: NSView

    /// Dark: smoky glass. Light: milky glass. Resolved per appearance.
    static let tint = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.5) : NSColor(white: 1, alpha: 0.72)
    }

    init() {
        if #available(macOS 26, *) {
            // Liquid Glass adapts its brightness to what's behind it, but our label colors follow the system
            // appearance: a tint layer inside the glass pins the tone so text stays readable on any window.
            let glass = NSGlassEffectView()
            glass.style = .regular
            let holder = NSView()
            let tint = TintView()
            tint.autoresizingMask = [.width, .height]
            content.autoresizingMask = [.width, .height]
            holder.addSubview(tint)
            holder.addSubview(content)
            glass.contentView = holder
            background = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            blur.layer?.borderWidth = 1
            let tint = TintView()
            tint.autoresizingMask = [.width, .height]
            blur.addSubview(tint)
            content.autoresizingMask = [.width, .height]
            blur.addSubview(content)
            background = blur
        }
        super.init(frame: .zero)
        wantsLayer = true // for the pop-in transform
        background.autoresizingMask = [.width, .height]
        addSubview(background)
        applyShape()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        content.superview?.frame = background.bounds
        content.frame = background.bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyShape()
    }

    private func applyShape() {
        if #available(macOS 26, *), let glass = background as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            content.superview?.wantsLayer = true
            content.superview?.layer?.cornerRadius = cornerRadius // clip the tint to the glass shape
            content.superview?.layer?.cornerCurve = .continuous
            content.superview?.layer?.masksToBounds = true
        } else {
            background.layer?.cornerRadius = cornerRadius
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            background.layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.12)).cgColor
        }
    }

    /// Fallback tint layer; drawn (not layer-colored) so the dynamic color follows appearance changes.
    private final class TintView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            GlassChipView.tint.setFill()
            bounds.fill()
        }
    }
}

/// Small spring/fade helpers for appearance only. Window position is never animated.
@MainActor
enum Motion {
    /// Spring-scales `view` from `scale` to identity around its center.
    static func popIn(_ view: NSView, from scale: CGFloat = 0.92) {
        guard let layer = view.layer else { return }
        let c = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -c.x, -c.y, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = t
        spring.toValue = CATransform3DIdentity
        spring.damping = 18
        spring.stiffness = 320
        spring.mass = 1
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "popIn")
    }

    /// Quick "bounce" for a toggled control.
    static func bounce(_ view: NSView) {
        view.wantsLayer = true
        popIn(view, from: 1.25)
    }
}

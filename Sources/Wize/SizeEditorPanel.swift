import AppKit

/// Edit Size bar: `W [1314] 🔓 × H [821] 🔓 │ (16:10 ◉) (✓)` in a 44 pt glass capsule.
///
/// Opening/closing replicates the design's transitions on ONE glass shell holding two layers, the size pill
/// and the bar (driven per display frame by `Tween`, since window animations can't do per-property delays,
/// overshoot curves or blur):
/// - shell: width/height 0.44 s `cubic-bezier(.32,1.12,.4,1)`, anchored to the badge corner;
/// - pill out: opacity + blur 0→4 px 0.22 s, scale 1→0.9 0.3 s; bar in after 130 ms: opacity + blur 6→0 0.26 s,
///   scale 0.94→1 0.36 s `cubic-bezier(.3,1.2,.4,1)`; transform origin at the anchored side;
/// - close reverses it, the pill returning after 170 ms, and follows the window's new corner after Apply.
/// The shell starts and ends as a pixel-identical copy of the badge, which hides/reappears instantly around it.
///
/// - Locks act immediately and are exclusive: W/H clear the aspect lock, a ratio clears W/H.
/// - Ratio and preset picks act immediately; with a ratio locked, a preset re-bases it to the preset's shape.
/// - Return or ✓ applies, Esc cancels, clicking outside applies. ↑/↓ step 1, ⇧↑/⇧↓ step 10.
/// The panel becomes key without activating Wize, so the controlled app stays frontmost.
@MainActor
final class SizeEditorPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    var onOpen: (() -> Void)?
    /// The shell has morphed back into a pill for this window: show the real badge in its place.
    var onClose: ((AXUIElement) -> Void)?
    /// Camera / record buttons: the size is applied first, then the window is captured.
    var onScreenshot: ((AXUIElement) -> Void)?
    var onRecord: ((AXUIElement) -> Void)?
    /// Whether a recording is running (the record button then reads "Stop recording").
    var isRecording: () -> Bool = { false }

    private let ax: AccessibilityManager
    private let constraints: WindowConstraintController
    private let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: true)
    private let container = NSView()
    private let chip = GlassChipView()
    private let pill = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let widthBox = FieldCapsule(name: "Width")
    private let heightBox = FieldCapsule(name: "Height")
    private var widthField: NSTextField { widthBox.field }
    private var heightField: NSTextField { heightBox.field }
    private var lockW: HoverButton!
    private var lockH: HoverButton!
    private var ratioChip: RatioChip!
    private var shotButton: CaptureButton!
    private var recordButton: CaptureButton!
    private var window: AXUIElement?
    private var closing = false
    private let tween = Tween()

    // Morph geometry (screen coordinates) and per-layer style, applied every frame.
    private var anchorRight = true
    private var pillSize = CGSize.zero
    private var pillLabelFrame = CGRect.zero
    private var barSize = CGSize.zero
    private var shellFrame = CGRect.zero
    private var pillStyle = (opacity: 1.0, blur: 0.0, scale: 1.0)
    private var barStyle = (opacity: 0.0, blur: 6.0, scale: 0.94)
    private let margin: CGFloat = 40 // room for the overshoot and the 30 pt shadow

    init(ax: AccessibilityManager, constraints: WindowConstraintController) {
        self.ax = ax
        self.constraints = constraints
        super.init()
        lockW = HoverButton(target: self, action: #selector(toggleWidth))
        lockH = HoverButton(target: self, action: #selector(toggleHeight))
        ratioChip = RatioChip(target: self, action: #selector(showRatioMenu))
        let apply = ApplyButton(target: self, action: #selector(applyAndClose))

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the shell casts its own (animated) shadow
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        func group(_ views: [NSView], spacing: CGFloat) -> NSStackView {
            let g = NSStackView(views: views)
            g.spacing = spacing
            g.alignment = .centerY
            return g
        }
        let divider = Divider()
        let sizes = group([group([Self.label("W"), widthBox, lockW], spacing: 6), Self.label("×", dim: true),
                           group([Self.label("H"), heightBox, lockH], spacing: 6)], spacing: 8)
        shotButton = CaptureButton(kind: .screenshot, target: self, action: #selector(screenshotWindow))
        recordButton = CaptureButton(kind: .record, target: self, action: #selector(recordWindow))
        for view in [sizes, divider, group([ratioChip, apply], spacing: 8), Divider(),
                     group([shotButton, recordButton], spacing: 4)] { stack.addArrangedSubview(view) }
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)
        pill.maximumNumberOfLines = 0
        chip.content.addSubview(pill)
        chip.content.addSubview(stack)
        chip.layer?.shadowColor = NSColor.black.cgColor
        chip.layer?.shadowOpacity = 0.35
        chip.layer?.shadowRadius = 15 // CSS: 0 10px 30px rgba(0,0,0,.35)
        chip.layer?.shadowOffset = CGSize(width: 0, height: -10)
        container.addSubview(chip)
        panel.contentView = container

        lockW.toolTip = "Keep width fixed while resizing"
        lockH.toolTip = "Keep height fixed while resizing"
        ratioChip.toolTip = "Aspect ratio — keeps proportions while typing and resizing"
        apply.toolTip = "Set size (Return)"
        shotButton.toolTip = "Screenshot this window. Wize is left out of the image."
        for field in [widthField, heightField] { field.delegate = self }
        widthField.nextKeyView = heightField
        heightField.nextKeyView = widthField
    }

    /// Opens by morphing out of the badge's pill at `window`'s corner (also when opened from the menu, as in
    /// the design: the shell always starts as the pill).
    func show(for window: AXUIElement) {
        guard let axFrame = ax.frame(of: window),
              let (frame, screen) = AccessibilityManager.placement(forAX: axFrame) else { return NSSound.beep() }
        self.window = window
        present(axFrame: axFrame, frame: frame, visible: screen.visibleFrame)
    }

    /// The opening morph for a window at `frame` (Cocoa) / `axFrame` (AX).
    private func present(axFrame: CGRect, frame: CGRect, visible: CGRect) {
        tween.stop()
        closing = false
        widthField.stringValue = "\(Int(axFrame.width.rounded()))"
        heightField.stringValue = "\(Int(axFrame.height.rounded()))"
        refresh()
        recordButton.toolTip = isRecording() ? "Stop recording" : "Record this window. Wize is left out of the video."
        onOpen?()

        barSize = stack.fittingSize
        // Too narrow for the bar inside the window: both go outside (below/above), as in the design.
        let outside = Settings.outside || barSize.width + 24 > frame.width
        let lock = window.map(constraints.lock(for:)) ?? WindowLockState()
        let pillRect = setPill(size: axFrame.size, lock: lock, window: frame, bounds: visible, outside: outside)
        let barRect = CGRect(origin: OverlayPlacement.origin(size: barSize, window: frame, bounds: visible,
                                                            outside: outside), size: barSize)
        anchorRight = Settings.corner == .bottomRight || Settings.corner == .topRight
        cover(pillRect.union(barRect))
        shellFrame = pillRect
        pillStyle = (1, 0, 1)
        barStyle = (0, 6, 0.94)
        layoutShell()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(widthField) // selects the value, ready to type over

        tween.run(on: container, [
            .init(duration: 0.44, curve: .shell) { [unowned self] p in shellFrame = lerp(pillRect, barRect, p); layoutShell() },
            .init(duration: 0.22) { [unowned self] p in pillStyle.opacity = 1 - p; pillStyle.blur = 4 * p; layoutShell() },
            .init(duration: 0.30) { [unowned self] p in pillStyle.scale = lerp(1, 0.9, p); layoutShell() },
            .init(delay: 0.13, duration: 0.26) { [unowned self] p in barStyle.opacity = p; barStyle.blur = 6 * (1 - p); layoutShell() },
            .init(delay: 0.13, duration: 0.36, curve: .pop) { [unowned self] p in barStyle.scale = lerp(0.94, 1, p); layoutShell() },
        ]) { [unowned self] in refreshToolTips() }
    }

    /// Tooltip areas are registered from the views' frames when set; they went stale while the bar moved
    /// during the morph (the ✓ tooltip appeared over the W field). Re-register at the settled layout.
    private func refreshToolTips() {
        for view in [lockW!, lockH!, ratioChip!] as [NSView] + stackButtons() {
            let tip = view.toolTip
            view.toolTip = nil
            view.toolTip = tip
        }
    }

    private func stackButtons() -> [NSView] {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return all(stack).filter { $0 is NSButton }
    }

    /// Reverse morph to the pill at the window's (possibly new) corner, then hand back to the real badge.
    private func close() {
        guard let window, !closing else { return }
        closing = true
        self.window = nil
        let from = shellFrame
        var to = from
        if let axFrame = ax.frame(of: window), let (frame, screen) = AccessibilityManager.placement(forAX: axFrame) {
            let outside = Settings.outside || barSize.width + 24 > frame.width
            to = setPill(size: axFrame.size, lock: constraints.lock(for: window), window: frame,
                         bounds: screen.visibleFrame, outside: outside)
            cover(from.union(to))
        }
        let start = (bar: barStyle, pill: pillStyle)
        tween.run(on: container, [
            .init(duration: 0.44, curve: .shell) { [unowned self] p in shellFrame = lerp(from, to, p); layoutShell() },
            .init(duration: 0.26) { [unowned self] p in
                barStyle.opacity = lerp(start.bar.opacity, 0, p); barStyle.blur = lerp(start.bar.blur, 6, p); layoutShell()
            },
            .init(duration: 0.36, curve: .pop) { [unowned self] p in barStyle.scale = lerp(start.bar.scale, 0.94, p); layoutShell() },
            .init(delay: 0.17, duration: 0.22) { [unowned self] p in
                pillStyle.opacity = lerp(start.pill.opacity, 1, p); pillStyle.blur = lerp(start.pill.blur, 0, p); layoutShell()
            },
            .init(delay: 0.17, duration: 0.30) { [unowned self] p in pillStyle.scale = lerp(start.pill.scale, 1, p); layoutShell() },
        ]) { [unowned self] in
            closing = false
            onClose?(window) // the real badge appears in the pill's exact spot…
            DispatchQueue.main.async { MainActor.assumeIsolated { if self.window == nil { self.panel.orderOut(nil) } } }
            if !Settings.overlayEnabled { panel.orderOut(nil) } // …or there's no badge to hand over to
        }
    }

    /// Lays out the pill text for `size` exactly like the badge and returns the pill's screen rect.
    /// `lock` is passed in: on close `self.window` is already cleared, and a pill drawn without the lock
    /// glyphs would be narrower than the badge it hands over to (a visible jump).
    private func setPill(size: CGSize, lock: WindowLockState, window: CGRect, bounds: CGRect, outside: Bool) -> CGRect {
        pill.attributedStringValue = OverlayPanel.content(size: size, position: nil, lock: lock)
        let layout = OverlayPanel.layout(pill)
        pillSize = layout.size
        pillLabelFrame = layout.label
        return CGRect(origin: OverlayPlacement.origin(size: pillSize, window: window, bounds: bounds, outside: outside),
                      size: pillSize)
    }

    /// Sizes the (static, transparent) panel to contain `rect` plus margin; the shell moves inside it.
    private func cover(_ rect: CGRect) {
        let target = rect.union(panel.isVisible ? panel.frame.insetBy(dx: margin, dy: margin) : rect)
            .insetBy(dx: -margin, dy: -margin)
        if panel.frame != target { panel.setFrame(target, display: false) }
    }

    /// Applies the current shell frame and both layers' styles. Called every animation frame.
    private func layoutShell() {
        let f = shellFrame.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
        chip.frame = f
        chip.cornerRadius = f.height / 2
        chip.layoutSubtreeIfNeeded()
        chip.layer?.shadowPath = CGPath(roundedRect: chip.bounds, cornerWidth: f.height / 2, cornerHeight: f.height / 2,
                                        transform: nil)
        // Both layers stay pinned to the anchored side and vertically centered while the shell resizes.
        let pillX = anchorRight ? f.width - pillSize.width : 0
        pill.frame = pillLabelFrame.offsetBy(dx: pillX, dy: (f.height - pillSize.height) / 2)
        stack.frame = CGRect(x: anchorRight ? f.width - barSize.width : 0, y: (f.height - barSize.height) / 2,
                             width: barSize.width, height: barSize.height)
        // Transform origin at the anchored side's center, as in the design (`right center` / `left center`).
        let pad = pillLabelFrame.minX
        Style.set(pill, opacity: pillStyle.opacity, blur: pillStyle.blur, scale: pillStyle.scale,
                  origin: CGPoint(x: anchorRight ? pill.bounds.width + pad : -pad, y: pill.bounds.height / 2))
        Style.set(stack, opacity: barStyle.opacity, blur: barStyle.blur, scale: barStyle.scale,
                  origin: CGPoint(x: anchorRight ? stack.bounds.width : 0, y: stack.bounds.height / 2))
        // Only the visible bar takes clicks (the pill layer is display-only).
        stack.isHidden = barStyle.opacity < 0.01
    }

    @objc private func screenshotWindow() { applyAndCapture(onScreenshot) }
    @objc private func recordWindow() { applyAndCapture(onRecord) }

    private func applyAndCapture(_ action: ((AXUIElement) -> Void)?) {
        guard let target = window, commit() else { return NSSound.beep() }
        close()
        action?(target)
    }

    @objc private func applyAndClose() {
        guard commit() else { return NSSound.beep() }
        close()
    }

    /// Applies the fields; false if they aren't a valid size.
    private func commit() -> Bool {
        guard let window,
              let w = Int(widthField.stringValue), let h = Int(heightField.stringValue),
              (1...32_767).contains(w), (1...32_767).contains(h) else { return false }
        // The app enforces its own min/max; the overlay then shows what it actually accepted.
        if !constraints.apply(CGSize(width: w, height: h), to: window) { NSSound.beep() }
        return true
    }

    // MARK: Locks (immediate, exclusive)

    @objc private func toggleWidth() {
        updateLock { lock, size in
            lock.width = lock.width == nil ? size.width : nil
            lock.aspect = nil
        }
        Motion.bounce(lockW)
    }

    @objc private func toggleHeight() {
        updateLock { lock, size in
            lock.height = lock.height == nil ? size.height : nil
            lock.aspect = nil
        }
        Motion.bounce(lockH)
    }

    private func updateLock(_ change: (inout WindowLockState, CGSize) -> Void) {
        guard let window, let size = ax.frame(of: window)?.size.rounded else { return }
        var lock = constraints.lock(for: window)
        change(&lock, size)
        constraints.setLock(lock, for: window)
        refresh()
    }

    // MARK: Ratio menu

    private var fieldSize: CGSize {
        CGSize(width: Double(widthField.stringValue) ?? 0, height: Double(heightField.stringValue) ?? 0)
    }

    @objc private func showRatioMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let lock = window.map(constraints.lock(for:)) ?? WindowLockState()
        let locked = lock.aspect.map(WindowLockState.ratioText)
        func add(_ title: String, _ value: CGSize?) {
            let item = menu.addItem(withTitle: title, action: #selector(pickRatio(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value.map { NSValue(size: $0) }
            item.state = locked == value.map(WindowLockState.ratioText) ? .on : .off
        }
        add("Free", nil)
        let current = WindowLockState.ratioText(fieldSize)
        if fieldSize.width > 0, fieldSize.height > 0,
           !WindowLockState.commonRatios.contains(where: { WindowLockState.ratioText($0) == current }) {
            add("Current  \(current)", fieldSize)
        }
        for ratio in WindowLockState.commonRatios { add(WindowLockState.ratioText(ratio), ratio) }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Presets"))
        for (index, preset) in WindowSizePreset.all.enumerated() {
            let item = menu.addItem(withTitle: "", action: #selector(pickPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.setTitle("\(preset.width) × \(preset.height)", detail: preset.name)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: ratioChip.bounds.height + 6), in: ratioChip)
    }

    @objc private func pickRatio(_ sender: NSMenuItem) {
        let ratio = (sender.representedObject as? NSValue)?.sizeValue
        updateLock { lock, _ in
            lock.aspect = ratio
            if ratio != nil { lock.width = nil; lock.height = nil }
        }
        if let ratio, let w = Double(widthField.stringValue), w > 0 {
            heightField.stringValue = "\(Int((w * ratio.height / ratio.width).rounded()))"
        }
        Motion.bounce(ratioChip)
        panel.makeFirstResponder(widthField)
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        let presets = WindowSizePreset.all
        guard presets.indices.contains(sender.tag) else { return }
        let preset = presets[sender.tag]
        widthField.stringValue = "\(preset.width)"
        heightField.stringValue = "\(preset.height)"
        // With a ratio locked, the preset's shape becomes the new ratio (design: ar = preset w/h).
        updateLock { lock, _ in if lock.aspect != nil { lock.aspect = preset.size } }
        panel.makeFirstResponder(widthField)
    }

    // MARK: Appearance

    private func refresh() {
        let lock = window.map(constraints.lock(for:)) ?? WindowLockState()
        lockW.setLocked(lock.width != nil)
        lockH.setLocked(lock.height != nil)
        widthField.textColor = lock.width != nil ? Palette.accentText : .labelColor
        heightField.textColor = lock.height != nil ? Palette.accentText : .labelColor
        ratioChip.title = lock.aspectIsActive ? lock.aspect.map(WindowLockState.ratioText) ?? "Free" : "Free"
        ratioChip.isLocked = lock.aspectIsActive
    }

    private static func label(_ text: String, dim: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13)
        l.textColor = dim ? .tertiaryLabelColor : .secondaryLabelColor
        return l
    }

    // MARK: Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): applyAndClose()
        case #selector(NSResponder.cancelOperation(_:)): close()
        case #selector(NSResponder.moveUp(_:)): step(control, by: 1)
        case #selector(NSResponder.moveDown(_:)): step(control, by: -1)
        case #selector(NSResponder.moveUpAndModifySelection(_:)): step(control, by: 10)
        case #selector(NSResponder.moveDownAndModifySelection(_:)): step(control, by: -10)
        default: return false
        }
        return true
    }

    private func step(_ control: NSControl, by delta: Int) {
        guard let field = control as? NSTextField else { return }
        field.stringValue = "\(max(1, (Int(field.stringValue) ?? 0) + delta))"
        fieldChanged(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        let digits = String(field.stringValue.filter { $0.isASCII && $0.isNumber }.prefix(5))
        if digits != field.stringValue { field.stringValue = digits }
        fieldChanged(field)
    }

    /// With a ratio locked, one dimension derives the other.
    private func fieldChanged(_ field: NSTextField) {
        refresh()
        guard let window, let ratio = constraints.lock(for: window).aspect,
              constraints.lock(for: window).aspectIsActive, let v = Double(field.stringValue), v > 0 else { return }
        let r = ratio.width / ratio.height
        if field === widthField {
            heightField.stringValue = "\(Int((v / r).rounded()))"
        } else {
            widthField.stringValue = "\(Int((v * r).rounded()))"
        }
    }

    /// Clicking outside applies (design), unless the fields are invalid.
    func windowDidResignKey(_ notification: Notification) {
        guard window != nil, !closing else { return }
        _ = commit()
        close()
    }
}

// MARK: - Controls (drawn, so dynamic colors follow Light/Dark)

@MainActor private func isDark(_ view: NSView) -> Bool {
    view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
}

/// 62×28 recessed capsule around a borderless number field; accent glow while editing.
private final class FieldCapsule: NSView {
    let field = NumberField(string: "")
    private var focused = false { didSet { needsDisplay = true } }

    init(name: String) {
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        field.setAccessibilityLabel(name)
        field.onFocusChange = { [weak self] in self?.focused = $0 }
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 62),
            heightAnchor.constraint(equalToConstant: 28),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        (isDark(self) ? NSColor(white: 0, alpha: 0.28) : NSColor(white: 0, alpha: 0.07)).setFill()
        path.fill()
        if focused {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 12.5, yRadius: 12.5)
            ring.lineWidth = 3
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            ring.stroke()
        }
    }
}

private final class NumberField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

/// 26 pt round lock toggle with a hover wash.
private final class HoverButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }

    convenience init(target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .imageOnly
        refusesFirstResponder = true // Tab stays between the two fields
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        setLocked(false)
    }

    func setLocked(_ locked: Bool) {
        image = NSImage(systemSymbolName: locked ? "lock.fill" : "lock.open", accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        contentTintColor = locked ? .controlAccentColor : .secondaryLabelColor
        state = locked ? .on : .off
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            // Always a circle: the stack can stretch the button taller than wide.
            let d = min(bounds.width, bounds.height, 26)
            let circle = CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
            (isDark(self) ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.06)).setFill()
            NSBezierPath(ovalIn: circle).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Ratio chip: 28 pt capsule, tinted while a ratio is locked, with the blue chevron disc on the right.
private final class RatioChip: NSButton {
    var isLocked = false { didSet { needsDisplay = true } }
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private let font13 = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    convenience init(target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        refusesFirstResponder = true
        title = "Free"
    }

    override var intrinsicContentSize: NSSize {
        let text = max(40, (title as NSString).size(withAttributes: [.font: font13]).width)
        return NSSize(width: 12 + ceil(text) + 6 + 20 + 4, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = isDark(self)
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        (isLocked ? NSColor.controlAccentColor.withAlphaComponent(dark ? 0.28 : 0.16)
                  : dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.06)).setFill()
        capsule.fill()
        let textColor: NSColor = isLocked ? (dark ? NSColor(srgbRed: 0xa9 / 255, green: 0xd2 / 255, blue: 1, alpha: 1)
                                                  : Palette.accentText) : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font13, .foregroundColor: textColor]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: CGPoint(x: 12, y: (bounds.height - size.height) / 2), withAttributes: attrs)

        let disc = CGRect(x: bounds.maxX - 24, y: (bounds.height - 20) / 2, width: 20, height: 20)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: disc).fill()
        if let chevron = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold).applying(.init(paletteColors: [.white]))) {
            chevron.draw(in: CGRect(x: disc.midX - chevron.size.width / 2, y: disc.midY - chevron.size.height / 2,
                                    width: chevron.size.width, height: chevron.size.height))
        }
    }
}

/// 28 pt accent disc with a checkmark and a soft accent glow.
private final class ApplyButton: NSButton {
    convenience init(target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        refusesFirstResponder = true
        title = ""
        setAccessibilityLabel("Apply")
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        wantsLayer = true
        shadow = NSShadow()
        layer?.shadowColor = NSColor.controlAccentColor.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    override func draw(_ dirtyRect: NSRect) {
        (isHighlighted ? NSColor.controlAccentColor.shadow(withLevel: 0.2) ?? .controlAccentColor
                       : NSColor.controlAccentColor).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        if let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold).applying(.init(paletteColors: [.white]))) {
            check.draw(in: CGRect(x: bounds.midX - check.size.width / 2, y: bounds.midY - check.size.height / 2,
                                  width: check.size.width, height: check.size.height))
        }
    }
}

/// 28 pt round icon button with a hover wash: camera (screenshot) or a ring with a red dot (record).
private final class CaptureButton: NSButton {
    enum Kind { case screenshot, record }
    private var kind = Kind.screenshot
    private var hovering = false { didSet { needsDisplay = true } }

    convenience init(kind: Kind, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.kind = kind
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        refusesFirstResponder = true
        setAccessibilityLabel(kind == .screenshot ? "Screenshot window" : "Record window")
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            (isDark(self) ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.07)).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        switch kind {
        case .screenshot:
            if let camera = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular).applying(.init(paletteColors: [.labelColor]))) {
                camera.draw(in: CGRect(x: c.x - camera.size.width / 2, y: c.y - camera.size.height / 2,
                                       width: camera.size.width, height: camera.size.height))
            }
        case .record:
            let ring = NSBezierPath(ovalIn: CGRect(x: c.x - 6.35, y: c.y - 6.35, width: 12.7, height: 12.7))
            ring.lineWidth = 1.3
            NSColor.labelColor.setStroke()
            ring.stroke()
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)).fill()
        }
    }
}

/// 1×18 hairline between the size and ratio groups.
private final class Divider: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 18) }
    override func draw(_ dirtyRect: NSRect) {
        (isDark(self) ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.12)).setFill()
        bounds.fill()
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

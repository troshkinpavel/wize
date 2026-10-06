import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let ax: AccessibilityManager
    private let constraints: WindowConstraintController
    private let editor: SizeEditorPanel
    private let onSettingsChanged: () -> Void
    private let settingsWindow = SettingsWindow()
    var capture: CaptureController?
    /// The window the open menu was built for; actions target it even if focus shifts meanwhile.
    private var menuWindow: AXUIElement?

    init(ax: AccessibilityManager, constraints: WindowConstraintController, editor: SizeEditorPanel,
         onSettingsChanged: @escaping () -> Void) {
        self.ax = ax
        self.constraints = constraints
        self.editor = editor
        self.onSettingsChanged = onSettingsChanged
        super.init()
        settingsWindow.onChange = onSettingsChanged
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                                           accessibilityDescription: "Wize")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    /// Rebuilt on every open so it always reflects the focused window and current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if ax.isTrusted {
            addWindowControls(menu)
        } else {
            info(menu, "⚠︎ Accessibility access required")
            item(menu, "Grant Access…", #selector(openAccessibility))
        }
        menu.addItem(.separator())

        item(menu, "Show Size Overlay", #selector(toggleOverlay)).state = Settings.overlayEnabled ? .on : .off
        let autoHide = item(menu, "Auto-hide When Idle", #selector(toggleAutoHide))
        autoHide.state = Settings.autoHide ? .on : .off
        autoHide.isEnabled = Settings.overlayEnabled
        let positions = NSMenu()
        for corner in OverlayCorner.allCases {
            let i = item(positions, corner.title, #selector(setCorner(_:)))
            i.representedObject = corner.rawValue
            i.state = Settings.corner == corner ? .on : .off
        }
        positions.addItem(.separator())
        item(positions, "Inside Window", #selector(setPlacement(_:))).state = Settings.outside ? .off : .on
        let outside = item(positions, "Outside Window", #selector(setPlacement(_:)))
        outside.state = Settings.outside ? .on : .off
        outside.tag = 1
        menu.addItem(withTitle: "Overlay Position", action: nil, keyEquivalent: "").submenu = positions

        menu.addItem(.separator())
        item(menu, "Settings…", #selector(openSettings), key: ",")
        item(menu, "Quit Wize", #selector(NSApplication.terminate(_:)), key: "q").target = NSApp
    }

    // MARK: Focused window section

    private func addWindowControls(_ menu: NSMenu) {
        constraints.prune()
        menuWindow = ax.refreshFocusedWindow()
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Focused Window"
        menu.addItem(.sectionHeader(title: appName))

        guard let window = menuWindow, let size = ax.frame(of: window)?.size.rounded else {
            info(menu, "No focused window")
            return
        }
        let sizeRow = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        sizeRow.setTitle("\(Int(size.width)) × \(Int(size.height))", detail: WindowLockState.ratioText(size), dimmed: true)
        sizeRow.isEnabled = false

        let settable = ax.isSizeSettable(window)
        if !settable { info(menu, "This window's size can't be changed") }
        let edit = item(menu, "Edit Size…", #selector(editSize))
        edit.isEnabled = settable
        // Shows the global shortcut (handled by HotKey, so it works with any app in front).
        let shortcut = Shortcut.editSize
        edit.keyEquivalent = shortcut.key.lowercased()
        edit.keyEquivalentModifierMask = shortcut.modifiers
        item(menu, "Screenshot Window", #selector(screenshotWindow))
        item(menu, capture?.isRecording == true ? "Stop Recording" : "Record Window", #selector(recordWindow))
        menu.addItem(.separator())

        let lock = constraints.lock(for: window)
        func lockItem(_ title: String, _ detail: String, on: Bool, _ action: Selector) {
            let i = item(menu, title, action)
            i.setTitle(title, detail: detail)
            i.state = on ? .on : .off
            i.isEnabled = settable
        }
        lockItem("Lock Width", "\(Int(lock.width ?? size.width))", on: lock.width != nil, #selector(toggleWidth))
        lockItem("Lock Height", "\(Int(lock.height ?? size.height))", on: lock.height != nil, #selector(toggleHeight))
        lockItem("Lock Aspect Ratio", WindowLockState.ratioText(lock.aspect ?? size),
                 on: lock.aspect != nil, #selector(toggleAspect))

        let presets = NSMenu()
        presets.autoenablesItems = false
        for (index, preset) in WindowSizePreset.all.enumerated() {
            let apply = item(presets, preset.title, #selector(applyPreset(_:)))
            apply.setTitle("\(preset.width) × \(preset.height)", detail: preset.name)
            apply.tag = index
            apply.isEnabled = settable
            apply.state = preset.size == size ? .on : .off
            // ⌥ / ⌥⇧ reveal rename / delete in place, so there's no preset-management screen.
            let label = preset.name.isEmpty ? preset.title : preset.name
            let rename = item(presets, "Rename “\(label)”…", #selector(renamePreset(_:)))
            rename.tag = index
            rename.isAlternate = true
            rename.keyEquivalentModifierMask = .option
            let delete = item(presets, "Delete “\(label)”", #selector(deletePreset(_:)))
            delete.tag = index
            delete.isAlternate = true
            delete.keyEquivalentModifierMask = [.option, .shift]
        }
        presets.addItem(.separator())
        item(presets, "Save Current Size…", #selector(saveCurrentSize))
        info(presets, "Hold ⌥ to rename, ⌥⇧ to delete")
        menu.addItem(withTitle: "Presets", action: nil, keyEquivalent: "").submenu = presets
    }

    // Exclusive, as in the design: W/H locks clear the aspect lock and vice versa.
    @objc private func toggleWidth() { updateLock { $0.width = $0.width == nil ? $1.width : nil; $0.aspect = nil } }
    @objc private func toggleHeight() { updateLock { $0.height = $0.height == nil ? $1.height : nil; $0.aspect = nil } }
    @objc private func toggleAspect() {
        updateLock { $0.aspect = $0.aspect == nil ? $1 : nil; $0.width = nil; $0.height = nil }
    }

    private func updateLock(_ change: (inout WindowLockState, CGSize) -> Void) {
        guard let window = menuWindow, let size = ax.frame(of: window)?.size.rounded else { return }
        var lock = constraints.lock(for: window)
        change(&lock, size)
        constraints.setLock(lock, for: window)
        onSettingsChanged() // redraw a persistent badge with the new lock state
    }

    @objc private func screenshotWindow() {
        guard let window = menuWindow else { return }
        // After the menu closes, so it can't end up in the capture timing.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.capture?.screenshot(window) } }
    }

    @objc private func recordWindow() {
        if capture?.isRecording == true { return capture?.stopRecording() ?? () }
        guard let window = menuWindow else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.capture?.startRecording(window) } }
    }

    @objc private func editSize() {
        guard let window = menuWindow else { return }
        // Let the menu finish closing before a panel takes key.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.editor.show(for: window) } }
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        let presets = WindowSizePreset.all
        guard let window = menuWindow, presets.indices.contains(sender.tag) else { return }
        if !constraints.apply(presets[sender.tag].size, to: window) { NSSound.beep() }
    }

    @objc private func saveCurrentSize() {
        guard let window = menuWindow, let size = ax.frame(of: window)?.size.rounded else { return }
        let w = Int(size.width), h = Int(size.height)
        guard let name = prompt("Save \(w) × \(h) as a preset", value: "") else { return }
        WindowSizePreset.all.append(WindowSizePreset(name: name, width: w, height: h))
    }

    @objc private func renamePreset(_ sender: NSMenuItem) {
        var presets = WindowSizePreset.all
        guard presets.indices.contains(sender.tag),
              let name = prompt("Rename preset \(presets[sender.tag].width) × \(presets[sender.tag].height)",
                                value: presets[sender.tag].name) else { return }
        presets[sender.tag].name = name
        WindowSizePreset.all = presets
    }

    @objc private func deletePreset(_ sender: NSMenuItem) {
        var presets = WindowSizePreset.all
        guard presets.indices.contains(sender.tag) else { return }
        presets.remove(at: sender.tag)
        WindowSizePreset.all = presets
    }

    /// Small name prompt. Needs Wize active for typing; hands focus back to the previous app afterwards.
    private func prompt(_ message: String, info: String = "Name (optional)", value: String,
                        button: String = "Save") -> String? {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        let field = NSTextField(string: value)
        field.frame = CGRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        defer { previous?.activate() }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: App settings

    @discardableResult
    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func info(_ menu: NSMenu, _ title: String) {
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
    }

    @objc private func toggleOverlay() {
        Settings.overlayEnabled.toggle()
        onSettingsChanged()
    }

    @objc private func setCorner(_ sender: NSMenuItem) {
        Settings.corner = OverlayCorner(rawValue: sender.representedObject as? String ?? "") ?? .bottomRight
        onSettingsChanged()
    }

    @objc private func setPlacement(_ sender: NSMenuItem) {
        Settings.outside = sender.tag == 1
        onSettingsChanged()
    }

    @objc private func toggleAutoHide() {
        Settings.autoHide.toggle()
        onSettingsChanged()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openAccessibility() {
        AccessibilityManager.openSettings()
    }
}

extension NSMenuItem {
    /// Title with a secondary, right-aligned detail column (`Lock Width      1314`).
    func setTitle(_ title: String, detail: String, dimmed: Bool = false) {
        self.title = title // plain title stays for accessibility and type-select
        guard !detail.isEmpty else { return }
        let font = NSFont.menuFont(ofSize: 0)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 200)]
        var base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
        if dimmed { base[.foregroundColor] = NSColor.secondaryLabelColor }
        let text = NSMutableAttributedString(string: "\(title)\t", attributes: base)
        base[.foregroundColor] = dimmed ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor
        text.append(NSAttributedString(string: detail, attributes: base))
        attributedTitle = text
    }
}

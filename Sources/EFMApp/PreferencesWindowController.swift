import AppKit
import EFMCore

/// Preferences (⌘,). Index settings (root, ignore list, other volumes) are staged and applied
/// with "Apply & Rescan"; the rest take effect immediately.
final class PreferencesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    /// Called after index settings were saved: (rootChanged).
    var onApplyIndexSettings: ((Bool) -> Void)?

    private let settings = Settings.shared
    private let rootField = NSTextField()
    private let ignoreTable = NSTableView()
    private let crossDevices = NSButton(checkboxWithTitle: "Index other volumes (external disks, network shares)", target: nil, action: nil)
    private let caseDefault = NSButton(checkboxWithTitle: "Match case by default", target: nil, action: nil)
    private let hideDock = NSButton(checkboxWithTitle: "Hide Dock icon", target: nil, action: nil)
    private let showStatus = NSButton(checkboxWithTitle: "Show menu-bar icon", target: nil, action: nil)
    private let hotKey = NSButton(checkboxWithTitle: "Global shortcut ⌘⇧Space shows EFM", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply & Rescan", target: nil, action: nil)
    private var ignores: [String] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "EFM Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        load()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 380
        return l
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        rootField.placeholderString = "/"
        rootField.delegate = self
        rootField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseRoot))
        let rootRow = NSStackView(views: [rootField, choose])
        rootRow.spacing = 6

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        col.title = "Path"
        col.resizingMask = .autoresizingMask
        ignoreTable.addTableColumn(col)
        ignoreTable.headerView = nil
        ignoreTable.dataSource = self
        ignoreTable.delegate = self
        ignoreTable.rowHeight = 20
        ignoreTable.usesAlternatingRowBackgroundColors = true
        ignoreTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        ignoreTable.style = .fullWidth
        let scroll = NSScrollView()
        scroll.documentView = ignoreTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        let plusMinus = NSSegmentedControl(images: [
            NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
            NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
        ], trackingMode: .momentary, target: self, action: #selector(plusMinus(_:)))
        plusMinus.segmentStyle = .smallSquare
        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetIgnores))
        reset.controlSize = .small
        reset.bezelStyle = .push
        let ignoreButtons = NSStackView(views: [plusMinus, NSView(), reset])
        ignoreButtons.distribution = .fill
        let ignoreBox = NSStackView(views: [scroll, ignoreButtons])
        ignoreBox.orientation = .vertical
        ignoreBox.alignment = .leading
        ignoreBox.spacing = 4
        ignoreButtons.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true

        crossDevices.target = self
        applyButton.target = self
        applyButton.action = #selector(applyIndexSettings)
        applyButton.bezelStyle = .push

        for b in [caseDefault, hideDock, showStatus, hotKey] {
            b.target = self
            b.action = #selector(toggleChanged(_:))
        }

        let grid = NSGridView(views: [
            [label("Watch folder:"), rootRow],
            [NSGridCell.emptyContentView, note("The folder tree to index. \"/\" indexes the whole startup disk.")],
            [label("Ignore paths:"), ignoreBox],
            [NSGridCell.emptyContentView, crossDevices],
            [NSGridCell.emptyContentView, applyButton],
            [NSGridCell.emptyContentView, NSBox.separator()],
            [label("Search:"), caseDefault],
            [label("Appearance:"), hideDock],
            [NSGridCell.emptyContentView, showStatus],
            [label("Shortcut:"), hotKey],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 2).rowAlignment = .none
        grid.row(at: 2).yPlacement = .top
        grid.row(at: 5).topPadding = 4
        grid.row(at: 5).bottomPadding = 4
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        content.layoutSubtreeIfNeeded()
        let fit = grid.fittingSize
        window?.setContentSize(NSSize(width: max(520, fit.width + 40), height: fit.height + 40))
    }

    func load() {
        rootField.stringValue = settings.watchRoot
        ignores = settings.ignorePaths(for: settings.watchRoot)
        ignoreTable.reloadData()
        crossDevices.state = settings.crossDevices ? .on : .off
        caseDefault.state = settings.caseSensitiveDefault ? .on : .off
        hideDock.state = settings.hideDockIcon ? .on : .off
        showStatus.state = settings.showStatusItem ? .on : .off
        showStatus.isEnabled = !settings.hideDockIcon
        hotKey.state = settings.globalHotKeyEnabled ? .on : .off
    }

    // MARK: Actions

    @objc private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: Settings.normalize(rootField.stringValue) ?? "/")
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.rootField.stringValue = url.path
        }
    }

    @objc private func plusMinus(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            ignores.append("")
            ignoreTable.reloadData()
            let row = ignores.count - 1
            ignoreTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            ignoreTable.editColumn(0, row: row, with: nil, select: true)
        } else {
            let rows = ignoreTable.selectedRowIndexes
            guard !rows.isEmpty else { NSSound.beep(); return }
            window?.makeFirstResponder(nil)
            for r in rows.reversed() where r < ignores.count { ignores.remove(at: r) }
            ignoreTable.reloadData()
        }
    }

    @objc private func resetIgnores() {
        window?.makeFirstResponder(nil)
        let root = Settings.normalize(rootField.stringValue) ?? "/"
        ignores = settings.defaultIgnorePaths(for: root)
        ignoreTable.reloadData()
    }

    @objc private func applyIndexSettings() {
        window?.makeFirstResponder(nil) // commit in-progress edits
        guard let root = Settings.normalize(rootField.stringValue) else {
            let a = NSAlert()
            a.messageText = "The watch folder must be an absolute path."
            a.beginSheetModal(for: window!)
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            let a = NSAlert()
            a.messageText = "\"\(root)\" is not a folder."
            a.beginSheetModal(for: window!)
            return
        }
        let cleaned = ignores.compactMap(Settings.normalize)
        let rootChanged = root != settings.watchRoot
        settings.watchRoot = root
        settings.customIgnorePaths = Set(cleaned) == Set(settings.defaultIgnorePaths(for: root)) ? nil : cleaned
        settings.crossDevices = crossDevices.state == .on
        rootField.stringValue = root
        ignores = settings.ignorePaths(for: root)
        ignoreTable.reloadData()
        onApplyIndexSettings?(rootChanged)
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender {
        case caseDefault: settings.caseSensitiveDefault = on
        case hideDock:
            settings.hideDockIcon = on
            showStatus.state = settings.showStatusItem ? .on : .off
            showStatus.isEnabled = !on
        case showStatus: settings.showStatusItem = on
        case hotKey: settings.globalHotKeyEnabled = on
        default: break
        }
    }

    // MARK: Ignore list table

    func numberOfRows(in tableView: NSTableView) -> Int { ignores.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ignoreCell")
        let cell = tableView.reusableCell(id) { () -> NSTableCellView in
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField()
            tf.isBordered = false
            tf.drawsBackground = false
            tf.isEditable = true
            tf.lineBreakMode = .byTruncatingMiddle
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.delegate = self
            tf.placeholderString = "/path/to/ignore"
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }
        cell.textField?.stringValue = ignores[row]
        cell.textField?.tag = row
        return cell
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, tf !== rootField else { return }
        let row = ignoreTable.row(for: tf)
        guard row >= 0, row < ignores.count else { return }
        let value = tf.stringValue.trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            ignores.remove(at: row)
            ignoreTable.reloadData()
        } else {
            ignores[row] = value
        }
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }
}

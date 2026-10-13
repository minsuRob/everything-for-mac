import AppKit
import EFMCore
import Quartz

enum ResultsTab: Int {
    case files = 0
    case events = 1
}

/// The search window: search field + case toggle + Files/Recent-changes switch on top,
/// results table in the middle, status bar at the bottom.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSMenuItemValidation,
    FileTableViewOwner, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private(set) var store: IndexStore

    private let searchField = NSSearchField()
    private let caseButton = NSButton()
    private let tabControl = NSSegmentedControl()
    private let banner = PermissionBannerView()
    private let statusBar = StatusBarView()
    private let filesTable = FileTableView()
    private let eventsTable = FileTableView()
    private let filesScroll = NSScrollView()
    private let eventsScroll = NSScrollView()
    private let results: ResultsDataSource
    private let events = EventsDataSource()
    let history = SearchHistory()

    private let searchQueue = DispatchQueue(label: "efm.search", qos: .userInitiated)
    private var token: CancelToken?
    private var seq = 0
    private var query = ""
    private var caseSensitive: Bool
    private var sort: SearchSort
    private var tab: ResultsTab = .files
    private var bannerDismissed = false
    private var needsRefreshOnShow = false
    private var recallingHistory = false
    private var lastSearchElapsed: TimeInterval = 0
    private var lastRefreshAt = Date.distantPast
    private var refreshScheduled = false

    private var qlPanel: QLPreviewPanel?
    private var qlURLs: [URL] = []

    var onRescan: (() -> Void)?

    init(store: IndexStore) {
        self.store = store
        caseSensitive = Settings.shared.caseSensitiveDefault
        sort = Settings.shared.sortOrder
        results = ResultsDataSource(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "EFM"
        window.minSize = NSSize(width: 560, height: 300)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
        window.setFrameAutosaveName("EFMMainWindow")
        IconCache.shared.onIconLoaded = { [weak self] _ in self?.reloadVisibleNames() }
        updateIndexStatus()
        runSearch()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }

        searchField.placeholderString = "Search files and folders"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.font = .systemFont(ofSize: 14)
        searchField.controlSize = .large
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.focusRingType = .default
        (searchField.cell as? NSSearchFieldCell)?.maximumRecents = 0

        caseButton.bezelStyle = .texturedRounded
        caseButton.setButtonType(.pushOnPushOff)
        caseButton.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: "Match case")
        caseButton.toolTip = "Match case (⌥⌘C)"
        caseButton.state = caseSensitive ? .on : .off
        caseButton.target = self
        caseButton.action = #selector(caseButtonClicked(_:))
        caseButton.controlSize = .large

        tabControl.segmentCount = 2
        tabControl.trackingMode = .selectOne
        tabControl.setImage(NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Files"), forSegment: 0)
        tabControl.setImage(NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Recent changes"), forSegment: 1)
        tabControl.setToolTip("Files (⌘1)", forSegment: 0)
        tabControl.setToolTip("Recent changes (⌘2)", forSegment: 1)
        tabControl.selectedSegment = 0
        tabControl.controlSize = .large
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))

        let header = NSStackView(views: [searchField, caseButton, tabControl])
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        banner.isHidden = true
        banner.onOpenSettings = { FullDiskAccess.openSettings() }
        banner.onDismiss = { [weak self] in
            self?.bannerDismissed = true
            self?.banner.isHidden = true
        }

        configure(table: filesTable, scroll: filesScroll)
        results.installColumns(in: filesTable, sort: sort)
        filesTable.dataSource = results
        filesTable.delegate = results
        filesTable.autosaveName = "EFMResultsTable"
        filesTable.autosaveTableColumns = true
        results.onSortChange = { [weak self] s in self?.sortChanged(s) }
        results.onSelectionChange = { [weak self] in self?.selectionChanged() }

        configure(table: eventsTable, scroll: eventsScroll)
        events.installColumns(in: eventsTable)
        eventsTable.dataSource = events
        eventsTable.delegate = events
        eventsTable.autosaveName = "EFMEventsTable"
        eventsTable.autosaveTableColumns = true
        events.onSelectionChange = { [weak self] in self?.selectionChanged() }
        eventsScroll.isHidden = true

        let tables = NSView()
        for s in [filesScroll, eventsScroll] {
            s.translatesAutoresizingMaskIntoConstraints = false
            tables.addSubview(s)
            NSLayoutConstraint.activate([
                s.leadingAnchor.constraint(equalTo: tables.leadingAnchor),
                s.trailingAnchor.constraint(equalTo: tables.trailingAnchor),
                s.topAnchor.constraint(equalTo: tables.topAnchor),
                s.bottomAnchor.constraint(equalTo: tables.bottomAnchor),
            ])
        }
        tables.setContentHuggingPriority(.init(1), for: .vertical)
        tables.setContentCompressionResistancePriority(.init(1), for: .vertical)

        statusBar.onRescan = { [weak self] in self?.onRescan?() }

        let headerSep = NSBox()
        headerSep.boxType = .separator

        let stack = NSStackView(views: [header, headerSep, banner, tables, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for v in [header, headerSep, banner, tables, statusBar] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window?.initialFirstResponder = searchField
        results.setSortIndicator(filesTable, sort) // after column autosave restored widths
    }

    private func configure(table: FileTableView, scroll: NSScrollView) {
        table.owner = self
        table.style = .fullWidth
        table.rowSizeStyle = .custom
        table.rowHeight = CellStyle.rowHeight
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsTypeSelect = false // type-select would walk millions of rows
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = []
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked(_:))
        table.setDraggingSourceOperationMask([.copy, .link], forLocal: false)
        table.verticalMotionCanBeginDrag = true
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
    }

    // MARK: Window

    func show(focusSearch: Bool = true) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if focusSearch { focusSearchField(selectAll: true) }
        if needsRefreshOnShow {
            needsRefreshOnShow = false
            indexDidChange()
        }
    }

    var isVisibleAndKey: Bool { (window?.isVisible ?? false) && (window?.isKeyWindow ?? false) && NSApp.isActive }

    func hide() {
        if let p = qlPanel, p.isVisible { p.orderOut(nil) }
        window?.orderOut(nil)
        // Give focus back to the previous app unless another of our windows is still up.
        if !NSApp.windows.contains(where: { $0.isVisible && $0 !== window && $0.canBecomeKey && !($0 is NSPanel) }) {
            NSApp.hide(nil)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if needsRefreshOnShow {
            needsRefreshOnShow = false
            indexDidChange()
        }
    }

    @objc override func cancelOperation(_ sender: Any?) { hide() }

    private func focusSearchField(selectAll: Bool) {
        window?.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            let len = (searchField.stringValue as NSString).length
            editor.selectedRange = selectAll ? NSRange(location: 0, length: len) : NSRange(location: len, length: 0)
        }
    }

    // MARK: Store

    func setStore(_ newStore: IndexStore) {
        store = newStore
        results.store = newStore
        results.update(entries: [], highlights: [])
        filesTable.reloadData()
        events.update([], filter: "", caseSensitive: caseSensitive)
        eventsTable.reloadData()
        updateIndexStatus()
        runSearch()
    }

    /// Throttled (≈300 ms) notification that the index changed.
    func indexDidChange() {
        statusBar.pulseActivity()
        updateIndexStatus()
        guard window?.isVisible ?? false, !(NSApp.isHidden) else {
            needsRefreshOnShow = true
            return
        }
        // Huge result sets (e.g. the empty query over millions of files) take ~100 ms to
        // re-sort; back off so constant FSEvents traffic doesn't keep a core busy.
        let minGap = max(0.3, min(3.0, lastSearchElapsed * 8))
        let since = Date().timeIntervalSince(lastRefreshAt)
        if since < minGap {
            if !refreshScheduled {
                refreshScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + (minGap - since)) { [weak self] in
                    self?.refreshScheduled = false
                    self?.indexDidChange()
                }
            }
            return
        }
        lastRefreshAt = Date()
        if tab == .events { reloadEvents(keepSelection: true) }
        statusBar.setEventCount(store.recentEvents.count)
        runSearch(refresh: true)
    }

    func updateIndexStatus() {
        switch store.state {
        case .idle:
            statusBar.setIndexState("Starting…", tone: .busy)
        case .loading:
            statusBar.setIndexState("Loading index…", tone: .busy)
        case .scanning(let n):
            statusBar.setIndexState("Scanning… \(Formatting.number(n))", tone: .busy)
        case .ready:
            statusBar.setIndexState("\(Formatting.number(store.entryCount)) files indexed", tone: .ready)
        case .failed(let msg):
            statusBar.setIndexState("Index error: \(msg)", tone: .failed)
        }
    }

    func setPermissionBannerVisible(_ visible: Bool) {
        banner.isHidden = !visible || bannerDismissed
    }

    // MARK: Search

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        queryChanged(sender.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        queryChanged(searchField.stringValue)
    }

    private func queryChanged(_ q: String) {
        guard q != query else { return }
        query = q
        if !recallingHistory { history.inputChanged(q) }
        if tab == .events { reloadEvents(keepSelection: false) }
        runSearch()
    }

    private func setQuery(_ q: String) {
        recallingHistory = true
        searchField.stringValue = q
        queryChanged(q)
        recallingHistory = false
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: (q as NSString).length, length: 0)
        }
    }

    /// Cancels any in-flight search and starts a new one. `refresh` re-runs the same query
    /// after an index change and keeps the selected entries selected.
    private func runSearch(refresh: Bool = false) {
        token?.cancel()
        let t = CancelToken()
        token = t
        seq += 1
        let mySeq = seq
        let q = query
        let options = SearchOptions(caseSensitive: caseSensitive, sort: sort)
        let store = self.store
        let keep: [UInt32] = refresh ? filesTable.selectedRowIndexes.prefix(1000).compactMap { results.entry(at: $0) } : []

        searchQueue.async { [weak self] in
            guard !t.isCancelled else { return }
            let started = DispatchTime.now()
            do {
                let r = try store.search(q, options: options, token: t)
                // Wall time (includes building path ranks for path sorting) drives refresh back-off.
                let wall = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
                var keepRows = IndexSet()
                if !keep.isEmpty {
                    let wanted = Set(keep)
                    for (i, e) in r.entries.enumerated() where wanted.contains(e) {
                        keepRows.insert(i)
                        if keepRows.count == wanted.count { break }
                    }
                }
                DispatchQueue.main.async {
                    guard let self, mySeq == self.seq, store === self.store else { return }
                    self.lastSearchElapsed = wall
                    self.apply(r, refresh: refresh, keepRows: keepRows)
                }
            } catch let e as SearchError {
                if case .cancelled = e { return }
                DispatchQueue.main.async {
                    guard let self, mySeq == self.seq else { return }
                    self.statusBar.setResults(e.description, isError: true)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, mySeq == self.seq else { return }
                    self.statusBar.setResults("\(error)", isError: true)
                }
            }
        }
    }

    private func apply(_ r: SearchResult, refresh: Bool, keepRows: IndexSet) {
        let hadSelection = filesTable.numberOfSelectedRows > 0
        results.update(entries: r.entries, highlights: r.highlights)
        filesTable.reloadData()
        if refresh {
            if hadSelection || !keepRows.isEmpty {
                filesTable.selectRowIndexes(keepRows, byExtendingSelection: false)
            }
        } else {
            filesTable.deselectAll(nil)
            filesTable.scrollRowToVisible(0)
        }
        let n = r.entries.count
        statusBar.setResults("\(Formatting.number(n)) \(n == 1 ? "result" : "results") · \(Formatting.milliseconds(r.elapsed))")
        if tab == .files { refreshQuickLook() }
    }

    private func sortChanged(_ s: SearchSort) {
        sort = s
        Settings.shared.sortOrder = s
        runSearch(refresh: true)
    }

    @objc private func caseButtonClicked(_ sender: NSButton) {
        caseSensitive = sender.state == .on
        if tab == .events { reloadEvents(keepSelection: false) }
        runSearch()
    }

    @objc func toggleCaseSensitive(_ sender: Any?) {
        caseButton.state = caseButton.state == .on ? .off : .on
        caseButtonClicked(caseButton)
    }

    // MARK: Search field keys (history, ↓ into results, Enter, Esc)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            if let older = history.older() { setQuery(older) }
            return true
        case #selector(NSResponder.moveDown(_:)):
            if let newer = history.newer() {
                setQuery(newer)
            } else {
                focusActiveTable(selectFirstIfNone: true)
            }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Commit the query to history (Cardinal does the same) and move to the results.
            history.inputChanged(searchField.stringValue)
            focusActiveTable(selectFirstIfNone: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    private func focusActiveTable(selectFirstIfNone: Bool) {
        let table = activeTable
        guard table.numberOfRows > 0 else { return }
        window?.makeFirstResponder(table)
        if selectFirstIfNone && table.numberOfSelectedRows == 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        table.scrollRowToVisible(max(table.selectedRow, 0))
    }

    // MARK: Tabs

    private var activeTable: FileTableView { tab == .files ? filesTable : eventsTable }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        selectTab(ResultsTab(rawValue: sender.selectedSegment) ?? .files)
    }

    private func selectTab(_ t: ResultsTab) {
        tab = t
        tabControl.selectedSegment = t.rawValue
        filesScroll.isHidden = t != .files
        eventsScroll.isHidden = t != .events
        if t == .events { reloadEvents(keepSelection: false) }
        searchField.placeholderString = t == .files ? "Search files and folders" : "Filter recent changes"
        refreshQuickLook()
    }

    @objc func showFiles(_ sender: Any?) { selectTab(.files) }
    @objc func showEvents(_ sender: Any?) { selectTab(.events) }

    private func reloadEvents(keepSelection: Bool) {
        let selectedPaths = keepSelection ? Set(events.paths(forRows: eventsTable.selectedRowIndexes)) : []
        events.update(store.recentEvents, filter: query, caseSensitive: caseSensitive)
        eventsTable.reloadData()
        if !selectedPaths.isEmpty {
            let rows = IndexSet(events.events.indices.filter { selectedPaths.contains(events.events[$0].path) })
            eventsTable.selectRowIndexes(rows, byExtendingSelection: false)
        }
        statusBar.setEventCount(store.recentEvents.count)
    }

    private func reloadVisibleNames() {
        for table in [filesTable, eventsTable] where !table.isHiddenOrHasHiddenAncestor {
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { continue }
            let col = table.column(withIdentifier: ColumnID.name)
            guard col >= 0 else { continue }
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                             columnIndexes: IndexSet(integer: col))
        }
    }

    // MARK: Selection & actions

    private func selectedPaths(in table: FileTableView? = nil) -> [String] {
        let t = table ?? activeTable
        return t === filesTable ? results.paths(forRows: t.selectedRowIndexes) : events.paths(forRows: t.selectedRowIndexes)
    }

    private func selectedURLs(in table: FileTableView? = nil) -> [URL] {
        selectedPaths(in: table).map { URL(fileURLWithPath: $0) }
    }

    func fileURLs(forRows rows: IndexSet, in table: FileTableView) -> [URL] {
        let paths = table === filesTable ? results.paths(forRows: rows) : events.paths(forRows: rows)
        return paths.filter { FileManager.default.fileExists(atPath: $0) || table === filesTable }
            .map { URL(fileURLWithPath: $0) }
    }

    private func selectionChanged() {
        refreshQuickLook()
    }

    @objc private func tableDoubleClicked(_ sender: FileTableView) {
        guard sender.clickedRow >= 0 else { return }
        openSelection(sender)
    }

    @objc func openSelection(_ sender: Any?) {
        let urls = selectedURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        if urls.count > 20 {
            let alert = NSAlert()
            alert.messageText = "Open \(urls.count) items?"
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for u in urls { NSWorkspace.shared.open(u) }
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = selectedURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func copyFiles(_ sender: Any?) {
        let urls = selectedURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    @objc func copyPaths(_ sender: Any?) {
        let paths = selectedPaths()
        guard !paths.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func copyNames(_ sender: Any?) {
        let names = selectedPaths().map { ($0 as NSString).lastPathComponent }
        guard !names.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(names.joined(separator: "\n"), forType: .string)
    }

    @objc func focusSearch(_ sender: Any?) {
        if !(window?.isVisible ?? false) { show() }
        focusSearchField(selectAll: true)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openSelection(_:)), #selector(revealInFinder(_:)), #selector(copyFiles(_:)),
             #selector(copyPaths(_:)), #selector(copyNames(_:)), #selector(toggleQuickLook(_:)):
            return activeTable.numberOfSelectedRows > 0
        case #selector(toggleCaseSensitive(_:)):
            item.state = caseSensitive ? .on : .off
            return true
        case #selector(showFiles(_:)):
            item.state = tab == .files ? .on : .off
            return true
        case #selector(showEvents(_:)):
            item.state = tab == .events ? .on : .off
            return true
        default:
            return true
        }
    }

    func contextMenu(for table: FileTableView) -> NSMenu? {
        let n = table.numberOfSelectedRows
        guard n > 0 else { return nil }
        let plural = n > 1
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, symbol: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        add(plural ? "Open \(n) Items" : "Open", #selector(openSelection(_:)), "o", symbol: "arrow.up.forward.app")
        add("Reveal in Finder", #selector(revealInFinder(_:)), "r", symbol: "folder")
        add("Quick Look", #selector(toggleQuickLook(_:)), " ", [], symbol: "eye")
        menu.addItem(.separator())
        add(plural ? "Copy Files" : "Copy File", #selector(copyFiles(_:)), "c", symbol: "doc.on.doc")
        add(plural ? "Copy Paths" : "Copy Path", #selector(copyPaths(_:)), "c", [.command, .shift], symbol: "link")
        add(plural ? "Copy Names" : "Copy Name", #selector(copyNames(_:)), symbol: "textformat")
        return menu
    }

    func tableWantsSearchFocus(_ table: FileTableView) {
        table.deselectAll(nil)
        focusSearchField(selectAll: false)
    }

    func table(_ table: FileTableView, forwardTyping text: String) {
        focusSearchField(selectAll: false)
        searchField.currentEditor()?.insertText(text)
    }

    // MARK: Quick Look

    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
            window?.makeKey()
        } else {
            guard activeTable.numberOfSelectedRows > 0 else { NSSound.beep(); return }
            // The panel picks its controller from the key window's responder chain.
            window?.makeKey()
            if activeTable.window?.firstResponder !== activeTable { window?.makeFirstResponder(activeTable) }
            panel.makeKeyAndOrderFront(nil)
            if qlPanel == nil { panel.updateController() }
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        qlPanel = panel
        qlURLs = Array(selectedURLs().prefix(500))
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        qlPanel = nil
        qlURLs = []
        // The panel was key; hand keyboard focus back to the results.
        DispatchQueue.main.async { [weak self] in
            guard let w = self?.window, w.isVisible, NSApp.isActive, !(QLPreviewPanel.shared()?.isVisible ?? false) else { return }
            w.makeKey()
        }
    }

    private func refreshQuickLook() {
        guard let panel = qlPanel, panel.isVisible else { return }
        let urls = Array(selectedURLs().prefix(500))
        guard urls != qlURLs else { return }
        qlURLs = urls
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { qlURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        index < qlURLs.count ? qlURLs[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        switch Int(event.keyCode) {
        case 125, 126: // ↓ ↑ move the selection in the table; the panel follows
            activeTable.keyDown(with: event)
            return true
        case 49:
            panel.orderOut(nil)
            window?.makeKey()
            return true
        default:
            return false
        }
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = item?.previewItemURL, let window else { return .zero }
        let table = activeTable
        let rows = table.selectedRowIndexes
        var target: Int?
        for r in rows {
            let path = table === filesTable ? results.row(r)?.path : (r < events.events.count ? events.events[r].path : nil)
            if path == url.path { target = r; break }
        }
        guard let row = target else { return .zero }
        let visible = table.rows(in: table.visibleRect)
        guard row >= visible.location && row < visible.location + visible.length else { return .zero }
        let col = max(table.column(withIdentifier: ColumnID.name), 0)
        var rect = table.frameOfCell(atColumn: col, row: row)
        rect.size.width = 16
        rect.origin.x += 2
        rect = table.convert(rect, to: nil)
        return window.convertToScreen(rect)
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = item?.previewItemURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

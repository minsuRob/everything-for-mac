import AppKit
import EFMCore

/// Data source for the search results. Rows are materialised lazily from the index (only
/// visible rows are ever touched), so 3+ million results scroll like ten.
@MainActor
final class ResultsDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        var live: Bool
        var name: String
        var parent: String
        var size: Int64
        var isDirectory: Bool
        var mtime: Int64
        var ctime: Int64

        var path: String { parent == "/" ? "/" + name : parent + "/" + name }
    }

    var store: IndexStore
    private(set) var entries: [UInt32] = []
    private(set) var highlights: [String] = []
    private var cache: [Int: Row] = [:]
    var onSortChange: ((SearchSort) -> Void)?
    var onSelectionChange: (() -> Void)?
    private var suppressSortCallback = false

    init(store: IndexStore) {
        self.store = store
    }

    func update(entries: [UInt32], highlights: [String]) {
        self.entries = entries
        self.highlights = highlights.filter { !$0.isEmpty }
        cache.removeAll(keepingCapacity: true)
    }

    func invalidateCache() { cache.removeAll(keepingCapacity: true) }

    func entry(at row: Int) -> UInt32? {
        row >= 0 && row < entries.count ? entries[row] : nil
    }

    func row(_ r: Int) -> Row? {
        if let cached = cache[r] { return cached }
        guard let e = entry(at: r) else { return nil }
        let info: Row = store.read { idx in
            guard Int(e) < idx.capacity, idx.isLive(e) else {
                return Row(live: false, name: "", parent: "", size: 0, isDirectory: false, mtime: 0, ctime: 0)
            }
            return Row(live: true, name: idx.nameOf(e), parent: idx.parentPath(of: e), size: idx.sizeOf(e),
                       isDirectory: idx.isDirectory(e), mtime: idx.mtimeOf(e), ctime: idx.ctimeOf(e))
        }
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[r] = info
        return info
    }

    func paths(forRows rows: IndexSet) -> [String] {
        let es = rows.compactMap { entry(at: $0) }
        guard !es.isEmpty else { return [] }
        return store.read { idx in
            es.compactMap { e in Int(e) < idx.capacity && idx.isLive(e) ? idx.path(of: e) : nil }
        }
    }

    // MARK: Columns

    func installColumns(in table: NSTableView, sort: SearchSort) {
        func col(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat, key: SortKey, ascending: Bool,
                 alignment: NSTextAlignment = .left) {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = min
            c.resizingMask = .userResizingMask
            c.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: ascending)
            c.headerCell.alignment = alignment
            table.addTableColumn(c)
        }
        col(ColumnID.name, "Name", width: 280, min: 120, key: .name, ascending: true)
        col(ColumnID.path, "Path", width: 360, min: 100, key: .path, ascending: true)
        col(ColumnID.size, "Size", width: 80, min: 50, key: .size, ascending: false, alignment: .right)
        col(ColumnID.modified, "Date Modified", width: 150, min: 90, key: .dateModified, ascending: false)
        col(ColumnID.created, "Date Created", width: 150, min: 90, key: .dateCreated, ascending: false)
        setSortIndicator(table, sort)
    }

    func setSortIndicator(_ table: NSTableView, _ sort: SearchSort) {
        suppressSortCallback = true
        table.sortDescriptors = [NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)]
        suppressSortCallback = false
        let indicator = NSImage(named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
        for c in table.tableColumns {
            table.setIndicatorImage(c.sortDescriptorPrototype?.key == sort.key.rawValue ? indicator : nil, in: c)
        }
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !suppressSortCallback, let d = tableView.sortDescriptors.first, let key = d.key,
              let sk = SortKey(rawValue: key) else { return }
        onSortChange?(SearchSort(sk, ascending: d.ascending))
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let r = self.row(row), r.live else { return nil }
        return URL(fileURLWithPath: r.path) as NSURL
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let r = self.row(row) else { return nil }
        switch id {
        case ColumnID.name:
            let cell = tableView.reusableCell(id) { NameCellView(identifier: id) }
            if r.live {
                let icon = IconCache.shared.icon(name: r.name, path: r.path, isDirectory: r.isDirectory)
                cell.configure(name: r.name, terms: highlights, icon: icon)
            } else {
                cell.configure(name: "(removed)", terms: [], icon: nil, dimmed: true)
            }
            return cell
        case ColumnID.path:
            let cell = tableView.reusableCell(id) {
                TextCellView(identifier: id, alignment: .left, truncation: .byTruncatingMiddle, font: CellStyle.font)
            }
            cell.secondary = true
            cell.textField?.stringValue = r.parent
            cell.toolTip = nil
            return cell
        case ColumnID.size:
            let cell = tableView.reusableCell(id) {
                TextCellView(identifier: id, alignment: .right, truncation: .byClipping, font: CellStyle.digitsFont)
            }
            cell.secondary = true
            cell.textField?.stringValue = r.live && !r.isDirectory ? Formatting.size(r.size) : ""
            return cell
        case ColumnID.modified, ColumnID.created:
            let cell = tableView.reusableCell(id) {
                TextCellView(identifier: id, alignment: .left, truncation: .byTruncatingTail, font: CellStyle.digitsFont)
            }
            cell.secondary = true
            cell.textField?.stringValue = r.live ? Formatting.unixDate(id == ColumnID.modified ? r.mtime : r.ctime) : ""
            return cell
        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { nil }
}

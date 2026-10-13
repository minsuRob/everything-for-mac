import AppKit
import EFMCore

/// Cardinal's "FSEvents" panel: recent file-system changes, newest first, optionally
/// filtered by the search text.
@MainActor
final class EventsDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var events: [RecentEvent] = []
    private var isDirCache: [String: Bool] = [:]
    var onSelectionChange: (() -> Void)?

    func update(_ all: [RecentEvent], filter: String, caseSensitive: Bool) {
        var list = Array(all.reversed())
        let f = filter.trimmingCharacters(in: .whitespaces)
        if !f.isEmpty {
            // Plain words only: filters (ext:, size:…) and operators don't apply to event paths.
            let terms = f.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"*?")) }
                .filter { !$0.isEmpty && !$0.contains(":") && !$0.hasPrefix("!") && !$0.contains("|") && $0 != "AND" && $0 != "OR" && $0 != "NOT" }
            let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            if !terms.isEmpty {
                list = list.filter { e in terms.allSatisfy { e.path.range(of: $0, options: opts) != nil } }
            }
        }
        events = list
        if isDirCache.count > 5000 { isDirCache.removeAll() }
    }

    func paths(forRows rows: IndexSet) -> [String] {
        rows.compactMap { $0 < events.count ? events[$0].path : nil }
    }

    func installColumns(in table: NSTableView) {
        func col(_ id: NSUserInterfaceItemIdentifier, _ title: String, _ width: CGFloat) {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = 50
            c.resizingMask = .userResizingMask
            table.addTableColumn(c)
        }
        col(ColumnID.time, "Time", 90)
        col(ColumnID.kind, "Event", 80)
        col(ColumnID.name, "Name", 240)
        col(ColumnID.path, "Path", 460)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { events.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < events.count, FileManager.default.fileExists(atPath: events[row].path) else { return nil }
        return URL(fileURLWithPath: events[row].path) as NSURL
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < events.count else { return nil }
        let e = events[row]
        switch id {
        case ColumnID.name:
            let cell = tableView.reusableCell(id) { NameCellView(identifier: id) }
            let name = (e.path as NSString).lastPathComponent
            let isDir: Bool
            if let cached = isDirCache[e.path] { isDir = cached } else {
                var d: ObjCBool = false
                isDir = FileManager.default.fileExists(atPath: e.path, isDirectory: &d) && d.boolValue
                isDirCache[e.path] = isDir
            }
            cell.configure(name: name, terms: [], icon: IconCache.shared.icon(name: name, path: e.path, isDirectory: isDir),
                           dimmed: e.kind == "removed")
            return cell
        default:
            let cell = tableView.reusableCell(id) {
                TextCellView(identifier: id, alignment: .left,
                             truncation: id == ColumnID.path ? .byTruncatingMiddle : .byTruncatingTail,
                             font: id == ColumnID.time ? CellStyle.digitsFont : CellStyle.font)
            }
            switch id {
            case ColumnID.time:
                cell.secondary = true
                cell.textField?.stringValue = Formatting.time.string(from: e.date)
            case ColumnID.kind:
                cell.secondary = false
                cell.textField?.stringValue = e.kind
            default:
                cell.secondary = true
                cell.textField?.stringValue = (e.path as NSString).deletingLastPathComponent
            }
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { nil }
}

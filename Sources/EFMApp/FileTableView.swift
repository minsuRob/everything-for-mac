import AppKit

/// What a `FileTableView` needs from its owner.
@MainActor
protocol FileTableViewOwner: AnyObject {
    func fileURLs(forRows rows: IndexSet, in table: FileTableView) -> [URL]
    func contextMenu(for table: FileTableView) -> NSMenu?
    /// ↑ on the first row: hand focus back to the search field.
    func tableWantsSearchFocus(_ table: FileTableView)
    /// Printable keys typed into the table are forwarded to the search field.
    func table(_ table: FileTableView, forwardTyping text: String)
    func openSelection(_ sender: Any?)
    func toggleQuickLook(_ sender: Any?)
}

/// Results table: keyboard behaviour matching Cardinal (Enter opens, Space Quick Looks,
/// ↑ at the top returns to the search field), ⌘C copies files, right-click selects the
/// clicked row before showing the context menu, and rows drag out as file URLs.
final class FileTableView: NSTableView {
    weak var owner: FileTableViewOwner?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = mods.subtracting([.numericPad, .function, .capsLock]).isEmpty
        switch Int(event.keyCode) {
        case 36, 76: // Return, Enter
            if plain || mods == [.numericPad] { owner?.openSelection(self); return }
        case 49: // Space
            if plain {
                if !event.isARepeat { owner?.toggleQuickLook(self) }
                return
            }
        case 126: // ↑
            if plain, selectedRow <= 0 {
                owner?.tableWantsSearchFocus(self)
                return
            }
        case 53: // Esc
            NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: self)
            return
        default:
            break
        }
        if !mods.contains(.command), !mods.contains(.control),
           let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            owner?.table(self, forwardTyping: chars)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return owner?.contextMenu(for: self)
    }

    // MARK: Copy (⌘C copies the files themselves; text fields keep their own copy:)

    @objc func copy(_ sender: Any?) {
        let urls = owner?.fileURLs(forRows: selectedRowIndexes, in: self) ?? []
        guard !urls.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return numberOfSelectedRows > 0 }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Drag out

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link] : []
    }
}

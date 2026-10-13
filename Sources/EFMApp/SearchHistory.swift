import Foundation

/// Search history with Cardinal's semantics (useSearchHistory.ts): the last slot is the
/// live "tail" that tracks the field while typing; a new entry is pushed when the field is
/// cleared, when the first letter changes, or when editing a recalled entry.
final class SearchHistory {
    private var entries: [String]
    private var cursor: Int
    private let maxEntries: Int
    private let defaultsKey = "searchHistory"

    init(maxEntries: Int = 50) {
        self.maxEntries = maxEntries
        var stored = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        stored = stored.filter { !$0.isEmpty }
        entries = stored + [""]
        cursor = entries.count - 1
        clamp()
    }

    private var tail: Int { entries.count - 1 }

    private func clamp() {
        if entries.count > maxEntries {
            let overflow = entries.count - maxEntries
            entries.removeFirst(overflow)
            cursor = max(cursor - overflow, 0)
        }
    }

    private func push(_ value: String) {
        if entries.isEmpty { entries.append("") }
        entries.append(value)
        clamp()
        cursor = tail
    }

    func inputChanged(_ value: String) {
        if entries.isEmpty { entries.append("") }
        let tailValue = entries[tail]
        if cursor != tail { push(value); return }
        if !tailValue.isEmpty && value.isEmpty { push(value); return }
        if !tailValue.isEmpty, !value.isEmpty, tailValue.first != value.first { push(value); return }
        entries[tail] = value
        cursor = tail
    }

    /// Returns the recalled query, or nil at either end.
    func older() -> String? {
        guard cursor > 0 else { return nil }
        cursor -= 1
        return entries[cursor]
    }

    func newer() -> String? {
        guard cursor < tail else { return nil }
        cursor += 1
        return entries[cursor]
    }

    func persist() {
        var seen = Set<String>()
        var unique: [String] = []
        for e in entries.reversed() where !e.isEmpty && seen.insert(e).inserted { unique.append(e) }
        UserDefaults.standard.set(Array(unique.prefix(maxEntries).reversed()), forKey: defaultsKey)
    }
}

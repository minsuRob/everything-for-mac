import EFMCore
import Foundation

extension Notification.Name {
    static let efmSettingsChanged = Notification.Name("EFMSettingsChanged")
}

/// UserDefaults-backed preferences (domain `com.efm.app` when run from the bundle).
///
/// Keys (usable with `defaults write com.efm.app <key> …`):
/// `watchRoot` (string), `ignorePaths` (array; absent = engine defaults for the root),
/// `crossDevices`, `caseSensitiveDefault`, `hideDockIcon`, `showStatusItem`,
/// `globalHotKeyEnabled` (bools), `sortKey` (string), `sortAscending` (bool).
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    enum Key {
        static let watchRoot = "watchRoot"
        static let ignorePaths = "ignorePaths"
        static let crossDevices = "crossDevices"
        static let caseSensitiveDefault = "caseSensitiveDefault"
        static let hideDockIcon = "hideDockIcon"
        static let showStatusItem = "showStatusItem"
        static let globalHotKeyEnabled = "globalHotKeyEnabled"
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
    }

    private init() {
        d.register(defaults: [
            Key.watchRoot: "/",
            Key.crossDevices: false,
            Key.caseSensitiveDefault: false,
            Key.hideDockIcon: false,
            Key.showStatusItem: true,
            Key.globalHotKeyEnabled: true,
            Key.sortKey: SortKey.name.rawValue,
            Key.sortAscending: true,
        ])
    }

    private func changed() {
        NotificationCenter.default.post(name: .efmSettingsChanged, object: self)
    }

    var watchRoot: String {
        get {
            let raw = (d.string(forKey: Key.watchRoot) ?? "/").trimmingCharacters(in: .whitespaces)
            return Settings.normalize(raw) ?? "/"
        }
        set { d.set(newValue, forKey: Key.watchRoot); changed() }
    }

    /// Explicit ignore list, or nil when the user never edited it.
    var customIgnorePaths: [String]? {
        get { d.stringArray(forKey: Key.ignorePaths) }
        set {
            if let newValue { d.set(newValue, forKey: Key.ignorePaths) } else { d.removeObject(forKey: Key.ignorePaths) }
            changed()
        }
    }

    var crossDevices: Bool {
        get { d.bool(forKey: Key.crossDevices) }
        set { d.set(newValue, forKey: Key.crossDevices); changed() }
    }

    var caseSensitiveDefault: Bool {
        get { d.bool(forKey: Key.caseSensitiveDefault) }
        set { d.set(newValue, forKey: Key.caseSensitiveDefault); changed() }
    }

    var hideDockIcon: Bool {
        get { d.bool(forKey: Key.hideDockIcon) }
        set { d.set(newValue, forKey: Key.hideDockIcon); changed() }
    }

    /// Always true while the Dock icon is hidden, so the app stays reachable.
    var showStatusItem: Bool {
        get { d.bool(forKey: Key.showStatusItem) || hideDockIcon }
        set { d.set(newValue, forKey: Key.showStatusItem); changed() }
    }

    var globalHotKeyEnabled: Bool {
        get { d.bool(forKey: Key.globalHotKeyEnabled) }
        set { d.set(newValue, forKey: Key.globalHotKeyEnabled); changed() }
    }

    var sortOrder: SearchSort {
        get {
            let key = SortKey(rawValue: d.string(forKey: Key.sortKey) ?? "") ?? .name
            return SearchSort(key, ascending: d.bool(forKey: Key.sortAscending))
        }
        set {
            d.set(newValue.key.rawValue, forKey: Key.sortKey)
            d.set(newValue.ascending, forKey: Key.sortAscending)
        }
    }

    func defaultIgnorePaths(for root: String) -> [String] {
        ScanOptions.defaults(for: root).ignorePaths.sorted()
    }

    func ignorePaths(for root: String) -> [String] {
        customIgnorePaths ?? defaultIgnorePaths(for: root)
    }

    func scanOptions(for root: String) -> ScanOptions {
        ScanOptions(ignorePaths: Set(ignorePaths(for: root).compactMap(Settings.normalize)), crossDevices: crossDevices)
    }

    /// Absolute, tilde-expanded, without a trailing slash (except "/"). Nil if not absolute.
    static func normalize(_ raw: String) -> String? {
        var s = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard s.hasPrefix("/") else { return nil }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Symlink-free form of `path` (what `IndexStore.rootPath` holds: /var → /private/var).
    static func canonical(_ path: String) -> String {
        path.withCString { p in
            guard let r = realpath(p, nil) else { return path }
            defer { free(r) }
            return String(cString: r)
        }
    }

    /// `~/Library/Application Support/EFM/index-<sanitized root>.idx`
    static func cacheURL(for root: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("EFM", isDirectory: true)
        var name = root == "/" ? "root" : String(root.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        while name.hasPrefix("_") { name.removeFirst() }
        if name.isEmpty { name = "root" }
        return dir.appendingPathComponent("index-\(name).idx")
    }
}

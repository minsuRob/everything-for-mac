import CEFM
import CoreServices
import Foundation

final class RWLock: @unchecked Sendable {
    private var lock = pthread_rwlock_t()
    init() { pthread_rwlock_init(&lock, nil) }
    deinit { pthread_rwlock_destroy(&lock) }
    func read<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return try body()
    }
    func write<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return try body()
    }
}

public enum IndexState: Sendable, Equatable {
    case idle
    case loading
    case scanning(entries: Int)
    case ready
    case failed(String)
}

public struct RecentEvent: Sendable {
    public var path: String
    public var kind: String
    public var date: Date
}

/// Owns the index for one watch root: loads the cache or scans, keeps it current from
/// FSEvents, saves it, and serves searches. Searches take a shared lock; scans and event
/// batches take the exclusive lock.
public final class IndexStore: @unchecked Sendable {
    public let rootPath: String
    public let cacheURL: URL
    public private(set) var scanOptions: ScanOptions

    private let lock = RWLock()
    private var index: FileIndex
    private var lastEventId: FSEventStreamEventId = 0
    private var watcher: Watcher?
    private let work = DispatchQueue(label: "efm.index", qos: .userInitiated)
    private var dirty = false
    private var stopped = false
    private let stateLock = NSLock()
    private var _state: IndexState = .idle
    private var _recent: [RecentEvent] = []

    /// Called (on a background queue) after the index changes; coalesced by the caller.
    public var onChange: (@Sendable () -> Void)?
    public var onStateChange: (@Sendable (IndexState) -> Void)?

    public init(rootPath: String = "/", cacheURL: URL, scanOptions: ScanOptions? = nil) {
        // FSEvents reports canonical paths (/private/var/..., not /var/...), so watch and index
        // the resolved path or events would not match index entries.
        self.rootPath = rootPath.withCString { p in
            guard let r = realpath(p, nil) else { return rootPath }
            defer { free(r) }
            return String(cString: r)
        }
        self.cacheURL = cacheURL
        self.scanOptions = scanOptions ?? .defaults(for: rootPath)
        index = FileIndex(rootPath: self.rootPath)
    }

    public var state: IndexState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    private func setState(_ s: IndexState) {
        stateLock.lock(); _state = s; stateLock.unlock()
        onStateChange?(s)
    }

    public var recentEvents: [RecentEvent] {
        stateLock.lock(); defer { stateLock.unlock() }
        return _recent
    }

    public var entryCount: Int { lock.read { index.liveCount } }

    // MARK: Lifecycle

    /// Loads the cache (replaying FSEvents since it was written) or scans from scratch.
    public func start() {
        stateLock.lock(); stopped = false; stateLock.unlock()
        work.async { [self] in
            setState(.loading)
            if loadCache() {
                lock.read { index.warmSortCache(.name) }
                setState(.ready)
                onChange?()
                startWatching(since: lastEventId)
            } else {
                fullScan()
            }
        }
    }

    public func rescan() {
        work.async { [self] in fullScan() }
    }

    public func updateScanOptions(_ options: ScanOptions) {
        work.async { [self] in
            scanOptions = options
            fullScan()
        }
    }

    private func fullScan() {
        stateLock.lock()
        let old = watcher
        watcher = nil
        stateLock.unlock()
        old?.stop()
        let since = Watcher.currentEventId
        setState(.scanning(entries: 0))
        let fresh = FileIndex(rootPath: rootPath)
        let t0 = Date()
        let scanner = Scanner(index: fresh, options: scanOptions, cancelled: { [weak self] in self?.isStopped ?? true },
                              progress: { [weak self] n in self?.setState(.scanning(entries: n)) })
        guard scanner.scan(path: rootPath, entry: 0) else {
            setState(.idle) // stopped mid-scan (e.g. the watch root changed); keep the old index
            return
        }
        fresh.names.commitOrder()
        fresh.resetChangeLog()
        lock.write {
            index = fresh
            lastEventId = since
            dirty = true
        }
        lock.read { index.warmSortCache(.name) }
        NSLog("EFM: scanned %d entries (%d unique names) in %.1fs", fresh.liveCount, fresh.names.count, Date().timeIntervalSince(t0))
        setState(.ready)
        onChange?()
        try? save()
        startWatching(since: since)
    }

    private func startWatching(since: FSEventStreamEventId) {
        let w = Watcher { [weak self] events in self?.handle(events) }
        stateLock.lock()
        if stopped {
            stateLock.unlock()
            return
        }
        let old = watcher
        watcher = w
        stateLock.unlock()
        old?.stop()
        w.start(path: rootPath, sinceWhen: since == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : since)
    }

    /// Stops watching and cancels an in-progress full scan (its partial result is discarded).
    /// Does not wait; use `waitUntilIdle()` for that.
    public func stop() {
        stateLock.lock()
        stopped = true
        let w = watcher
        watcher = nil
        stateLock.unlock()
        w?.stop()
    }

    private var isStopped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopped
    }

    /// Blocks until queued scans and event batches have been applied.
    public func waitUntilIdle() {
        work.sync {}
    }

    // MARK: Search

    public func search(_ query: String, options: SearchOptions, token: CancelToken) throws -> SearchResult {
        try lock.read { try index.search(query, options: options, token: token) }
    }

    /// Shared access for rendering rows. Keep `body` short.
    public func read<T>(_ body: (FileIndex) throws -> T) rethrows -> T {
        try lock.read { try body(index) }
    }

    // MARK: Events

    private func handle(_ events: [FSEvent]) {
        work.async { [self] in apply(events) }
    }

    func apply(_ events: [FSEvent]) {
        guard !events.isEmpty else { return }
        if events.contains(where: { $0.rootChanged || ($0.path == rootPath && $0.needsSubtreeScan) }) {
            fullScan()
            return
        }
        let ignore = scanOptions.ignorePaths
        func ignored(_ p: String) -> Bool {
            ignore.contains { p == $0 || p.hasPrefix($0 + "/") }
        }
        var subtree: [String] = []
        var single: [String] = []
        var seen = Set<String>()
        var recent: [RecentEvent] = []
        let now = Date()
        for e in events where !e.isHistoryDone && !ignored(e.path) {
            if e.needsSubtreeScan { subtree.append(e.path) }
            else if seen.insert(e.path).inserted { single.append(e.path) }
            recent.append(RecentEvent(path: e.path, kind: describe(e), date: now))
        }
        let maxId = events.map(\.id).max() ?? lastEventId

        lock.write {
            var newDirs: [String] = []
            for p in single {
                applySingle(p, newDirs: &newDirs)
            }
            for p in minimalCover(subtree + newDirs) {
                rescanSubtree(p)
            }
            index.names.commitOrder()
            lastEventId = max(lastEventId, maxId)
            dirty = true
        }
        stateLock.lock()
        _recent.append(contentsOf: recent)
        if _recent.count > 2000 { _recent.removeFirst(_recent.count - 2000) }
        stateLock.unlock()
        onChange?()
    }

    private func describe(_ e: FSEvent) -> String {
        if e.has(kFSEventStreamEventFlagItemRemoved) { return "removed" }
        if e.has(kFSEventStreamEventFlagItemRenamed) { return "renamed" }
        if e.has(kFSEventStreamEventFlagItemCreated) { return "created" }
        if e.needsSubtreeScan { return "rescan" }
        return "modified"
    }

    /// One path from a file-level event: stat it and make the index agree.
    /// New directories are returned in `newDirs` so their contents get scanned.
    private func applySingle(_ path: String, newDirs: inout [String]) {
        var info = efm_dirent()
        let exists = path.withCString { efm_stat_path($0, &info) } == 0
        let node = index.lookup(path: path)
        guard exists else {
            if let node { index.remove(node) }
            return
        }
        let isDir = Int(info.type) == EFM_TYPE_DIR
        if let node {
            if index.isDirectory(node) != isDir || (Int(info.type) == EFM_TYPE_SYMLINK) != index.flagsOf(node).contains(.symlink) {
                let parent = index.parentOf(node)
                index.remove(node)
                let name = (path as NSString).lastPathComponent
                index.addEntry(name: name, parent: parent, info: info)
                if isDir { newDirs.append(path) }
            } else {
                index.update(node, info: info)
            }
            return
        }
        guard let parent = ensureParent(of: path) else { return }
        let name = (path as NSString).lastPathComponent
        index.addEntry(name: name, parent: parent, info: info)
        if isDir { newDirs.append(path) }
    }

    /// Finds (creating if needed) the parent folder entry of `path`.
    private func ensureParent(of path: String) -> UInt32? {
        let parentPath = (path as NSString).deletingLastPathComponent
        if let p = index.lookup(path: parentPath) { return p }
        guard parentPath != path, index.relativeComponents(parentPath) != nil else { return nil }
        var info = efm_dirent()
        guard parentPath.withCString({ efm_stat_path($0, &info) }) == 0, Int(info.type) == EFM_TYPE_DIR,
              let grand = ensureParent(of: parentPath) else { return nil }
        return index.addEntry(name: (parentPath as NSString).lastPathComponent, parent: grand, info: info)
    }

    private func rescanSubtree(_ path: String) {
        var info = efm_dirent()
        guard path.withCString({ efm_stat_path($0, &info) }) == 0 else {
            if let n = index.lookup(path: path) { index.remove(n) }
            return
        }
        let node: UInt32
        if let n = index.lookup(path: path) {
            node = n
            index.update(n, info: info)
        } else {
            guard let parent = ensureParent(of: path) else { return }
            node = index.addEntry(name: (path as NSString).lastPathComponent, parent: parent, info: info)
        }
        guard index.isDirectory(node) else { return }
        index.removeChildren(node)
        Scanner(index: index, options: scanOptions).scan(path: path, entry: node)
    }

    // MARK: Persistence

    private static let magic: UInt64 = 0x3130_5844_4946_4D45 // "EMFIDX01" little-endian
    private static let version: UInt64 = 1

    public func save() throws {
        try lock.read {
            guard dirty else { return }
            let tmp = cacheURL.appendingPathExtension("tmp")
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            do {
                var root = Array(rootPath.utf8)
                let uuid = Array(Self.fseventsUUID(for: rootPath).utf8)
                var header: [UInt64] = [Self.magic, Self.version, UInt64(root.count), UInt64(uuid.count), lastEventId]
                try writeAll(fd, &header, header.count * 8)
                try writeAll(fd, &root, root.count)
                try uuid.withUnsafeBytes { try writeAll(fd, $0.baseAddress!, $0.count) }
                try index.names.write(to: fd)
                try index.write(to: fd)
                close(fd)
            } catch {
                close(fd)
                unlink(tmp.path)
                throw error
            }
            guard rename(tmp.path, cacheURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        lock.write { dirty = false }
    }

    /// Returns false (and leaves the empty index) if the cache is missing, from another root,
    /// another format version, or the FSEvents history it refers to is gone.
    private func loadCache() -> Bool {
        let fd = open(cacheURL.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        do {
            var header = [UInt64](repeating: 0, count: 5)
            try readAll(fd, &header, 40)
            guard header[0] == Self.magic, header[1] == Self.version, header[2] < 4096, header[3] < 256 else { return false }
            var root = [UInt8](repeating: 0, count: Int(header[2]))
            try readAll(fd, &root, root.count)
            var uuid = [UInt8](repeating: 0, count: Int(header[3]))
            try readAll(fd, &uuid, uuid.count)
            guard String(decoding: root, as: UTF8.self) == rootPath,
                  String(decoding: uuid, as: UTF8.self) == Self.fseventsUUID(for: rootPath) else { return false }
            let t0 = Date()
            let names = try NamePool.read(from: fd)
            let loaded = try FileIndex.read(from: fd, rootPath: rootPath, names: names)
            lock.write {
                index = loaded
                lastEventId = header[4]
                dirty = false
            }
            NSLog("EFM: loaded %d entries from cache in %.2fs", loaded.liveCount, Date().timeIntervalSince(t0))
            return true
        } catch {
            NSLog("EFM: cache unreadable (%@), rescanning", "\(error)")
            return false
        }
    }

    /// FSEvents database identity for the root's volume. If it changes, stored event ids are
    /// meaningless and the cache must be rebuilt (Everything does the same with USN journal ids).
    static func fseventsUUID(for path: String) -> String {
        var info = efm_dirent()
        guard efm_stat_path(path, &info) == 0,
              let uuid = FSEventsCopyUUIDForDevice(dev_t(bitPattern: info.dev)) else { return "" }
        return (CFUUIDCreateString(nil, uuid) as String?) ?? ""
    }
}

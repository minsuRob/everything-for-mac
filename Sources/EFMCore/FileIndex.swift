import CEFM
import Foundation

public struct EntryFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let directory = EntryFlags(rawValue: 1)
    public static let symlink = EntryFlags(rawValue: 2)
    public static let deleted = EntryFlags(rawValue: 4)
    /// A directory on another device that the scanner did not descend into.
    public static let mountPoint = EntryFlags(rawValue: 8)
}

public let noEntry = UInt32.max

/// In-memory file tree in struct-of-arrays form. Entry 0 is the watch root.
/// Only names and parent links are stored; paths are rebuilt on demand.
///
/// Not thread-safe by itself: `IndexStore` serialises writers against readers.
public final class FileIndex: @unchecked Sendable {
    public let rootPath: String
    public let names: NamePool

    let nameId = PODBuffer<UInt32>(capacity: 1 << 16)
    let parent = PODBuffer<UInt32>(capacity: 1 << 16)
    let firstChild = PODBuffer<UInt32>(capacity: 1 << 16)
    let nextSibling = PODBuffer<UInt32>(capacity: 1 << 16)
    let flags = PODBuffer<UInt8>(capacity: 1 << 16)
    let size = PODBuffer<Int64>(capacity: 1 << 16)
    let mtime = PODBuffer<Int64>(capacity: 1 << 16)
    let ctime = PODBuffer<Int64>(capacity: 1 << 16)
    private var freeList: [UInt32] = []
    /// Entries added or modified since load, so cached sort permutations can be patched
    /// instead of rebuilt (see `SortCache`).
    let changeLog = PODBuffer<UInt32>()
    var sortCaches: [SortKey: SortCache] = [:]
    let sortCacheLock = NSLock()

    public private(set) var liveCount = 0
    /// Bumped on every mutation; caches keyed on it (sorted views) know when to rebuild.
    public private(set) var generation: UInt64 = 0

    public init(rootPath: String, names: NamePool = NamePool()) {
        self.rootPath = rootPath
        self.names = names
        _ = addEntry(name: "", parent: noEntry, info: efm_dirent(name_off: 0, name_len: 0, type: UInt8(EFM_TYPE_DIR), reserved: 0, dev: 0, size: 0, mtime: 0, ctime: 0))
    }

    /// Slots, including deleted ones (bit sets are sized by this).
    public var capacity: Int { nameId.count }

    @inline(__always) public func isLive(_ e: UInt32) -> Bool {
        flags[Int(e)] & EntryFlags.deleted.rawValue == 0
    }

    @inline(__always) public func isDirectory(_ e: UInt32) -> Bool {
        flags[Int(e)] & EntryFlags.directory.rawValue != 0
    }

    public func flagsOf(_ e: UInt32) -> EntryFlags { EntryFlags(rawValue: flags[Int(e)]) }
    public func parentOf(_ e: UInt32) -> UInt32 { parent[Int(e)] }
    public func sizeOf(_ e: UInt32) -> Int64 { size[Int(e)] }
    public func mtimeOf(_ e: UInt32) -> Int64 { mtime[Int(e)] }
    public func ctimeOf(_ e: UInt32) -> Int64 { ctime[Int(e)] }
    public func nameOf(_ e: UInt32) -> String { names.string(nameId[Int(e)]) }

    // MARK: Mutation

    @discardableResult
    func addEntry(name: String, parent p: UInt32, info: efm_dirent) -> UInt32 {
        var name = name
        let id = name.withUTF8 { names.intern($0.baseAddress!, $0.count) }
        return addEntry(nameId: id, parent: p, info: info)
    }

    func addEntry(nameId id: UInt32, parent p: UInt32, info: efm_dirent) -> UInt32 {
        var f: UInt8 = 0
        switch Int(info.type) {
        case EFM_TYPE_DIR: f = EntryFlags.directory.rawValue
        case EFM_TYPE_SYMLINK: f = EntryFlags.symlink.rawValue
        default: break
        }
        let e: UInt32
        if let reused = freeList.popLast() {
            e = reused
            let i = Int(e)
            nameId[i] = id; parent[i] = p; firstChild[i] = noEntry; nextSibling[i] = noEntry
            flags[i] = f; size[i] = info.size; mtime[i] = info.mtime; ctime[i] = info.ctime
        } else {
            e = UInt32(nameId.count)
            nameId.append(id); parent.append(p); firstChild.append(noEntry); nextSibling.append(noEntry)
            flags.append(f); size.append(info.size); mtime.append(info.mtime); ctime.append(info.ctime)
        }
        if p != noEntry {
            nextSibling[Int(e)] = firstChild[Int(p)]
            firstChild[Int(p)] = e
        }
        liveCount += 1
        generation &+= 1
        changeLog.append(e)
        return e
    }

    func update(_ e: UInt32, info: efm_dirent) {
        let i = Int(e)
        size[i] = info.size
        mtime[i] = info.mtime
        ctime[i] = info.ctime
        generation &+= 1
        changeLog.append(e)
    }

    func setFlag(_ e: UInt32, _ flag: EntryFlags, _ on: Bool) {
        if on { flags[Int(e)] |= flag.rawValue } else { flags[Int(e)] &= ~flag.rawValue }
    }

    /// Unlinks `e` from its parent and frees it with all descendants.
    func remove(_ e: UInt32) {
        guard e != 0, isLive(e) else { return }
        let p = parent[Int(e)]
        if p != noEntry {
            var c = firstChild[Int(p)]
            if c == e {
                firstChild[Int(p)] = nextSibling[Int(e)]
            } else {
                while c != noEntry {
                    let n = nextSibling[Int(c)]
                    if n == e { nextSibling[Int(c)] = nextSibling[Int(e)]; break }
                    c = n
                }
            }
        }
        var stack: [UInt32] = [e]
        while let x = stack.popLast() {
            var c = firstChild[Int(x)]
            while c != noEntry { stack.append(c); c = nextSibling[Int(c)] }
            flags[Int(x)] = EntryFlags.deleted.rawValue
            firstChild[Int(x)] = noEntry
            nextSibling[Int(x)] = noEntry
            parent[Int(x)] = noEntry
            freeList.append(x)
            liveCount -= 1
        }
        generation &+= 1
    }

    /// Removes all children of `e` (keeps `e`).
    func removeChildren(_ e: UInt32) {
        var c = firstChild[Int(e)]
        while c != noEntry {
            let n = nextSibling[Int(c)]
            remove(c)
            c = n
        }
    }

    // MARK: Navigation

    public func child(of p: UInt32, nameId id: UInt32) -> UInt32? {
        var c = firstChild[Int(p)]
        while c != noEntry {
            if nameId[Int(c)] == id { return c }
            c = nextSibling[Int(c)]
        }
        return nil
    }

    public func children(of p: UInt32) -> [UInt32] {
        var out: [UInt32] = []
        var c = firstChild[Int(p)]
        while c != noEntry { out.append(c); c = nextSibling[Int(c)] }
        return out
    }

    /// Path components below the root, or nil if `path` is outside the root.
    func relativeComponents(_ path: String) -> [Substring]? {
        if rootPath == "/" {
            guard path.hasPrefix("/") else { return nil }
            return path.split(separator: "/")
        }
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        return path.dropFirst(rootPath.count).split(separator: "/")
    }

    public func lookup(path: String) -> UInt32? {
        guard let comps = relativeComponents(path) else { return nil }
        var e: UInt32 = 0
        for comp in comps {
            var s = String(comp)
            guard let id = s.withUTF8({ names.lookup($0.baseAddress!, $0.count) }),
                  let c = child(of: e, nameId: id) else { return nil }
            e = c
        }
        return e
    }

    /// Case-insensitive lookup used for `parent:` / `in:` arguments.
    public func lookupCaseInsensitive(path: String) -> UInt32? {
        if let e = lookup(path: path) { return e }
        guard let comps = relativeComponents(path) else { return nil }
        var e: UInt32 = 0
        for comp in comps {
            let want = normalizeForMatch(String(comp), caseSensitive: false)
            var found: UInt32?
            var c = firstChild[Int(e)]
            while c != noEntry {
                let f = names.foldedBytes(nameId[Int(c)])
                if String(decoding: f, as: UTF8.self) == want { found = c; break }
                c = nextSibling[Int(c)]
            }
            guard let next = found else { return nil }
            e = next
        }
        return e
    }

    public func path(of e: UInt32) -> String {
        if e == 0 { return rootPath }
        var chain: [UInt32] = []
        var x = e
        while x != 0 && x != noEntry {
            chain.append(nameId[Int(x)])
            x = parent[Int(x)]
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(128)
        if rootPath != "/" { bytes.append(contentsOf: rootPath.utf8) }
        for id in chain.reversed() {
            bytes.append(UInt8(ascii: "/"))
            bytes.append(contentsOf: names.rawBytes(id))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Path of the containing folder (what the Path column shows).
    public func parentPath(of e: UInt32) -> String {
        let p = parent[Int(e)]
        return p == noEntry ? "" : path(of: p)
    }

    public func depth(of e: UInt32) -> Int {
        var d = 0
        var x = parent[Int(e)]
        while x != noEntry { d += 1; x = parent[Int(x)] }
        return d
    }

    // MARK: Persistence

    func write(to fd: Int32) throws {
        var header: [UInt64] = [UInt64(nameId.count), UInt64(liveCount), UInt64(freeList.count)]
        try writeAll(fd, &header, 24)
        try nameId.write(to: fd); try parent.write(to: fd)
        try firstChild.write(to: fd); try nextSibling.write(to: fd)
        try flags.write(to: fd); try size.write(to: fd)
        try mtime.write(to: fd); try ctime.write(to: fd)
        try freeList.withUnsafeBytes { try writeAll(fd, $0.baseAddress!, $0.count) }
    }

    static func read(from fd: Int32, rootPath: String, names: NamePool) throws -> FileIndex {
        var header = [UInt64](repeating: 0, count: 3)
        try readAll(fd, &header, 24)
        let idx = FileIndex(rootPath: rootPath, names: names)
        let n = Int(header[0])
        try idx.nameId.read(from: fd, count: n); try idx.parent.read(from: fd, count: n)
        try idx.firstChild.read(from: fd, count: n); try idx.nextSibling.read(from: fd, count: n)
        try idx.flags.read(from: fd, count: n); try idx.size.read(from: fd, count: n)
        try idx.mtime.read(from: fd, count: n); try idx.ctime.read(from: fd, count: n)
        idx.freeList = [UInt32](repeating: 0, count: Int(header[2]))
        try idx.freeList.withUnsafeMutableBytes { try readAll(fd, $0.baseAddress!, $0.count) }
        idx.liveCount = Int(header[1])
        idx.resetChangeLog()
        // Validate links so a corrupt cache cannot send path building into a loop.
        for i in 0..<n where idx.flags[i] & EntryFlags.deleted.rawValue == 0 {
            let p = idx.parent[i]
            if i == 0 { guard p == noEntry else { throw POSIXError(.EINVAL) }; continue }
            guard p != noEntry, Int(p) < n, idx.nameId[i] < UInt32(names.count) else { throw POSIXError(.EINVAL) }
            var x = p, steps = 0
            while x != 0 {
                x = idx.parent[Int(x)]
                steps += 1
                guard x != noEntry, Int(x) < n, steps < 4096 else { throw POSIXError(.EINVAL) }
            }
        }
        return idx
    }
}

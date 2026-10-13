import CEFM
import Foundation

/// Interned file names. Each distinct name is stored once (most names repeat: `index.js`,
/// `.DS_Store`, `Contents`…), so name matching runs over unique names only.
///
/// Three parallel blobs, each `\0`-separated and contiguous for SIMD scanning:
/// - `raw`: bytes exactly as the file system returned them (used to build paths)
/// - `cased`: NFC-normalised (case-sensitive matching)
/// - `folded`: NFC + lowercased (default case-insensitive matching)
///
/// Normalising once here means a Korean query typed in NFC matches names stored in NFD
/// in a single pass. Cardinal instead searches twice (NFC and NFD query) and still misses
/// names that mix both forms.
public final class NamePool: @unchecked Sendable {
    let raw = PODBuffer<UInt8>(capacity: 1 << 20)
    let rawOffsets = PODBuffer<UInt32>(capacity: 1 << 16)
    let cased = PODBuffer<UInt8>(capacity: 1 << 20)
    let casedOffsets = PODBuffer<UInt32>(capacity: 1 << 16)
    let folded = PODBuffer<UInt8>(capacity: 1 << 20)
    let foldedOffsets = PODBuffer<UInt32>(capacity: 1 << 16)

    /// Open-addressing table of `id + 1` (0 = empty), keyed by a hash of the raw bytes.
    private var table = PODBuffer<UInt32>(repeating: 0, count: 1 << 16)
    private var tableMask = (1 << 16) - 1

    /// Name ids ordered by folded bytes, and each id's position in that order.
    /// Kept current by `commitOrder()` so result sorting by name is a radix sort on ranks.
    let sortedIds = PODBuffer<UInt32>()
    let rank = PODBuffer<UInt32>()
    private var unsortedFrom = 0

    public init() {
        rawOffsets.append(0)
        casedOffsets.append(0)
        foldedOffsets.append(0)
    }

    public var count: Int { rawOffsets.count - 1 }

    // MARK: Interning

    @inline(__always) private static func hash(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ UInt64(n)
        var i = 0
        while i + 8 <= n {
            let w = UnsafeRawPointer(p + i).loadUnaligned(as: UInt64.self)
            h = (h ^ w) &* 0x9E37_79B9_7F4A_7C15
            h ^= h >> 29
            i += 8
        }
        var tail: UInt64 = 0
        var shift: UInt64 = 0
        while i < n {
            tail |= UInt64(p[i]) << shift
            shift += 8
            i += 1
        }
        h = (h ^ tail) &* 0x9E37_79B9_7F4A_7C15
        return h ^ (h >> 32)
    }

    @inline(__always) func rawBytes(_ id: UInt32) -> UnsafeBufferPointer<UInt8> {
        let s = Int(rawOffsets[Int(id)]), e = Int(rawOffsets[Int(id) + 1]) - 1
        return UnsafeBufferPointer(start: raw.base + s, count: e - s)
    }

    @inline(__always) func foldedBytes(_ id: UInt32) -> UnsafeBufferPointer<UInt8> {
        let s = Int(foldedOffsets[Int(id)]), e = Int(foldedOffsets[Int(id) + 1]) - 1
        return UnsafeBufferPointer(start: folded.base + s, count: e - s)
    }

    /// Returns the id for `bytes` without inserting it.
    public func lookup(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt32? {
        var slot = Int(truncatingIfNeeded: Self.hash(p, n)) & tableMask
        while true {
            let v = table[slot]
            if v == 0 { return nil }
            let id = v - 1
            let b = rawBytes(id)
            if b.count == n && memcmp(b.baseAddress!, p, n) == 0 { return id }
            slot = (slot + 1) & tableMask
        }
    }

    public func lookup(_ s: String) -> UInt32? {
        var s = s
        return s.withUTF8 { lookup($0.baseAddress!, $0.count) }
    }

    public func intern(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt32 {
        var slot = Int(truncatingIfNeeded: Self.hash(p, n)) & tableMask
        while true {
            let v = table[slot]
            if v == 0 { break }
            let id = v - 1
            let b = rawBytes(id)
            if b.count == n && memcmp(b.baseAddress!, p, n) == 0 { return id }
            slot = (slot + 1) & tableMask
        }
        let id = UInt32(count)
        append(p, n)
        table[slot] = id + 1
        if count * 10 > (tableMask + 1) * 6 { rehash(capacity: (tableMask + 1) * 2) }
        return id
    }

    public func intern(_ s: String) -> UInt32 {
        var s = s
        return s.withUTF8 { intern($0.baseAddress!, $0.count) }
    }

    private func append(_ p: UnsafePointer<UInt8>, _ n: Int) {
        raw.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
        raw.append(0)
        rawOffsets.append(UInt32(raw.count))

        var ascii = true
        for i in 0..<n where p[i] >= 0x80 { ascii = false; break }
        if ascii {
            cased.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
            folded.reserve(folded.count + n + 1)
            for i in 0..<n {
                let c = p[i]
                folded.append(c &- 65 < 26 ? c | 0x20 : c)
            }
        } else {
            let s = String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
            var nfc = s.precomposedStringWithCanonicalMapping
            var low = nfc.lowercased()
            nfc.withUTF8 { cased.append(contentsOf: $0) }
            low.withUTF8 { folded.append(contentsOf: $0) }
        }
        cased.append(0)
        casedOffsets.append(UInt32(cased.count))
        folded.append(0)
        foldedOffsets.append(UInt32(folded.count))
    }

    private func rehash(capacity: Int) {
        let fresh = PODBuffer<UInt32>(repeating: 0, count: capacity)
        let mask = capacity - 1
        for id in 0..<UInt32(count) {
            let b = rawBytes(id)
            var slot = Int(truncatingIfNeeded: Self.hash(b.baseAddress!, b.count)) & mask
            while fresh[slot] != 0 { slot = (slot + 1) & mask }
            fresh[slot] = id + 1
        }
        table = fresh
        tableMask = mask
    }

    public func string(_ id: UInt32) -> String {
        String(decoding: rawBytes(id), as: UTF8.self)
    }

    // MARK: Name order

    /// Merges names interned since the last call into `sortedIds` and rewrites `rank`.
    /// O(new log new + total); cheap enough to run after every update batch.
    public func commitOrder() {
        let total = count
        guard unsortedFrom < total else { return }
        var fresh = Array(UInt32(unsortedFrom)..<UInt32(total))
        fresh.sort { lessFolded($0, $1) }
        if sortedIds.count == 0 {
            fresh.withUnsafeBufferPointer { sortedIds.append(contentsOf: $0) }
        } else {
            let old = Array(sortedIds.buffer)
            sortedIds.removeAll()
            sortedIds.reserve(old.count + fresh.count)
            var i = 0, j = 0
            while i < old.count && j < fresh.count {
                if lessFolded(fresh[j], old[i]) {
                    sortedIds.append(fresh[j]); j += 1
                } else {
                    sortedIds.append(old[i]); i += 1
                }
            }
            while i < old.count { sortedIds.append(old[i]); i += 1 }
            while j < fresh.count { sortedIds.append(fresh[j]); j += 1 }
        }
        rank.resize(total, fill: 0)
        for (r, id) in sortedIds.buffer.enumerated() { rank[Int(id)] = UInt32(r) }
        unsortedFrom = total
    }

    /// Folded order, ties broken by raw bytes so the order is total.
    func lessFolded(_ a: UInt32, _ b: UInt32) -> Bool {
        let c = compareBytes(foldedBytes(a), foldedBytes(b))
        if c != 0 { return c < 0 }
        return compareBytes(rawBytes(a), rawBytes(b)) < 0
    }

    // MARK: Persistence

    func write(to fd: Int32) throws {
        var header = [UInt64(count), UInt64(raw.count), UInt64(cased.count), UInt64(folded.count),
                      UInt64(table.count), UInt64(sortedIds.count)]
        try writeAll(fd, &header, header.count * 8)
        try raw.write(to: fd); try rawOffsets.write(to: fd)
        try cased.write(to: fd); try casedOffsets.write(to: fd)
        try folded.write(to: fd); try foldedOffsets.write(to: fd)
        try table.write(to: fd)
        try sortedIds.write(to: fd); try rank.write(to: fd)
    }

    static func read(from fd: Int32) throws -> NamePool {
        var header = [UInt64](repeating: 0, count: 6)
        try readAll(fd, &header, 48)
        let pool = NamePool()
        let n = Int(header[0])
        try pool.raw.read(from: fd, count: Int(header[1]))
        try pool.rawOffsets.read(from: fd, count: n + 1)
        try pool.cased.read(from: fd, count: Int(header[2]))
        try pool.casedOffsets.read(from: fd, count: n + 1)
        try pool.folded.read(from: fd, count: Int(header[3]))
        try pool.foldedOffsets.read(from: fd, count: n + 1)
        let tableCount = Int(header[4])
        guard tableCount > 0, tableCount & (tableCount - 1) == 0 else { throw POSIXError(.EINVAL) }
        let table = PODBuffer<UInt32>(capacity: tableCount)
        try table.read(from: fd, count: tableCount)
        pool.table = table
        pool.tableMask = tableCount - 1
        try pool.sortedIds.read(from: fd, count: Int(header[5]))
        try pool.rank.read(from: fd, count: Int(header[5]))
        pool.unsortedFrom = Int(header[5])
        return pool
    }
}

@inline(__always) func compareBytes(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
    let n = min(a.count, b.count)
    if n > 0 {
        let c = memcmp(a.baseAddress!, b.baseAddress!, n)
        if c != 0 { return Int(c) }
    }
    return a.count - b.count
}

/// Applies the same normalisation as `NamePool.folded` / `cased` to query text.
public func normalizeForMatch(_ s: String, caseSensitive: Bool) -> String {
    let nfc = s.precomposedStringWithCanonicalMapping
    return caseSensitive ? nfc : nfc.lowercased()
}

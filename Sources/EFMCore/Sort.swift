import Foundation

public enum SortKey: String, Sendable, CaseIterable {
    case name, path, size, dateModified, dateCreated
}

public struct SearchSort: Sendable, Equatable {
    public var key: SortKey
    public var ascending: Bool

    public init(_ key: SortKey, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    public static let `default` = SearchSort(.name)
}

struct SortItem {
    var key: UInt64
    var entry: UInt32
}

/// LSD radix sort on 64-bit keys with 16-bit digits. Digits that are identical across all
/// keys are skipped, so 32-bit-range keys (name ranks, dates) take two passes.
/// Stable, so ties keep the input order.
func radixSort(_ items: inout [SortItem]) {
    let n = items.count
    guard n > 1 else { return }
    if n < 256 {
        items.sort { $0.key < $1.key }
        return
    }
    var orBits: UInt64 = 0, andBits: UInt64 = ~0
    for it in items { orBits |= it.key; andBits &= it.key }
    let varying = orBits ^ andBits
    var tmp = [SortItem](repeating: SortItem(key: 0, entry: 0), count: n)
    var counts = [Int](repeating: 0, count: 65536)
    items.withUnsafeMutableBufferPointer { a in
        tmp.withUnsafeMutableBufferPointer { b in
            var src = a, dst = b
            var swapped = false
            for shift in stride(from: UInt64(0), to: 64, by: 16) where (varying >> shift) & 0xFFFF != 0 {
                for i in 0..<65536 { counts[i] = 0 }
                for i in 0..<n { counts[Int((src[i].key >> shift) & 0xFFFF)] += 1 }
                var sum = 0
                for i in 0..<65536 {
                    let c = counts[i]
                    counts[i] = sum
                    sum += c
                }
                for i in 0..<n {
                    let d = Int((src[i].key >> shift) & 0xFFFF)
                    dst[counts[d]] = src[i]
                    counts[d] += 1
                }
                swap(&src, &dst)
                swapped.toggle()
            }
            if swapped { a.baseAddress!.update(from: b.baseAddress!, count: n) }
        }
    }
}

extension FileIndex {
    /// Preorder rank of every entry in path order (children visited by name).
    func computePathRanks() -> PODBuffer<UInt32> {
        names.commitOrder()
        let ranks = PODBuffer<UInt32>(repeating: 0, count: capacity)
        var next: UInt32 = 0
        var stack: [UInt32] = [0]
        var kids: [SortItem] = []
        while let e = stack.popLast() {
            ranks[Int(e)] = next
            next += 1
            kids.removeAll(keepingCapacity: true)
            var c = firstChild[Int(e)]
            while c != noEntry {
                kids.append(SortItem(key: UInt64(names.rank[Int(nameId[Int(c)])]), entry: c))
                c = nextSibling[Int(c)]
            }
            kids.sort { $0.key > $1.key } // reversed: the stack pops the smallest first
            for k in kids { stack.append(k.entry) }
        }
        return ranks
    }

    func sortKey(_ e: UInt32, _ key: SortKey, pathRanks: PODBuffer<UInt32>?) -> UInt64 {
        let i = Int(e)
        switch key {
        case .name: return UInt64(names.rank[Int(nameId[i])]) << 32 | UInt64(pathRanks?[i] ?? e)
        case .path: return UInt64(pathRanks![i])
        case .size: return UInt64(bitPattern: size[i])
        case .dateModified: return UInt64(bitPattern: mtime[i] ^ Int64.min)
        case .dateCreated: return UInt64(bitPattern: ctime[i] ^ Int64.min)
        }
    }
}

/// A full sort of all live entries for one key, kept across searches (Everything's "fast sort").
/// Large result sets are produced by filtering this permutation with the match bit set instead
/// of sorting the matches. Entries added or modified after the permutation was built (those in
/// `FileIndex.changeLog` past `logPosition`) are excluded from it and merged in separately, so
/// file-system churn does not force a rebuild. Relative order of existing names survives
/// `NamePool.commitOrder()`, which only inserts new ranks.
final class SortCache {
    let perm: [UInt32]
    let logPosition: Int
    init(perm: [UInt32], logPosition: Int) {
        self.perm = perm
        self.logPosition = logPosition
    }
}

extension FileIndex {
    /// Below this many matches a direct radix sort is cheaper than walking a permutation.
    nonisolated(unsafe) static var permutationThreshold = 40_000
    /// Rebuild a cached permutation once this many entries changed since it was built.
    static let rebuildAfterChanges = 200_000

    func resetChangeLog() {
        changeLog.removeAll()
        sortCacheLock.lock()
        sortCaches.removeAll()
        sortCacheLock.unlock()
    }

    /// Builds the permutation ahead of the first large query (e.g. the empty query).
    func warmSortCache(_ key: SortKey) {
        _ = ensureSortCache(key)
    }

    /// Name ranks from the root down to `e`. Comparing these chains lexicographically gives the
    /// same order as `computePathRanks` (children by name), without a full-tree pass.
    func rankChain(_ e: UInt32) -> [UInt32] {
        var chain: [UInt32] = []
        var x = e
        while x != 0 && x != noEntry {
            chain.append(names.rank[Int(nameId[Int(x)])])
            x = parent[Int(x)]
        }
        chain.reverse()
        return chain
    }

    private func ensureSortCache(_ key: SortKey) -> SortCache {
        sortCacheLock.lock()
        defer { sortCacheLock.unlock() }
        if let c = sortCaches[key], changeLog.count - c.logPosition < Self.rebuildAfterChanges {
            return c
        }
        var items: [SortItem] = []
        items.reserveCapacity(liveCount)
        // The full path order is computed once here and then patched through the change log,
        // so path sorting stays cheap while files change.
        let ranks = key == .path ? computePathRanks() : nil
        for e in 1..<UInt32(capacity) where isLive(e) {
            items.append(SortItem(key: sortKey(e, key, pathRanks: ranks), entry: e))
        }
        radixSort(&items)
        let c = SortCache(perm: items.map(\.entry), logPosition: changeLog.count)
        sortCaches[key] = c
        return c
    }

    func sortedEntries(_ bits: BitSet, order: SearchSort, token: CancelToken) throws -> [UInt32] {
        if names.rank.count < names.count { names.commitOrder() } // only for indexes built outside IndexStore
        let n = bits.cardinality
        var out: [UInt32]
        if n < Self.permutationThreshold && order.key == .path {
            var keyed: [(chain: [UInt32], entry: UInt32)] = []
            keyed.reserveCapacity(n)
            bits.forEach { e in keyed.append((rankChain(UInt32(e)), UInt32(e))) }
            if token.isCancelled { throw SearchError.cancelled }
            keyed.sort { $0.chain.lexicographicallyPrecedes($1.chain) }
            out = keyed.map(\.entry)
        } else if n < Self.permutationThreshold {
            var items: [SortItem] = []
            items.reserveCapacity(n)
            bits.forEach { e in items.append(SortItem(key: sortKey(UInt32(e), order.key, pathRanks: nil), entry: UInt32(e))) }
            if token.isCancelled { throw SearchError.cancelled }
            radixSort(&items)
            out = items.map(\.entry)
        } else {
            out = try sortedFromPermutation(bits, key: order.key, token: token)
        }
        if !order.ascending { out.reverse() }
        return out
    }

    private func sortedFromPermutation(_ bits: BitSet, key: SortKey, token: CancelToken) throws -> [UInt32] {
        let cache = ensureSortCache(key)
        // Entries touched since the permutation was built: their position in it may be stale.
        let dirty = BitSet(count: capacity)
        var extras: [UInt32] = []
        for i in cache.logPosition..<changeLog.count {
            let e = Int(changeLog[i])
            if e < capacity, !dirty.contains(e) {
                dirty.insert(e)
                if bits.contains(e) { extras.append(UInt32(e)) }
            }
        }

        // Filter the permutation in parallel chunks, then concatenate in order.
        let perm = cache.perm
        let parts = activeProcessorCount * 2
        let per = (perm.count + parts - 1) / max(parts, 1)
        var pieces = [[UInt32]](repeating: [], count: parts)
        pieces.withUnsafeMutableBufferPointer { pieceBuf in
            perm.withUnsafeBufferPointer { p in
                DispatchQueue.concurrentPerform(iterations: parts) { c in
                    let lo = c * per, hi = min(lo + per, p.count)
                    guard lo < hi else { return }
                    var local: [UInt32] = []
                    local.reserveCapacity((hi - lo) / 4)
                    for i in lo..<hi {
                        let e = Int(p[i])
                        if bits.contains(e) && !dirty.contains(e) { local.append(p[i]) }
                    }
                    pieceBuf[c] = local
                }
            }
        }
        if token.isCancelled { throw SearchError.cancelled }
        var main: [UInt32] = []
        main.reserveCapacity(pieces.reduce(0) { $0 + $1.count } + extras.count)
        for p in pieces { main.append(contentsOf: p) }
        guard !extras.isEmpty else { return main }

        // Merge the (few) changed entries into place.
        let less: (UInt32, UInt32) -> Bool
        if key == .path {
            less = { self.rankChain($0).lexicographicallyPrecedes(self.rankChain($1)) }
        } else {
            less = { self.sortKey($0, key, pathRanks: nil) < self.sortKey($1, key, pathRanks: nil) }
        }
        extras.sort(by: less)
        var merged: [UInt32] = []
        merged.reserveCapacity(main.count + extras.count)
        var lo = 0
        for x in extras {
            var a = lo, b = main.count
            while a < b {
                let m = (a + b) / 2
                if less(main[m], x) { a = m + 1 } else { b = m }
            }
            merged.append(contentsOf: main[lo..<a])
            merged.append(x)
            lo = a
        }
        merged.append(contentsOf: main[lo...])
        return merged
    }
}

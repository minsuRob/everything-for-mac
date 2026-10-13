import CEFM
import EFMQuery
import Foundation

public struct SearchOptions: Sendable, Equatable {
    public var caseSensitive: Bool
    public var sort: SearchSort

    public init(caseSensitive: Bool = false, sort: SearchSort = .default) {
        self.caseSensitive = caseSensitive
        self.sort = sort
    }
}

public struct SearchResult: Sendable {
    public var entries: [UInt32]
    public var elapsed: TimeInterval
    /// Literal terms for highlighting matches in the UI.
    public var highlights: [String]
    public var generation: UInt64
}

public enum SearchError: Error, CustomStringConvertible {
    case parse(String)
    case unsupported(String)
    case invalidArgument(String)
    case cancelled

    public var description: String {
        switch self {
        case .parse(let m): "Invalid query: \(m)"
        case .unsupported(let f): "Filter not supported: \(f)"
        case .invalidArgument(let m): m
        case .cancelled: "Cancelled"
        }
    }
}

/// Cancellation flag readable from C kernels.
public final class CancelToken: @unchecked Sendable {
    let flag: UnsafeMutablePointer<Int32>
    public init() {
        flag = .allocate(capacity: 1)
        flag.initialize(to: 0)
    }
    deinit { flag.deallocate() }
    public func cancel() { flag.pointee = 1 }
    public var isCancelled: Bool { flag.pointee != 0 }
}

/// Evaluates one query against a `FileIndex`.
///
/// Every sub-expression produces a bit set over entry slots, so AND/OR/NOT are word-wide
/// bit operations. Cardinal materialises each term as a `Vec` of node ids and intersects
/// through a `HashSet`, which allocates per term and degrades with large result sets.
/// Name terms are matched once per *unique* name (in parallel, SIMD substring search), then
/// projected onto entries.
final class QueryEvaluator {
    let index: FileIndex
    let names: NamePool
    let options: SearchOptions
    let token: CancelToken
    let live: BitSet
    let chunkCount: Int
    private var nameCache: [String: BitSet] = [:]
    private(set) var highlights: [String] = []

    init(index: FileIndex, options: SearchOptions, token: CancelToken) {
        self.index = index
        self.names = index.names
        self.options = options
        self.token = token
        chunkCount = activeProcessorCount * 4
        live = BitSet(count: index.capacity)
        let flags = index.flags.base
        let live = self.live
        let chunks = alignedChunks(index.capacity, parts: chunkCount)
        DispatchQueue.concurrentPerform(iterations: chunks.count) { c in
            let r = chunks[c]
            var base = r.lowerBound
            while base < r.upperBound {
                var word: UInt64 = 0
                let stop = min(base + 64, r.upperBound)
                for e in base..<stop where flags[e] & EntryFlags.deleted.rawValue == 0 {
                    word |= 1 << UInt64(e - base)
                }
                live.words[base >> 6] = word
                base += 64
            }
        }
        if index.capacity > 0 { live.words[0] &= ~1 } // never return the root itself
    }

    func checkCancelled() throws {
        if token.isCancelled { throw SearchError.cancelled }
    }

    // MARK: Expressions

    func evaluate(_ expr: Expr, candidates: BitSet?) throws -> BitSet {
        try checkCancelled()
        switch expr {
        case .empty:
            return (candidates ?? live).copy()
        case .term(let t):
            return try evaluateTerm(t, candidates: candidates, caseSensitive: options.caseSensitive)
        case .not(let inner):
            let base = (candidates ?? live).copy()
            base.subtract(try evaluate(inner, candidates: candidates))
            return base
        case .or(let parts):
            let acc = BitSet(count: index.capacity)
            for p in parts { acc.formUnion(try evaluate(p, candidates: candidates)) }
            return acc
        case .and(let parts):
            var current = candidates
            for p in parts.sorted(by: { cost($0) < cost($1) }) {
                let r = try evaluate(p, candidates: current)
                if let c = current, !isSubsetByConstruction(p) { r.formIntersection(c) }
                current = r
                if r.isEmpty { break }
            }
            return current ?? live.copy()
        }
    }

    /// Terms that already restrict themselves to `candidates` don't need a second intersection.
    private func isSubsetByConstruction(_ e: Expr) -> Bool {
        if case .term(.filter(let f)) = e {
            switch f.kind {
            case .content, .tag, .size, .dateModified, .dateCreated: return true
            default: return false
            }
        }
        return false
    }

    /// Rough evaluation cost used to order AND operands (cheap first, so expensive filters
    /// like `content:` only see the survivors).
    private func cost(_ e: Expr) -> Int {
        switch e {
        case .empty: return 0
        case .not(let i): return cost(i) + 1
        case .and(let ps), .or(let ps): return ps.map(cost).max() ?? 0
        case .term(let t):
            switch t {
            case .word(let w): return w.contains("/") ? 30 : 10
            case .phrase: return 10
            case .regex: return 40
            case .filter(let f):
                switch f.kind {
                case .file, .folder: return 1
                case .ext, .type, .audio, .video, .doc, .exe: return 5
                case .parent, .inFolder, .noSubfolders: return 6
                case .size, .dateModified, .dateCreated: return 8
                case .caseSensitive: return 10
                case .content: return 1000
                case .tag: return 900
                case .unsupported: return 0
                }
            }
        }
    }

    func evaluateTerm(_ term: Term, candidates: BitSet?, caseSensitive cs: Bool) throws -> BitSet {
        switch term {
        case .word(let w):
            return try evaluateWord(w, caseSensitive: cs)
        case .phrase(let p):
            highlights.append(p)
            return try entries(fromNames: nameLiteral(p, kind: Int32(EFM_MATCH_SUBSTR), cs: cs))
        case .regex(let pattern):
            return try entries(fromNames: nameRegex(pattern, cs: cs))
        case .filter(let f):
            return try evaluateFilter(f, candidates: candidates, caseSensitive: cs)
        }
    }

    // MARK: Words and path segments

    func evaluateWord(_ word: String, caseSensitive cs: Bool) throws -> BitSet {
        let pattern = pathPattern(forWord: word)
        let segs = pattern.segments
        if segs.isEmpty { return live.copy() }
        if segs.count == 1 {
            return try entries(fromNames: try segmentNames(segs[0], cs: cs) ?? allNames())
        }
        return try evaluateChain(segs, cs: cs)
    }

    /// Unique-name bit set for one segment; nil means "any name".
    func segmentNames(_ seg: Segment, cs: Bool) throws -> BitSet? {
        switch seg {
        case .literal(let s, let kind):
            highlights.append(s)
            let k: Int32 = switch kind {
            case .substr: Int32(EFM_MATCH_SUBSTR)
            case .prefix: Int32(EFM_MATCH_PREFIX)
            case .suffix: Int32(EFM_MATCH_SUFFIX)
            case .exact: Int32(EFM_MATCH_EXACT)
            }
            return try nameLiteral(s, kind: k, cs: cs)
        case .wildcard(let p):
            switch reduceGlob(p) {
            case .all: return nil
            case .literal(let s, let k):
                highlights.append(s)
                return try nameLiteral(s, kind: k, cs: cs)
            case .glob(let g): return try nameGlob(g, cs: cs)
            }
        case .star, .globstar:
            return nil
        }
    }

    /// Slash-separated pattern: the last segment matches the entry, earlier ones match a
    /// contiguous chain of ancestors; `**` spans any number of folders.
    func evaluateChain(_ segs: [Segment], cs: Bool) throws -> BitSet {
        var sets: [BitSet?] = []
        for s in segs { sets.append(try segmentNames(s, cs: cs)) }
        let lastIsGlobstar = segs.last == .globstar
        let out = BitSet(count: index.capacity)
        let nameId = index.nameId.base, parent = index.parent.base
        let live = self.live

        func matches(_ e: UInt32, _ i: Int) -> Bool {
            if i < 0 { return true }
            if segs[i] == .globstar {
                if matches(e, i - 1) { return true }
                let p = parent[Int(e)]
                return p != noEntry && matches(p, i)
            }
            guard e != 0, e != noEntry else { return false }
            if let s = sets[i], !s.contains(Int(nameId[Int(e)])) { return false }
            if i == 0 { return true }
            let p = parent[Int(e)]
            return p != noEntry && matches(p, i - 1)
        }

        let first: BitSet
        if lastIsGlobstar {
            first = live
        } else {
            first = try entries(fromNames: sets.last! ?? allNames())
        }
        let chunks = alignedChunks(index.capacity, parts: chunkCount)
        let flag = token.flag
        DispatchQueue.concurrentPerform(iterations: chunks.count) { c in
            let r = chunks[c]
            var w = r.lowerBound >> 6
            let wEnd = (r.upperBound + 63) >> 6
            while w < wEnd {
                if flag.pointee != 0 { return }
                var word = first.words[w]
                var outWord: UInt64 = 0
                while word != 0 {
                    let bit = word.trailingZeroBitCount
                    word &= word - 1
                    let e = UInt32(w << 6 | bit)
                    let ok: Bool
                    if lastIsGlobstar {
                        // Results are strict descendants of a node matching the prefix chain.
                        var a = parent[Int(e)]
                        var found = false
                        while a != noEntry {
                            if matches(a, segs.count - 2) { found = true; break }
                            a = parent[Int(a)]
                        }
                        ok = found
                    } else {
                        ok = matches(e, segs.count - 1)
                    }
                    if ok { outWord |= 1 << UInt64(bit) }
                }
                out.words[w] = outWord & live.words[w]
                w += 1
            }
        }
        try checkCancelled()
        return out
    }

    // MARK: Filters

    func evaluateFilter(_ f: Filter, candidates: BitSet?, caseSensitive cs: Bool) throws -> BitSet {
        let arg = f.argument
        switch f.kind {
        case .file, .folder:
            let wantDir = f.kind == .folder
            let r = flagFilter { flags in (flags & EntryFlags.directory.rawValue != 0) == wantDir }
            if let arg, !arg.raw.isEmpty { r.formIntersection(try argumentAsName(arg, cs: cs)) }
            return r
        case .ext:
            guard let arg else { throw SearchError.invalidArgument("ext: needs an extension") }
            return try entries(fromNames: nameExtensions(normalizedExtensions(arg)))
        case .type, .audio, .video, .doc, .exe:
            let typeName: String
            var extra: FilterArgument?
            switch f.kind {
            case .type:
                guard let a = arg else { throw SearchError.invalidArgument("type: needs a category") }
                typeName = a.raw
            case .audio: typeName = "audio"; extra = arg
            case .video: typeName = "video"; extra = arg
            case .doc: typeName = "doc"; extra = arg
            default: typeName = "exe"; extra = arg
            }
            let r: BitSet
            switch TypeGroups.target(forTypeName: typeName) {
            case .files: r = flagFilter { $0 & EntryFlags.directory.rawValue == 0 }
            case .folders: r = flagFilter { $0 & EntryFlags.directory.rawValue != 0 }
            case .extensions(let exts): r = try entries(fromNames: nameExtensions(exts))
            case nil: throw SearchError.invalidArgument("Unknown type: \(typeName)")
            }
            if let extra, !extra.raw.isEmpty { r.formIntersection(try argumentAsName(extra, cs: cs)) }
            return r
        case .size:
            guard let arg else { throw SearchError.invalidArgument("size: needs a value") }
            let pred = try SizePredicate.parse(arg)
            let sizes = index.size.base
            return entryFilter(candidates: candidates, filesOnly: true) { pred.matches(sizes[$0]) }
        case .dateModified, .dateCreated:
            guard let arg else { throw SearchError.invalidArgument("Date filter needs a value") }
            let pred = try DatePredicate.parse(arg, now: Date(), calendar: .current)
            let times = f.kind == .dateModified ? index.mtime.base : index.ctime.base
            return entryFilter(candidates: candidates, filesOnly: false) { pred.matches(times[$0]) }
        case .parent, .inFolder, .noSubfolders:
            guard let arg, !arg.raw.isEmpty else { throw SearchError.invalidArgument("Folder filter needs a path") }
            let path = arg.raw.count > 1 && arg.raw.hasSuffix("/") ? String(arg.raw.dropLast()) : arg.raw
            let node = cs ? index.lookup(path: path) : index.lookupCaseInsensitive(path: path)
            let out = BitSet(count: index.capacity)
            guard let node else { return out }
            switch f.kind {
            case .parent:
                for c in index.children(of: node) { out.insert(Int(c)) }
            case .noSubfolders:
                out.insert(Int(node))
                for c in index.children(of: node) where !index.isDirectory(c) { out.insert(Int(c)) }
            default:
                var stack = index.children(of: node)
                while let e = stack.popLast() {
                    out.insert(Int(e))
                    var c = index.firstChild[Int(e)]
                    while c != noEntry { stack.append(c); c = index.nextSibling[Int(c)] }
                }
            }
            out.formIntersection(live)
            return out
        case .content:
            guard let arg, !arg.raw.isEmpty else { throw SearchError.invalidArgument("content: needs text") }
            return try contentFilter(needle: arg.raw, candidates: candidates, caseSensitive: cs)
        case .tag:
            guard let arg, !arg.raw.isEmpty else { throw SearchError.invalidArgument("tag: needs a tag name") }
            let wanted: [String]
            if case .list(let items) = arg.kind { wanted = items } else { wanted = [arg.raw] }
            return try tagFilter(wanted: wanted, candidates: candidates, caseSensitive: cs)
        case .caseSensitive:
            guard let arg, !arg.raw.isEmpty else { return live.copy() }
            if arg.kind == .phrase {
                return try evaluateTerm(.phrase(arg.raw), candidates: candidates, caseSensitive: true)
            }
            return try evaluateWord(arg.raw, caseSensitive: true)
        case .unsupported(let name):
            throw SearchError.unsupported(name)
        }
    }

    private func argumentAsName(_ arg: FilterArgument, cs: Bool) throws -> BitSet {
        if arg.kind == .phrase {
            return try entries(fromNames: nameLiteral(arg.raw, kind: Int32(EFM_MATCH_SUBSTR), cs: cs))
        }
        return try evaluateWord(arg.raw, caseSensitive: cs)
    }

    func flagFilter(_ pass: @escaping @Sendable (UInt8) -> Bool) -> BitSet {
        let out = BitSet(count: index.capacity)
        let flags = index.flags.base
        let live = self.live
        let chunks = alignedChunks(index.capacity, parts: chunkCount)
        DispatchQueue.concurrentPerform(iterations: chunks.count) { c in
            let r = chunks[c]
            var base = r.lowerBound
            while base < r.upperBound {
                var word: UInt64 = 0
                for e in base..<min(base + 64, r.upperBound) where pass(flags[e]) {
                    word |= 1 << UInt64(e - base)
                }
                out.words[base >> 6] = word & live.words[base >> 6]
                base += 64
            }
        }
        return out
    }

    /// Per-entry predicate over `candidates` (or all live entries).
    func entryFilter(candidates: BitSet?, filesOnly: Bool, _ pass: @escaping @Sendable (Int) -> Bool) -> BitSet {
        let src = candidates ?? live
        let out = BitSet(count: index.capacity)
        let flags = index.flags.base
        let wordsCount = src.wordCount
        let parts = max(1, min(chunkCount, wordsCount / 64))
        let per = (wordsCount + parts - 1) / parts
        DispatchQueue.concurrentPerform(iterations: parts) { c in
            let lo = c * per, hi = min(lo + per, wordsCount)
            guard lo < hi else { return }
            for w in lo..<hi {
                var word = src.words[w]
                var o: UInt64 = 0
                while word != 0 {
                    let bit = word.trailingZeroBitCount
                    word &= word - 1
                    let e = w << 6 | bit
                    if filesOnly && flags[e] & EntryFlags.directory.rawValue != 0 { continue }
                    if pass(e) { o |= 1 << UInt64(bit) }
                }
                out.words[w] = o
            }
        }
        return out
    }

    // MARK: Unique-name matching

    func allNames() -> BitSet { BitSet(count: names.count, filled: true) }

    func nameLiteral(_ text: String, kind: Int32, cs: Bool) throws -> BitSet {
        let key = "L\(kind)\(cs ? 1 : 0)\u{0}\(text)"
        if let hit = nameCache[key] { return hit }
        var needle = normalizeForMatch(text, caseSensitive: cs)
        let out = BitSet(count: names.count)
        let blob = cs ? names.cased : names.folded
        let offsets = cs ? names.casedOffsets : names.foldedOffsets
        if needle.utf8.contains(0) { return out }
        let chunks = alignedChunks(names.count, parts: chunkCount)
        let flag = token.flag
        needle.withUTF8 { n in
            let np = n.baseAddress!, nc = n.count
            DispatchQueue.concurrentPerform(iterations: chunks.count) { c in
                let r = chunks[c]
                _ = efm_match_names(blob.base, offsets.base, UInt32(r.lowerBound), UInt32(r.upperBound),
                                    np, nc, kind, out.words, flag)
            }
        }
        try checkCancelled()
        nameCache[key] = out
        return out
    }

    func nameGlob(_ pattern: String, cs: Bool) throws -> BitSet {
        var pat = normalizeForMatch(pattern, caseSensitive: cs)
        let out = BitSet(count: names.count)
        let blob = (cs ? names.cased : names.folded).base
        let offsets = (cs ? names.casedOffsets : names.foldedOffsets).base
        let chunks = alignedChunks(names.count, parts: chunkCount)
        pat.withUTF8 { p in
            DispatchQueue.concurrentPerform(iterations: chunks.count) { c in
                let r = chunks[c]
                var base = r.lowerBound
                while base < r.upperBound {
                    var word: UInt64 = 0
                    for i in base..<min(base + 64, r.upperBound) {
                        let s = Int(offsets[i]), e = Int(offsets[i + 1]) - 1
                        if globMatch(p, UnsafeBufferPointer(start: blob + s, count: e - s)) {
                            word |= 1 << UInt64(i - base)
                        }
                    }
                    out.words[base >> 6] = word
                    base += 64
                }
            }
        }
        try checkCancelled()
        return out
    }

    func nameRegex(_ pattern: String, cs: Bool) throws -> BitSet {
        let opts: NSRegularExpression.Options = cs ? [] : [.caseInsensitive]
        do { _ = try NSRegularExpression(pattern: pattern, options: opts) } catch {
            throw SearchError.invalidArgument("Invalid regex: \(pattern)")
        }
        // Prefilter: a literal every match must contain is found with the SIMD kernel first,
        // so the (slow, allocating) regex engine only sees candidate names.
        let candidates: BitSet
        if let lit = requiredLiteral(inRegex: pattern) {
            candidates = try nameLiteral(lit, kind: Int32(EFM_MATCH_SUBSTR), cs: cs)
        } else {
            candidates = allNames()
        }
        let out = BitSet(count: names.count)
        let blob = names.cased.base
        let offsets = names.casedOffsets.base
        let chunks = alignedChunks(names.count, parts: chunkCount)
        let flag = token.flag
        DispatchQueue.concurrentPerform(iterations: chunks.count) { c in
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return }
            let r = chunks[c]
            var w = r.lowerBound >> 6
            let wEnd = (r.upperBound + 63) >> 6
            while w < wEnd {
                if flag.pointee != 0 { return }
                var word = candidates.words[w]
                var o: UInt64 = 0
                while word != 0 {
                    let bit = word.trailingZeroBitCount
                    word &= word - 1
                    let i = w << 6 | bit
                    let s = Int(offsets[i]), e = Int(offsets[i + 1]) - 1
                    let str = String(decoding: UnsafeBufferPointer(start: blob + s, count: e - s), as: UTF8.self)
                    if re.firstMatch(in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length)) != nil {
                        o |= 1 << UInt64(bit)
                    }
                }
                out.words[w] = o
                w += 1
            }
        }
        try checkCancelled()
        return out
    }

    func nameExtensions(_ exts: Set<String>) throws -> BitSet {
        let key = "E\u{0}" + exts.sorted().joined(separator: ";")
        if let hit = nameCache[key] { return hit }
        let wanted = exts.map { Array(normalizeForMatch($0, caseSensitive: false).utf8) }
        let out = BitSet(count: names.count)
        let blob = names.folded.base
        let offsets = names.foldedOffsets.base
        let chunks = alignedChunks(names.count, parts: chunkCount)
        DispatchQueue.concurrentPerform(iterations: chunks.count) { c in
            let r = chunks[c]
            var base = r.lowerBound
            while base < r.upperBound {
                var word: UInt64 = 0
                for i in base..<min(base + 64, r.upperBound) {
                    let s = Int(offsets[i]), e = Int(offsets[i + 1]) - 1
                    var dot = e - 1
                    while dot > s && blob[dot] != UInt8(ascii: ".") { dot -= 1 }
                    guard dot > s else { continue } // no dot, or a leading-dot name like ".zshrc"
                    let extLen = e - dot - 1
                    for w in wanted where w.count == extLen {
                        if w.withUnsafeBufferPointer({ memcmp($0.baseAddress!, blob + dot + 1, extLen) == 0 }) {
                            word |= 1 << UInt64(i - base)
                            break
                        }
                    }
                }
                out.words[base >> 6] = word
                base += 64
            }
        }
        nameCache[key] = out
        return out
    }

    /// Projects a unique-name bit set onto live entries.
    func entries(fromNames nameBits: BitSet) throws -> BitSet {
        let out = BitSet(count: index.capacity)
        let chunks = alignedChunks(index.capacity, parts: chunkCount)
        let ids = index.nameId.base, flags = index.flags.base
        DispatchQueue.concurrentPerform(iterations: chunks.count) { c in
            let r = chunks[c]
            _ = efm_entries_from_names(ids, flags, UInt32(r.lowerBound), UInt32(r.upperBound), nameBits.words,
                                       EntryFlags.deleted.rawValue, 0, out.words)
        }
        out.words[0] &= ~1
        try checkCancelled()
        return out
    }
}

extension FileIndex {
    /// Runs a query. Caller must hold at least shared access to the index.
    public func search(_ query: String, options: SearchOptions = SearchOptions(),
                       token: CancelToken = CancelToken()) throws -> SearchResult {
        let start = DispatchTime.now()
        let parsed: Expr
        do { parsed = try parseQuery(query) } catch { throw SearchError.parse("\(error)") }
        let expr = preprocess(parsed, homeDirectory: NSHomeDirectory())
        let evaluator = QueryEvaluator(index: self, options: options, token: token)
        let bits = try evaluator.evaluate(expr, candidates: nil)
        let entries = try sortedEntries(bits, order: options.sort, token: token)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        return SearchResult(entries: entries, elapsed: elapsed, highlights: evaluator.highlights, generation: generation)
    }

}

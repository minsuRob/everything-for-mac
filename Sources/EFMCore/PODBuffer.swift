import Foundation

/// Growable array of trivially copyable values backed by one malloc block.
/// Unlike `Array`, the storage pointer can be handed to C, written to disk as raw bytes,
/// and read from many threads without retain/release or exclusivity checks.
public final class PODBuffer<T: BitwiseCopyable>: @unchecked Sendable {
    public private(set) var base: UnsafeMutablePointer<T>
    public private(set) var count: Int = 0
    public private(set) var capacity: Int

    public init(capacity: Int = 16) {
        self.capacity = max(capacity, 16)
        base = .allocate(capacity: self.capacity)
    }

    public convenience init(repeating value: T, count: Int) {
        self.init(capacity: count)
        base.initialize(repeating: value, count: count)
        self.count = count
    }

    deinit { base.deallocate() }

    @inline(__always) public subscript(i: Int) -> T {
        get { base[i] }
        set { base[i] = newValue }
    }

    public func reserve(_ minimum: Int) {
        guard minimum > capacity else { return }
        var cap = capacity
        while cap < minimum { cap = cap * 3 / 2 + 16 }
        let fresh = UnsafeMutablePointer<T>.allocate(capacity: cap)
        fresh.moveInitialize(from: base, count: count)
        base.deallocate()
        base = fresh
        capacity = cap
    }

    @inline(__always) public func append(_ value: T) {
        if count == capacity { reserve(count + 1) }
        base[count] = value
        count += 1
    }

    public func append(contentsOf src: UnsafeBufferPointer<T>) {
        reserve(count + src.count)
        (base + count).update(from: src.baseAddress!, count: src.count)
        count += src.count
    }

    public func removeAll(keepingCapacity: Bool = true) {
        count = 0
    }

    /// Sets `count` to `n`, filling any new slots with `fill`.
    public func resize(_ n: Int, fill: T) {
        reserve(n)
        if n > count { (base + count).initialize(repeating: fill, count: n - count) }
        count = n
    }

    public var buffer: UnsafeBufferPointer<T> { UnsafeBufferPointer(start: base, count: count) }
    public var byteCount: Int { count * MemoryLayout<T>.stride }

    // MARK: Raw I/O

    func write(to fd: Int32) throws {
        try writeAll(fd, UnsafeRawPointer(base), byteCount)
    }

    func read(from fd: Int32, count n: Int) throws {
        reserve(n)
        try readAll(fd, UnsafeMutableRawPointer(base), n * MemoryLayout<T>.stride)
        count = n
    }
}

/// Fixed-size bit set over [0, count). Word-aligned so chunks of 64 can be filled in parallel.
public struct BitSet: @unchecked Sendable {
    public let count: Int
    public let words: UnsafeMutablePointer<UInt64>
    public var wordCount: Int { (count + 63) >> 6 }
    private let owner: Owner

    private final class Owner: @unchecked Sendable {
        let p: UnsafeMutablePointer<UInt64>
        init(_ p: UnsafeMutablePointer<UInt64>) { self.p = p }
        deinit { p.deallocate() }
    }

    public init(count: Int, filled: Bool = false) {
        self.count = count
        let n = max((count + 63) >> 6, 1)
        words = .allocate(capacity: n)
        words.initialize(repeating: filled ? ~0 : 0, count: n)
        owner = Owner(words)
        if filled { clearTail() }
    }

    private func clearTail() {
        let extra = count & 63
        if extra != 0 { words[(count >> 6)] &= (1 << UInt64(extra)) - 1 }
        if count == 0 { words[0] = 0 }
    }

    @inline(__always) public func contains(_ i: Int) -> Bool {
        (words[i >> 6] >> UInt64(i & 63)) & 1 != 0
    }

    @inline(__always) public func insert(_ i: Int) {
        words[i >> 6] |= 1 << UInt64(i & 63)
    }

    public func copy() -> BitSet {
        let c = BitSet(count: count)
        c.words.update(from: words, count: max(wordCount, 1))
        return c
    }

    public func formIntersection(_ o: BitSet) {
        for w in 0..<wordCount { words[w] &= o.words[w] }
    }

    public func formUnion(_ o: BitSet) {
        for w in 0..<wordCount { words[w] |= o.words[w] }
    }

    public func subtract(_ o: BitSet) {
        for w in 0..<wordCount { words[w] &= ~o.words[w] }
    }

    public var cardinality: Int {
        var n = 0
        for w in 0..<wordCount { n += words[w].nonzeroBitCount }
        return n
    }

    public var isEmpty: Bool {
        for w in 0..<wordCount where words[w] != 0 { return false }
        return true
    }

    /// Calls `body` for each set bit in ascending order.
    @inline(__always) public func forEach(_ body: (Int) -> Void) {
        for w in 0..<wordCount {
            var word = words[w]
            while word != 0 {
                body(w << 6 | word.trailingZeroBitCount)
                word &= word - 1
            }
        }
    }
}

func writeAll(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) throws {
    var done = 0
    while done < n {
        let r = Darwin.write(fd, p + done, min(n - done, 1 << 30))
        if r < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        done += r
    }
}

func readAll(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ n: Int) throws {
    var done = 0
    while done < n {
        let r = Darwin.read(fd, p + done, min(n - done, 1 << 30))
        if r < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if r == 0 { throw POSIXError(.EIO) }
        done += r
    }
}

/// Splits [0, n) into `parts` ranges whose bounds (except the last) are multiples of 64,
/// so each range owns whole bit-set words.
func alignedChunks(_ n: Int, parts: Int) -> [Range<Int>] {
    guard n > 0 else { return [] }
    let per = max(((n / max(parts, 1)) + 63) & ~63, 4096)
    var out: [Range<Int>] = []
    var lo = 0
    while lo < n {
        out.append(lo..<min(lo + per, n))
        lo += per
    }
    return out
}

let activeProcessorCount = ProcessInfo.processInfo.activeProcessorCount

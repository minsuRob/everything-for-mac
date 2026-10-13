// Ported from cardisoft/cardinal (MIT): query-segmentation/src/lib.rs and
// search-cache/src/segment.rs.

/// How a literal segment is compared against one path component.
public enum SegmentKind: Sendable, Equatable {
    case substr, prefix, suffix, exact
}

public enum Segment: Sendable, Equatable {
    /// No wildcard; compared according to `SegmentKind`.
    case literal(String, SegmentKind)
    /// Contains `*` or `?`; always a whole-component glob match (see `globMatches`).
    case wildcard(String)
    /// Exactly `*`: any single component.
    case star
    /// Exactly `**`: zero or more components.
    case globstar
}

/// Slash-separated word split into per-component matchers. The item that
/// matches the final segment is the result; earlier segments must match its
/// ancestors as a contiguous chain (with `**` allowing gaps).
public struct PathPattern: Sendable, Equatable {
    public var segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }
}

/// Splits a word on `/` and classifies each segment.
///
/// A segment has a left boundary when it is not first or the word starts with
/// `/`, and a right boundary when it is not last or the word ends with `/`:
/// both → exact, left → prefix, right → suffix, neither → substring.
/// Returns no segments for `""`, `/`, `///` or words with empty inner
/// segments (`a//b`), which Cardinal rejects as unprocessable.
public func pathPattern(forWord word: String) -> PathPattern {
    let leftClosed = word.hasPrefix("/")
    let rightClosed = word.hasSuffix("/")
    let trimmed = word.drop(while: { $0 == "/" }).reversed().drop(while: { $0 == "/" }).reversed()
    guard !trimmed.isEmpty else { return PathPattern(segments: []) }

    let parts = String(trimmed).split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.contains(where: \.isEmpty) else { return PathPattern(segments: []) }

    let last = parts.count - 1
    let segments = parts.enumerated().map { index, part -> Segment in
        switch part {
        case "**": return .globstar
        case "*": return .star
        default:
            let text = String(part)
            if text.contains(where: { $0 == "*" || $0 == "?" }) { return .wildcard(text) }
            let left = index > 0 || leftClosed
            let right = index < last || rightClosed
            let kind: SegmentKind = switch (left, right) {
            case (true, true): .exact
            case (true, false): .prefix
            case (false, true): .suffix
            case (false, false): .substr
            }
            return .literal(text, kind)
        }
    }
    return PathPattern(segments: segments)
}

// MARK: Glob matching

/// Whole-string glob match: `*` matches any run, `?` exactly one Unicode scalar.
/// Case-insensitive matching folds ASCII in place and lowercases both sides
/// only when the pattern has non-ASCII characters.
public func globMatches(_ pattern: String, _ name: String, caseInsensitive: Bool) -> Bool {
    if caseInsensitive && !pattern.utf8.allSatisfy({ $0 < 0x80 }) {
        return GlobPattern(pattern, caseInsensitive: true).matches(name)
    }
    let result = pattern.utf8.withContiguousStorageIfAvailable { p in
        name.utf8.withContiguousStorageIfAvailable { n in globCore(p, n, fold: caseInsensitive) }
    }
    return (result ?? nil) ?? GlobPattern(pattern, caseInsensitive: caseInsensitive).matches(name)
}

/// Precompiled glob for matching many names against one pattern.
public struct GlobPattern: Sendable {
    public let pattern: String
    public let caseInsensitive: Bool
    /// Pattern bytes; lowercased when case-insensitive.
    private let bytes: [UInt8]
    /// Case-insensitive with non-ASCII letters in the pattern: names are lowercased per call.
    private let lowercasesNames: Bool

    public init(_ pattern: String, caseInsensitive: Bool) {
        self.pattern = pattern
        self.caseInsensitive = caseInsensitive
        let ascii = pattern.utf8.allSatisfy { $0 < 0x80 }
        lowercasesNames = caseInsensitive && !ascii
        if !caseInsensitive {
            bytes = Array(pattern.utf8)
        } else if ascii {
            bytes = pattern.utf8.map(asciiLower)
        } else {
            bytes = Array(pattern.lowercased().utf8)
        }
    }

    public func matches(_ name: String) -> Bool {
        if lowercasesNames {
            return matchesBytes(Array(name.lowercased().utf8), fold: false)
        }
        if let result = name.utf8.withContiguousStorageIfAvailable({ matches(utf8: $0) }) {
            return result
        }
        return matchesBytes(Array(name.utf8), fold: caseInsensitive)
    }

    /// Matches a UTF-8 encoded name without allocating (except for non-ASCII case-insensitive patterns).
    public func matches(utf8 name: UnsafeBufferPointer<UInt8>) -> Bool {
        if lowercasesNames {
            let lowered = String(decoding: name, as: UTF8.self).lowercased()
            return matchesBytes(Array(lowered.utf8), fold: false)
        }
        return bytes.withUnsafeBufferPointer { globCore($0, name, fold: caseInsensitive) }
    }

    private func matchesBytes(_ name: [UInt8], fold: Bool) -> Bool {
        bytes.withUnsafeBufferPointer { p in
            name.withUnsafeBufferPointer { n in globCore(p, n, fold: fold) }
        }
    }
}

@inline(__always)
private func asciiLower(_ b: UInt8) -> UInt8 {
    b &- 0x41 < 26 ? b | 0x20 : b
}

/// Length of the UTF-8 sequence starting with `lead` (1 for stray continuation bytes).
@inline(__always)
private func scalarWidth(_ lead: UInt8) -> Int {
    lead < 0xC0 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
}

/// Iterative glob with single-star backtracking: O(|p|·|n|) worst case, no allocation.
/// After a failed attempt the star skips straight to the next byte that can start
/// the following literal (safe in UTF-8: such bytes are always scalar boundaries).
private func globCore(_ p: UnsafeBufferPointer<UInt8>, _ n: UnsafeBufferPointer<UInt8>, fold: Bool) -> Bool {
    @inline(__always) func same(_ a: UInt8, _ b: UInt8) -> Bool {
        fold ? asciiLower(a) == asciiLower(b) : a == b
    }
    let pc = p.count, nc = n.count
    var pi = 0, ni = 0
    var starP = -1, starN = 0
    while true {
        if pi < pc {
            let c = p[pi]
            if c == 0x2A { // *
                pi += 1
                if pi == pc { return true }
                starP = pi - 1
                starN = ni
                continue
            }
            if ni < nc {
                if c == 0x3F { // ?
                    ni = min(ni + scalarWidth(n[ni]), nc)
                    pi += 1
                    continue
                }
                if same(c, n[ni]) {
                    pi += 1
                    ni += 1
                    continue
                }
            }
        } else if ni == nc {
            return true
        }
        guard starP >= 0, starN < nc else { return false }
        starN = min(starN + scalarWidth(n[starN]), nc)
        let next = p[starP + 1]
        if next != 0x3F {
            while starN < nc && !same(next, n[starN]) { starN += 1 }
        }
        ni = starN
        pi = starP + 1
    }
}

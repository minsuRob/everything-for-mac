/// Whole-string glob over UTF-8 bytes: `*` matches any run, `?` matches one Unicode scalar.
/// Iterative with single-star backtracking, so it is linear for typical patterns.
@inline(__always)
func globMatch(_ pat: UnsafeBufferPointer<UInt8>, _ s: UnsafeBufferPointer<UInt8>) -> Bool {
    var p = 0, i = 0
    var starP = -1, starI = 0
    let pn = pat.count, sn = s.count
    while i < sn {
        if p < pn {
            let c = pat[p]
            if c == UInt8(ascii: "*") {
                starP = p
                starI = i
                p += 1
                continue
            }
            if c == UInt8(ascii: "?") {
                i += scalarLength(s[i])
                p += 1
                continue
            }
            if c == s[i] {
                p += 1
                i += 1
                continue
            }
        }
        if starP >= 0 {
            p = starP + 1
            starI += scalarLength(s[starI])
            i = starI
            continue
        }
        return false
    }
    while p < pn && pat[p] == UInt8(ascii: "*") { p += 1 }
    return p == pn
}

@inline(__always) private func scalarLength(_ lead: UInt8) -> Int {
    if lead < 0x80 { return 1 }
    if lead >= 0xF0 { return 4 }
    if lead >= 0xE0 { return 3 }
    if lead >= 0xC0 { return 2 }
    return 1
}

/// Everything's wildcard reduction (see docs/analysis/REA-FINDINGS.md §8): patterns whose only
/// wildcards are leading/trailing `*` become plain prefix/suffix/substring matches.
enum ReducedGlob {
    case literal(String, kind: Int32)
    case all
    case glob(String)
}

func reduceGlob(_ pattern: String) -> ReducedGlob {
    if pattern.allSatisfy({ $0 == "*" }) { return .all }
    var body = Substring(pattern)
    var lead = false, trail = false
    while body.first == "*" { body = body.dropFirst(); lead = true }
    while body.last == "*" { body = body.dropLast(); trail = true }
    if body.contains("*") || body.contains("?") { return .glob(pattern) }
    let s = String(body)
    switch (lead, trail) {
    case (true, true): return .literal(s, kind: Int32(0))   // substring
    case (true, false): return .literal(s, kind: Int32(2))  // suffix
    case (false, true): return .literal(s, kind: Int32(1))  // prefix
    case (false, false): return .literal(s, kind: Int32(3)) // exact
    }
}

/// Longest literal that every match of `pattern` must contain, or nil if none can be proven
/// (alternation, inline flags, or no literal run). Conservative: only top-level literal runs,
/// and a character followed by `?`, `*` or `{` is treated as optional.
func requiredLiteral(inRegex pattern: String) -> String? {
    if pattern.contains("|") || pattern.contains("(?") { return nil }
    let chars = Array(pattern)
    var best = "", run = ""
    var depth = 0
    var i = 0
    func flush() {
        if run.count > best.count { best = run }
        run = ""
    }
    while i < chars.count {
        let c = chars[i]
        switch c {
        case "\\":
            guard i + 1 < chars.count else { return nil }
            let n = chars[i + 1]
            if depth == 0, "\\.^$*+?()[]{}/-".contains(n) {
                run.append(n)
            } else {
                flush()
            }
            i += 2
            continue
        case "[":
            flush()
            i += 1
            if i < chars.count, chars[i] == "^" { i += 1 }
            if i < chars.count, chars[i] == "]" { i += 1 }
            while i < chars.count, chars[i] != "]" {
                if chars[i] == "\\" { i += 1 }
                i += 1
            }
        case "(":
            flush(); depth += 1
        case ")":
            flush(); depth = max(0, depth - 1)
        case "?", "*", "{":
            if !run.isEmpty { run.removeLast() }
            flush()
            if c == "{" { while i < chars.count, chars[i] != "}" { i += 1 } }
        case "+":
            flush()
        case ".", "^", "$":
            flush()
        default:
            if depth == 0 { run.append(c) } else { flush() }
        }
        i += 1
    }
    flush()
    return best.isEmpty ? nil : best
}

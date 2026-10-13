// Ported from cardisoft/cardinal (MIT): cardinal-syntax/src/lib.rs and the
// quote stripping in search-cache/src/query_preprocessor.rs.

/// Parses an Everything/Cardinal-style query.
///
/// Precedence: `!`/`NOT` > `|`/`OR` > space/`AND`. Keywords are case-insensitive.
/// The result keeps `.empty` operands where the user left a gap (`foo |`,
/// `AND bar`, `foo ""`); `preprocess` collapses them with Cardinal's semantics
/// (empty inside OR = everything, empty inside AND = ignored).
///
/// Quoting: a token made only of quoted sections becomes `.phrase` (literal);
/// a token mixing quoted and unquoted text (`"My Docs"/*.md`) becomes `.word`
/// with the quotes removed, like Cardinal. `\"` and `\\` are unescaped.
public func parseQuery(_ input: String) throws(ParseError) -> Expr {
    var parser = QueryParser(input)
    return try parser.parse()
}

struct QueryParser {
    private let chars: [Unicode.Scalar]
    private var pos = 0
    private var groupStack: [Unicode.Scalar] = []

    init(_ input: String) {
        chars = Array(input.unicodeScalars)
    }

    mutating func parse() throws(ParseError) -> Expr {
        let expr = try parseAnd()
        skipWhitespace()
        if !isEOF {
            throw error("unexpected trailing characters")
        }
        return expr
    }

    // MARK: Boolean structure

    private mutating func parseAnd() throws(ParseError) -> Expr {
        var parts: [Expr] = []
        var pendingKeywordAnd = false
        while true {
            skipWhitespace()
            if consumeKeyword("AND") {
                if parts.isEmpty { parts.append(.empty) }
                pendingKeywordAnd = true
                continue
            }
            if isEOF || isAtGroupClose {
                if pendingKeywordAnd { parts.append(.empty) }
                break
            }
            // Cardinal stops at an empty operand (`""`) and then reports trailing
            // characters; we keep it as `.empty` so `foo "" bar` stays valid.
            let expr = try parseOr()
            if case .and(let nested) = expr {
                parts.append(contentsOf: nested)
            } else {
                parts.append(expr)
            }
            pendingKeywordAnd = false
        }
        switch parts.count {
        case 0: return .empty
        case 1: return parts[0]
        default: return .and(parts)
        }
    }

    private mutating func parseOr() throws(ParseError) -> Expr {
        var parts: [Expr] = []
        while true {
            skipWhitespace()
            if peek == "|" || isEOF || isAtGroupClose {
                parts.append(.empty)
            } else {
                let expr = try parseNot()
                if case .or(let nested) = expr {
                    parts.append(contentsOf: nested)
                } else {
                    parts.append(expr)
                }
            }
            skipWhitespace()
            if peek == "|" {
                pos += 1
            } else if !consumeKeyword("OR") {
                break
            }
        }
        return parts.count == 1 ? parts[0] : .or(parts)
    }

    private mutating func parseNot() throws(ParseError) -> Expr {
        var negations = 0
        while true {
            skipWhitespace()
            if peek == "!" {
                pos += 1
                negations += 1
            } else if consumeKeyword("NOT") {
                negations += 1
            } else {
                break
            }
        }
        let expr = try parsePrimary()
        return negations % 2 == 1 ? .not(expr) : expr
    }

    private mutating func parsePrimary() throws(ParseError) -> Expr {
        skipWhitespace()
        guard let ch = peek else { return .empty }
        switch ch {
        case "<": return try parseGroup(closing: ">")
        case "(": return try parseGroup(closing: ")")
        case ">", ")": throw error("unexpected closing delimiter")
        default: return try parseWordLike()
        }
    }

    private mutating func parseGroup(closing: Unicode.Scalar) throws(ParseError) -> Expr {
        pos += 1
        groupStack.append(closing)
        let expr = try parseAnd()
        groupStack.removeLast()
        skipWhitespace()
        guard peek == closing else { throw error("expected '\(closing)'") }
        pos += 1
        return expr
    }

    // MARK: Terms

    /// Reads a word, phrase, `name:` filter or `regex:` term.
    private mutating func parseWordLike() throws(ParseError) -> Expr {
        let start = pos
        var seen = false
        var hasQuotedSection = false
        var hasUnquotedText = false
        while let ch = peek {
            if ch == "\\", peekNext == "\"" {
                seen = true
                hasUnquotedText = true
                pos += 2
                continue
            }
            if ch == "\"" {
                try skipQuotedSection()
                seen = true
                hasQuotedSection = true
                continue
            }
            if ch == ":", seen {
                let name = String(String.UnicodeScalarView(chars[start..<pos]))
                if isValidFilterName(name) {
                    pos += 1
                    return .term(try parseFilterTerm(name: name))
                }
            }
            if isTermBreaker(ch) { break }
            seen = true
            hasUnquotedText = true
            pos += 1
        }
        if start == pos { throw error("expected term") }

        let raw = String(String.UnicodeScalarView(chars[start..<pos]))
        let text = stripQuotes(raw)
        if text.isEmpty { return .empty }
        if hasQuotedSection && !hasUnquotedText { return .term(.phrase(text)) }
        return .term(.word(text))
    }

    private mutating func skipQuotedSection() throws(ParseError) {
        let quotePos = pos
        pos += 1
        var escaped = false
        while let ch = peek {
            pos += 1
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return
            }
        }
        throw error("missing closing quote", at: quotePos)
    }

    private mutating func parseFilterTerm(name: String) throws(ParseError) -> Term {
        let lower = name.lowercased()
        if lower == "regex" {
            return .regex(try parseRegexPattern())
        }
        let kind = filterKind(named: lower, original: name)
        return .filter(Filter(kind: kind, argument: try parseFilterArgument(kind: kind)))
    }

    private mutating func parseRegexPattern() throws(ParseError) -> String {
        skipWhitespace()
        if isEOF || isAtGroupClose { throw error("regex: requires a pattern") }
        if peek == "\"" { return try parsePhraseString() }

        var pattern = String.UnicodeScalarView()
        var escaped = false
        var parenDepth = 0
        var bracketDepth = 0
        while let ch = peek {
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "[" {
                bracketDepth += 1
            } else if ch == "]" && bracketDepth > 0 {
                bracketDepth -= 1
            } else if ch == "(" && bracketDepth == 0 {
                parenDepth += 1
            } else if ch == ")" && bracketDepth == 0 {
                if parenDepth > 0 {
                    parenDepth -= 1
                } else if currentCloserIs(ch) {
                    break
                }
            } else if bracketDepth == 0 && (ch.properties.isWhitespace || (currentCloserIs(ch) && parenDepth == 0)) {
                break
            }
            pattern.append(ch)
            pos += 1
        }
        if pattern.isEmpty { throw error("regex: requires a pattern") }
        return String(pattern)
    }

    /// Reads the text right after `name:`; whitespace after the colon means "no argument".
    private mutating func parseFilterArgument(kind: FilterKind) throws(ParseError) -> FilterArgument? {
        guard let first = peek,
              !first.properties.isWhitespace,
              !startsWithFilterToken(),
              !isAtGroupClose,
              first != "|"
        else { return nil }

        let start = pos
        var buffer = String.UnicodeScalarView()
        var quotedSections = 0
        var hasUnquotedText = false
        while let ch = peek {
            if ch == "\"" {
                let quoted = try parsePhraseString()
                buffer.append("\"")
                buffer.append(contentsOf: quoted.unicodeScalars)
                buffer.append("\"")
                quotedSections += 1
                continue
            }
            if ch.properties.isWhitespace || ch == "|" || currentCloserIs(ch) { break }
            if ch == "<" || ch == ">" {
                if !buffer.isEmpty { break }
                buffer.append(ch)
                pos += 1
                hasUnquotedText = true
                continue
            }
            buffer.append(ch)
            pos += 1
            hasUnquotedText = true
        }

        if buffer.isEmpty {
            pos = start
            return nil
        }
        let raw = String(buffer)
        if raw == "\"\"" { return nil }
        let stripped = stripQuotes(raw)
        // Deviation: a fully quoted argument is always a literal phrase, so
        // `content:"a;b"` or `content:"v1..2"` are not split into lists/ranges.
        if quotedSections == 1 && !hasUnquotedText {
            return FilterArgument(raw: stripped, kind: .phrase)
        }
        return FilterArgument(raw: stripped, kind: classifyArgument(kind: kind, raw: raw, quoted: quotedSections > 0 && raw.hasPrefix("\"")))
    }

    /// Reads a `"..."` section and returns its contents with backslashes preserved.
    private mutating func parsePhraseString() throws(ParseError) -> String {
        let quotePos = pos
        pos += 1
        var result = String.UnicodeScalarView()
        var escaped = false
        while let ch = peek {
            pos += 1
            if escaped {
                escaped = false
                result.append(ch)
                continue
            }
            if ch == "\\" {
                escaped = true
                result.append(ch)
                continue
            }
            if ch == "\"" { return String(result) }
            result.append(ch)
        }
        throw error("missing closing quote", at: quotePos)
    }

    // MARK: Cursor helpers

    private var isEOF: Bool { pos >= chars.count }
    private var peek: Unicode.Scalar? { pos < chars.count ? chars[pos] : nil }
    private var peekNext: Unicode.Scalar? { pos + 1 < chars.count ? chars[pos + 1] : nil }

    private mutating func skipWhitespace() {
        while let ch = peek, ch.properties.isWhitespace { pos += 1 }
    }

    private mutating func consumeKeyword(_ keyword: String) -> Bool {
        let scalars = Array(keyword.unicodeScalars)
        guard pos + scalars.count <= chars.count else { return false }
        for (offset, k) in scalars.enumerated() {
            let c = chars[pos + offset]
            let upper = (97...122).contains(c.value) ? c.value - 32 : c.value
            guard upper == k.value else { return false }
        }
        if pos + scalars.count < chars.count, !isKeywordBoundary(chars[pos + scalars.count]) {
            return false
        }
        pos += scalars.count
        return true
    }

    private func currentCloserIs(_ ch: Unicode.Scalar) -> Bool {
        groupStack.last == ch
    }

    private var isAtGroupClose: Bool {
        guard let closer = groupStack.last, let ch = peek else { return false }
        return closer == ch
    }

    /// True when the cursor sits on another `name:` token (`video:size:>1gb`).
    private func startsWithFilterToken() -> Bool {
        var i = pos
        while i < chars.count {
            let ch = chars[i]
            if isTermBreaker(ch) { return false }
            if ch == ":" {
                guard i > pos else { return false }
                return isValidFilterName(String(String.UnicodeScalarView(chars[pos..<i])))
            }
            i += 1
        }
        return false
    }

    private func error(_ message: String, at scalarOffset: Int? = nil) -> ParseError {
        // Positions are UTF-8 byte offsets, as in Cardinal.
        let end = min(scalarOffset ?? pos, chars.count)
        let bytes = chars[0..<end].reduce(0) { $0 + UTF8.width($1) }
        return ParseError(message, at: bytes)
    }
}

// MARK: Lexical helpers

private func isTermBreaker(_ ch: Unicode.Scalar) -> Bool {
    if ch.properties.isWhitespace { return true }
    switch ch {
    case "|", "<", ">", "(", ")", "!": return true
    default: return false
    }
}

private func isKeywordBoundary(_ ch: Unicode.Scalar) -> Bool {
    if ch.properties.isWhitespace { return true }
    switch ch {
    case "|", "<", ">", "(", ")", "!", ":", "\"", "\\", "/", ";", ",", ".",
         "[", "]", "{", "}", "#", "\0":
        return true
    default:
        return false
    }
}

private func isValidFilterName(_ name: String) -> Bool {
    !name.isEmpty && name.unicodeScalars.allSatisfy {
        ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "_" || $0 == "-"
    }
}

/// Maps a lowercased filter keyword to its kind; anything else is `.unsupported(original)`.
func filterKind(named lower: String, original: String) -> FilterKind {
    switch lower {
    case "file": return .file
    case "folder": return .folder
    case "ext": return .ext
    case "type": return .type
    case "audio": return .audio
    case "video": return .video
    case "doc": return .doc
    case "exe": return .exe
    case "size": return .size
    case "dm", "datemodified": return .dateModified
    case "dc", "datecreated": return .dateCreated
    case "parent": return .parent
    case "infolder", "in": return .inFolder
    case "nosubfolders": return .noSubfolders
    case "content": return .content
    case "tag", "t": return .tag
    case "case": return .caseSensitive
    default: return .unsupported(original)
    }
}

/// Removes double quotes and unescapes `\"` / `\\`; other backslashes are kept.
func stripQuotes(_ value: String) -> String {
    guard value.contains("\"") || value.contains("\\") else { return value }
    var result = String.UnicodeScalarView()
    var it = value.unicodeScalars.makeIterator()
    var pending = it.next()
    while let ch = pending {
        pending = it.next()
        if ch == "\\" {
            if let next = pending, next == "\\" || next == "\"" {
                result.append(next)
                pending = it.next()
            } else {
                result.append(ch)
            }
        } else if ch != "\"" {
            result.append(ch)
        }
    }
    return String(result)
}

// MARK: Argument classification

private func classifyArgument(kind: FilterKind, raw: String, quoted: Bool) -> ArgumentKind {
    if let list = parseList(raw) {
        return .list(list.map(stripQuotes))
    }
    if case let (op, value)? = parseComparison(raw) {
        return .comparison(op, stripQuotes(value))
    }
    if case let (lower, upper)? = parseDottedRange(raw) ?? (allowsHyphenRange(kind) ? parseHyphenRange(raw) : nil) {
        return .range(lower: lower.map(stripQuotes), upper: upper.map(stripQuotes))
    }
    return quoted ? .phrase : .bare
}

/// Splits on `;` outside quotes; empty items are dropped (`ext:jpg;` → `["jpg"]`).
private func parseList(_ raw: String) -> [String]? {
    guard raw.contains(";") else { return nil }
    var parts: [String] = []
    var current = String.UnicodeScalarView()
    var inQuotes = false
    var escaped = false
    func flush() {
        let part = String(current).trimmingWhitespace()
        if !part.isEmpty { parts.append(part) }
        current = String.UnicodeScalarView()
    }
    for ch in raw.unicodeScalars {
        if escaped {
            escaped = false
        } else if ch == "\\" {
            escaped = true
        } else if ch == "\"" {
            inQuotes.toggle()
        } else if ch == ";" && !inQuotes {
            flush()
            continue
        }
        current.append(ch)
    }
    flush()
    return parts.isEmpty ? nil : parts
}

private func parseComparison(_ raw: String) -> (ComparisonOp, String)? {
    let operators: [(String, ComparisonOp)] = [
        ("<=", .lte), (">=", .gte), ("!=", .ne), ("<", .lt), (">", .gt), ("=", .eq),
    ]
    for (token, op) in operators where raw.hasPrefix(token) {
        let value = String(raw.dropFirst(token.count)).trimmingWhitespace()
        return value.isEmpty ? nil : (op, value)
    }
    return nil
}

private func parseDottedRange(_ raw: String) -> (String?, String?)? {
    guard let sep = raw.firstRange(of: "..") else { return nil }
    let lower = String(raw[..<sep.lowerBound]).trimmingWhitespace()
    let upper = String(raw[sep.upperBound...]).trimmingWhitespace()
    if lower.isEmpty && upper.isEmpty { return nil }
    let quoted = { (s: String) in s.count >= 2 && s.hasPrefix("\"") && s.hasSuffix("\"") }
    guard hasDigit(lower) || hasDigit(upper) || quoted(lower) || quoted(upper) else { return nil }
    return (lower.isEmpty ? nil : lower, upper.isEmpty ? nil : upper)
}

/// `2014/8/1-2014/8/31`: only accepted when both sides look like dates.
private func parseHyphenRange(_ raw: String) -> (String?, String?)? {
    var index = raw.startIndex
    while let dash = raw[index...].firstIndex(of: "-") {
        let left = String(raw[..<dash]).trimmingWhitespace()
        let right = String(raw[raw.index(after: dash)...]).trimmingWhitespace()
        if !left.isEmpty, !right.isEmpty, looksLikeDateFragment(left), looksLikeDateFragment(right) {
            return (left, right)
        }
        index = raw.index(after: dash)
    }
    return nil
}

private func allowsHyphenRange(_ kind: FilterKind) -> Bool {
    switch kind {
    case .dateModified, .dateCreated: return true
    case .unsupported(let name):
        return ["da", "dateaccessed", "dr", "daterun"].contains(name.lowercased())
    default: return false
    }
}

private func hasDigit(_ s: String) -> Bool {
    s.utf8.contains { $0 >= 0x30 && $0 <= 0x39 }
}

private func looksLikeDateFragment(_ s: String) -> Bool {
    guard hasDigit(s) else { return false }
    return s.contains("/") || s.contains("\\") || s.contains(".") || s.filter { $0 == "-" }.count >= 2
}

extension String {
    func trimmingWhitespace() -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace })
        else { return "" }
        return String(scalars[first...last])
    }
}

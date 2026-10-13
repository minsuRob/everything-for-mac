// Ported from cardisoft/cardinal (MIT): search-cache/src/query_preprocessor.rs
// (home expansion) and optimize_query in cardinal-syntax/src/lib.rs.

/// Normalizes a parsed query for evaluation:
///
/// 1. Expands a leading `~` (`~` or `~/…`) in words and in `parent:`, `in:`
///    and `nosubfolders:` arguments. Phrases and regexes are left alone.
/// 2. Flattens nested AND/OR, drops `.empty` from AND (an all-empty AND is
///    `.empty`), and collapses any OR containing `.empty` to `.empty`
///    ("empty matches everything", so `foo|` shows all results while typing).
/// 3. Stably reorders AND operands by cost: scope filters (`parent:`, `in:`,
///    `nosubfolders:`) first, then words/phrases/regex/sub-expressions, then
///    other filters, and `tag:`/`content:` last.
public func preprocess(_ expr: Expr, homeDirectory: String) -> Expr {
    optimize(expandHome(expr, home: homeDirectory))
}

// MARK: Home expansion

private func expandHome(_ expr: Expr, home: String) -> Expr {
    switch expr {
    case .empty: .empty
    case .term(let term): .term(expandHome(term, home: home))
    case .not(let inner): .not(expandHome(inner, home: home))
    case .and(let parts): .and(parts.map { expandHome($0, home: home) })
    case .or(let parts): .or(parts.map { expandHome($0, home: home) })
    }
}

private func expandHome(_ term: Term, home: String) -> Term {
    switch term {
    case .word(let word):
        return .word(expandHomePrefix(word, home: home))
    case .filter(var filter):
        switch filter.kind {
        case .parent, .inFolder, .noSubfolders:
            guard var argument = filter.argument else { return term }
            argument.raw = expandHomePrefix(argument.raw, home: home)
            switch argument.kind {
            case .bare, .phrase:
                break
            case .list(let values):
                argument.kind = .list(values.map { expandHomePrefix($0, home: home) })
            case .range(let lower, let upper):
                argument.kind = .range(lower: lower.map { expandHomePrefix($0, home: home) },
                                       upper: upper.map { expandHomePrefix($0, home: home) })
            case .comparison(let op, let value):
                argument.kind = .comparison(op, expandHomePrefix(value, home: home))
            }
            filter.argument = argument
            return .filter(filter)
        default:
            return term
        }
    case .phrase, .regex:
        return term
    }
}

/// `~` → home, `~/x` → home + `/x`; `~user` and mid-word tildes are kept.
func expandHomePrefix(_ value: String, home: String) -> String {
    guard value.hasPrefix("~") else { return value }
    let rest = value.dropFirst()
    if rest.isEmpty { return home }
    guard rest.hasPrefix("/") else { return value }
    let base = home.hasSuffix("/") ? String(home.dropLast()) : home
    return base + rest
}

// MARK: Optimizer

private func optimize(_ expr: Expr) -> Expr {
    switch expr {
    case .and(let parts): optimizeAnd(parts)
    case .or(let parts): optimizeOr(parts)
    case .not(let inner): .not(optimize(inner))
    case .term, .empty: expr
    }
}

private func optimizeAnd(_ parts: [Expr]) -> Expr {
    var flattened: [Expr] = []
    for part in parts {
        switch optimize(part) {
        case .empty: continue
        case .and(let nested): flattened.append(contentsOf: nested)
        case let other: flattened.append(other)
        }
    }
    switch flattened.count {
    case 0: return .empty
    case 1: return flattened[0]
    default:
        // Stable: enumerated offset breaks ties.
        let ordered = flattened.enumerated().sorted {
            (evaluationPriority($0.element), $0.offset) < (evaluationPriority($1.element), $1.offset)
        }
        return .and(ordered.map(\.element))
    }
}

private func optimizeOr(_ parts: [Expr]) -> Expr {
    var flattened: [Expr] = []
    for part in parts {
        switch optimize(part) {
        case .empty: return .empty
        case .or(let nested): flattened.append(contentsOf: nested)
        case let other: flattened.append(other)
        }
    }
    return flattened.count == 1 ? flattened[0] : .or(flattened)
}

/// Lower runs first. Cardinal uses 0 for `parent:`/`infolder:` and 3 for `tag:`;
/// we also treat `nosubfolders:` as scope and `content:` (file reads) as last.
private func evaluationPriority(_ expr: Expr) -> Int {
    guard case .term(.filter(let filter)) = expr else { return 1 }
    switch filter.kind {
    case .parent, .inFolder, .noSubfolders: return 0
    case .tag, .content: return 3
    default: return 2
    }
}

/// Query syntax tree. Matches the Everything-style language Cardinal documents
/// (docs/reference/search-syntax.md): words, phrases, wildcards, slash segments,
/// filters, and NOT > OR > AND precedence.
public indirect enum Expr: Equatable, Sendable {
    case empty
    case term(Term)
    case not(Expr)
    case and([Expr])
    case or([Expr])
}

public enum Term: Equatable, Sendable {
    /// Unquoted token. May contain `*`, `?`, `/` and `**` segments; the engine
    /// splits it into path segments (see `PathPattern`).
    case word(String)
    /// Double-quoted text: literal, spaces kept, wildcards not interpreted.
    case phrase(String)
    case regex(String)
    case filter(Filter)
}

public struct Filter: Equatable, Sendable {
    public var kind: FilterKind
    /// nil when the filter has no argument (`file:`), otherwise the raw text after the colon.
    public var argument: FilterArgument?

    public init(kind: FilterKind, argument: FilterArgument?) {
        self.kind = kind
        self.argument = argument
    }
}

public enum FilterKind: Equatable, Sendable {
    case file, folder
    case ext
    case type
    case audio, video, doc, exe
    case size
    case dateModified, dateCreated
    case parent, inFolder, noSubfolders
    case content
    case tag
    case caseSensitive
    /// Recognised Everything keyword the engine does not evaluate (e.g. `da:`, `attrib:`).
    case unsupported(String)
}

public struct FilterArgument: Equatable, Sendable {
    /// Exact text after the colon with surrounding quotes removed.
    public var raw: String
    public var kind: ArgumentKind

    public init(raw: String, kind: ArgumentKind) {
        self.raw = raw
        self.kind = kind
    }
}

public enum ArgumentKind: Equatable, Sendable {
    case bare
    case phrase
    /// `a;b;c`
    case list([String])
    /// `min..max`; either side may be empty (`..10mb`).
    case range(lower: String?, upper: String?)
    case comparison(ComparisonOp, String)
}

public enum ComparisonOp: Equatable, Sendable {
    case lt, lte, gt, gte, eq, ne
}

public struct ParseError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public var position: Int

    public init(_ message: String, at position: Int) {
        self.message = message
        self.position = position
    }

    public var description: String { "\(message) at \(position)" }
}

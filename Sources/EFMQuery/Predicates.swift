// Ported from cardisoft/cardinal (MIT): SizePredicate, DatePredicate,
// lookup_type_group and normalize_extension in search-cache/src/query.rs.

import Foundation

public struct FilterValueError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

// MARK: Size

/// `size:` argument compiled to a closed byte interval, optionally negated (`!=`).
public struct SizePredicate: Sendable, Equatable {
    public let lowerBound: Int64
    public let upperBound: Int64
    public let isNegated: Bool

    public init(lowerBound: Int64, upperBound: Int64, isNegated: Bool = false) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.isNegated = isNegated
    }

    /// Accepts comparisons (`>1gb`), `..` ranges (inclusive, open ends allowed),
    /// keywords (`empty`, `tiny`, … `gigantic`/`giant`) and bare sizes (exact match).
    /// Units are binary (`1kb` = 1024).
    public static func parse(_ arg: FilterArgument) throws -> SizePredicate {
        switch arg.kind {
        case .comparison(let op, let value):
            if sizeKeyword(value) != nil {
                throw FilterValueError("size keywords cannot be used with comparison operators")
            }
            let bytes = try parseSizeLiteral(value)
            let (lo, hi, neg) = comparisonBounds(op, start: bytes, end: bytes)
            return SizePredicate(lowerBound: lo, upperBound: hi, isNegated: neg)
        case .range(let lower, let upper):
            let lo = try lower.map(parseSizeLiteral)
            let hi = try upper.map(parseSizeLiteral)
            if let lo, let hi, lo > hi {
                throw FilterValueError("size range start must be less than or equal to the end")
            }
            return SizePredicate(lowerBound: lo ?? .min, upperBound: hi ?? .max)
        case .list:
            throw FilterValueError("size: lists are not supported")
        case .bare, .phrase:
            let raw = arg.raw.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { throw FilterValueError("size: requires a value") }
            if case let (lo, hi)? = sizeKeyword(raw) {
                return SizePredicate(lowerBound: lo, upperBound: hi)
            }
            let bytes = try parseSizeLiteral(raw)
            return SizePredicate(lowerBound: bytes, upperBound: bytes)
        }
    }

    @inlinable
    public func matches(_ size: Int64) -> Bool {
        (size >= lowerBound && size <= upperBound) != isNegated
    }
}

private let KB: Int64 = 1024
private let MB: Int64 = 1024 * 1024

private func sizeKeyword(_ name: String) -> (Int64, Int64)? {
    switch name.trimmingCharacters(in: .whitespaces).lowercased() {
    case "empty": (0, 0)
    case "tiny": (0, 10 * KB)
    case "small": (10 * KB + 1, 100 * KB)
    case "medium": (100 * KB + 1, MB)
    case "large": (MB + 1, 16 * MB)
    case "huge": (16 * MB + 1, 128 * MB)
    case "gigantic", "giant": (128 * MB + 1, .max)
    default: nil
    }
}

private func parseSizeLiteral(_ raw: String) throws -> Int64 {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { throw FilterValueError("size: expected a number") }
    let numberPart = trimmed.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
    let unitPart = trimmed[numberPart.endIndex...]
    guard !numberPart.isEmpty, let value = Double(numberPart) else {
        throw FilterValueError("size: expected a numeric value in \"\(raw)\"")
    }
    let multiplier: Double = switch unitPart.trimmingCharacters(in: .whitespaces).lowercased() {
    case "", "b", "byte", "bytes": 1
    case "k", "kb", "kib", "kilobyte", "kilobytes": 0x1p10
    case "m", "mb", "mib", "megabyte", "megabytes": 0x1p20
    case "g", "gb", "gib", "gigabyte", "gigabytes": 0x1p30
    case "t", "tb", "tib", "terabyte", "terabytes": 0x1p40
    case "p", "pb", "pib", "petabyte", "petabytes": 0x1p50
    default: throw FilterValueError("Unknown size unit: \"\(unitPart)\"")
    }
    let bytes = (value * multiplier).rounded()
    guard bytes.isFinite, bytes >= 0 else { throw FilterValueError("size: value \"\(raw)\" is out of range") }
    return bytes >= 0x1p63 ? .max : Int64(bytes)
}

/// Bounds for `op value`, where `value` covers `[start, end]` (a single size, or a whole day).
private func comparisonBounds(_ op: ComparisonOp, start: Int64, end: Int64) -> (Int64, Int64, Bool) {
    switch op {
    case .lt: start == .min ? (1, 0, false) : (.min, start - 1, false)
    case .lte: (.min, end, false)
    case .gt: end == .max ? (1, 0, false) : (end + 1, .max, false)
    case .gte: (start, .max, false)
    case .eq: (start, end, false)
    case .ne: (start, end, true)
    }
}

// MARK: Date

/// `dm:`/`dc:` argument compiled to a closed interval of Unix seconds, optionally negated.
///
/// Every date value denotes whole local days: `dm:2024-01-01` is that day,
/// `dm:a..b` runs from the start of `a` to the end of `b`, `<a` is before the
/// start of `a`, `>a` after its end, `<=`/`>=` include it. Weeks start on Monday;
/// `pastweek`/`pastmonth`/`pastyear` cover the last 7/30/365 days plus today.
/// Dates are interpreted in the Gregorian calendar using `calendar.timeZone`.
public struct DatePredicate: Sendable, Equatable {
    public let lowerBound: Int64
    public let upperBound: Int64
    public let isNegated: Bool

    public init(lowerBound: Int64, upperBound: Int64, isNegated: Bool = false) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.isNegated = isNegated
    }

    public static func parse(_ arg: FilterArgument, now: Date, calendar: Calendar) throws -> DatePredicate {
        let context = DateContext(now: now, timeZone: calendar.timeZone)
        switch arg.kind {
        case .range(let lower, let upper):
            let lo = try lower.map { try context.value(of: $0).start }
            let hi = try upper.map { try context.value(of: $0).end }
            if let lo, let hi, lo > hi {
                throw FilterValueError("date range start must not exceed end")
            }
            return DatePredicate(lowerBound: lo ?? .min, upperBound: hi ?? .max)
        case .comparison(let op, let raw):
            let value = try context.value(of: raw)
            let (lo, hi, neg) = comparisonBounds(op, start: value.start, end: value.end)
            return DatePredicate(lowerBound: lo, upperBound: hi, isNegated: neg)
        case .bare, .phrase:
            let value = try context.value(of: arg.raw)
            return DatePredicate(lowerBound: value.start, upperBound: value.end)
        case .list:
            throw FilterValueError("date filters do not accept lists")
        }
    }

    @inlinable
    public func matches(_ unixSeconds: Int64) -> Bool {
        (unixSeconds >= lowerBound && unixSeconds <= upperBound) != isNegated
    }
}

private struct CivilDate {
    var year: Int, month: Int, day: Int
}

private struct DateContext {
    let calendar: Calendar
    let today: CivilDate

    init(now: Date, timeZone: TimeZone) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        calendar = gregorian
        let c = gregorian.dateComponents([.year, .month, .day], from: now)
        today = CivilDate(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Resolves a keyword or absolute date to `[start of first day, end of last day]`.
    func value(of raw: String) throws -> (start: Int64, end: Int64) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw FilterValueError("date filters require a value") }
        if let range = keywordRange(trimmed.lowercased()) ?? absoluteRange(trimmed) {
            return range
        }
        throw FilterValueError("Unrecognized date literal: \(trimmed)")
    }

    private func keywordRange(_ keyword: String) -> (Int64, Int64)? {
        let weekday = calendar.component(.weekday, from: noon(today)!) // 1 = Sunday
        let mondayOffset = (weekday + 5) % 7
        switch keyword {
        case "today":
            return span(today, today)
        case "yesterday":
            let d = shift(today, by: -1)
            return span(d, d)
        case "thisweek":
            let start = shift(today, by: -mondayOffset)
            return span(start, shift(start, by: 6))
        case "lastweek":
            let start = shift(today, by: -mondayOffset - 7)
            return span(start, shift(start, by: 6))
        case "thismonth":
            return monthRange(today.year, today.month)
        case "lastmonth":
            return today.month == 1 ? monthRange(today.year - 1, 12) : monthRange(today.year, today.month - 1)
        case "thisyear":
            return yearRange(today.year)
        case "lastyear":
            return yearRange(today.year - 1)
        case "pastweek":
            return span(shift(today, by: -7), today)
        case "pastmonth":
            return span(shift(today, by: -30), today)
        case "pastyear":
            return span(shift(today, by: -365), today)
        default:
            return nil
        }
    }

    /// `YYYY-MM-DD`, `DD-MM-YYYY`, `MM-DD-YYYY` (also with `/` or `.`), tried in
    /// Cardinal's order; plus `YYYY` (whole year) and `YYYY-MM` (whole month).
    private func absoluteRange(_ raw: String) -> (Int64, Int64)? {
        let isDigits = { (s: Substring) in !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }
        if raw.count == 4, isDigits(Substring(raw)) {
            return yearRange(Int(raw)!)
        }
        guard let sep = raw.first(where: { $0 == "-" || $0 == "/" || $0 == "." }) else { return nil }
        let parts = raw.split(separator: sep, omittingEmptySubsequences: false)
        guard parts.allSatisfy(isDigits) else { return nil }

        if parts.count == 2, parts[0].count == 4, parts[1].count <= 2 {
            return monthRange(Int(parts[0])!, Int(parts[1])!)
        }
        guard parts.count == 3 else { return nil }

        // Field order as indices of (year, month, day) within `parts`.
        typealias Order = (y: Int, m: Int, d: Int)
        var orders: [Order] = switch sep {
        case "-": [(0, 1, 2), (2, 1, 0), (2, 0, 1)]   // %Y-%m-%d, %d-%m-%Y, %m-%d-%Y
        case "/": [(0, 1, 2), (2, 0, 1), (2, 1, 0)]   // %Y/%m/%d, %m/%d/%Y, %d/%m/%Y
        default: [(0, 1, 2), (2, 1, 0), (2, 0, 1)]    // %Y.%m.%d, %d.%m.%Y, %m.%d.%Y
        }
        let startsWithYear = parts[0].count == 4
        if !startsWithYear {
            orders = orders.filter { $0.y != 0 } + orders.filter { $0.y == 0 }
        }
        for order in orders {
            guard parts[order.y].count == 4, parts[order.m].count <= 2, parts[order.d].count <= 2 else { continue }
            let date = CivilDate(year: Int(parts[order.y])!, month: Int(parts[order.m])!, day: Int(parts[order.d])!)
            if isValid(date) { return span(date, date) }
        }
        return nil
    }

    private func isValid(_ date: CivilDate) -> Bool {
        guard (1...9999).contains(date.year), (1...12).contains(date.month), date.day >= 1,
              let first = noon(CivilDate(year: date.year, month: date.month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first)
        else { return false }
        return days.contains(date.day)
    }

    private func monthRange(_ year: Int, _ month: Int) -> (Int64, Int64)? {
        guard isValid(CivilDate(year: year, month: month, day: 1)),
              let first = noon(CivilDate(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first)
        else { return nil }
        return span(CivilDate(year: year, month: month, day: 1), CivilDate(year: year, month: month, day: days.upperBound - 1))
    }

    private func yearRange(_ year: Int) -> (Int64, Int64)? {
        guard (1...9999).contains(year) else { return nil }
        return span(CivilDate(year: year, month: 1, day: 1), CivilDate(year: year, month: 12, day: 31))
    }

    /// From the first second of `first` to the last second of `last`.
    private func span(_ first: CivilDate, _ last: CivilDate) -> (Int64, Int64)? {
        guard let a = noon(first), let b = noon(last),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: b)
        else { return nil }
        let start = calendar.startOfDay(for: a).timeIntervalSince1970
        let end = calendar.startOfDay(for: nextDay).timeIntervalSince1970
        return (Int64(start.rounded(.down)), Int64(end.rounded(.down)) - 1)
    }

    /// Noon avoids DST transitions at midnight when moving between days.
    private func noon(_ date: CivilDate) -> Date? {
        calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: 12))
    }

    private func shift(_ date: CivilDate, by days: Int) -> CivilDate {
        guard let base = noon(date), let shifted = calendar.date(byAdding: .day, value: days, to: base) else { return date }
        let c = calendar.dateComponents([.year, .month, .day], from: shifted)
        return CivilDate(year: c.year!, month: c.month!, day: c.day!)
    }
}

// MARK: Types and extensions

/// What a `type:` category selects.
public enum TypeFilterTarget: Sendable, Equatable {
    case files
    case folders
    case extensions(Set<String>)
}

public enum TypeGroups {
    public static let pictures: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "webp", "ico", "svg", "heic", "heif", "raw",
        "arw", "cr2", "orf", "raf", "psd", "ai",
    ]
    public static let videos: Set<String> = [
        "mp4", "m4v", "mov", "avi", "mkv", "wmv", "webm", "flv", "mpg", "mpeg", "3gp", "3g2", "ts",
        "mts", "m2ts",
    ]
    public static let audio: Set<String> = [
        "mp3", "wav", "flac", "aac", "ogg", "oga", "opus", "wma", "m4a", "alac", "aiff",
    ]
    public static let documents: Set<String> = [
        "txt", "md", "rst", "doc", "docx", "rtf", "odt", "pdf", "pages", "rtfd",
    ]
    public static let presentations: Set<String> = ["ppt", "pptx", "key", "odp"]
    public static let spreadsheets: Set<String> = ["xls", "xlsx", "csv", "numbers", "ods"]
    public static let pdf: Set<String> = ["pdf"]
    public static let archives: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "cab", "iso", "dmg",
    ]
    public static let code: Set<String> = [
        "rs", "ts", "tsx", "js", "jsx", "c", "cc", "cpp", "cxx", "h", "hpp", "hh", "java", "cs", "py",
        "go", "rb", "swift", "kt", "kts", "php", "html", "css", "scss", "sass", "less", "json", "yaml",
        "yml", "toml", "ini", "cfg", "sh", "zsh", "fish", "ps1", "psm1", "sql", "lua", "pl", "pm", "r",
        "m", "mm", "dart", "scala", "ex", "exs",
    ]
    public static let executables: Set<String> = [
        "exe", "msi", "bat", "cmd", "com", "ps1", "psm1", "app", "apk", "ipa", "jar", "bin", "run",
        "pkg",
    ]

    /// Extension set (lowercase, no dot) for a `type:` category or synonym, or nil
    /// if unknown. `file`/`folder` categories have no extension set; see `target(forTypeName:)`.
    public static func extensions(forTypeName name: String) -> Set<String>? {
        if case .extensions(let set) = target(forTypeName: name) { return set }
        return nil
    }

    /// Full `type:` lookup including `type:file(s)` and `type:folder(s)`/`dir`/`directory`.
    public static func target(forTypeName name: String) -> TypeFilterTarget? {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "file", "files": .files
        case "folder", "folders", "dir", "directory": .folders
        case "picture", "pictures", "image", "images", "photo", "photos": .extensions(pictures)
        case "video", "videos", "movie", "movies": .extensions(videos)
        case "audio", "audios", "music", "song", "songs": .extensions(audio)
        case "doc", "docs", "document", "documents", "text", "office": .extensions(documents)
        case "presentation", "presentations", "ppt", "slides": .extensions(presentations)
        case "spreadsheet", "spreadsheets", "xls", "excel", "sheet", "sheets": .extensions(spreadsheets)
        case "pdf": .extensions(pdf)
        case "archive", "archives", "compressed", "zip": .extensions(archives)
        case "code", "source", "dev": .extensions(code)
        case "exe", "exec", "executable", "executables", "program", "programs", "app", "apps": .extensions(executables)
        default: nil
        }
    }

    /// Extension set for the `audio:`, `video:`, `doc:` and `exe:` macros.
    public static func extensions(forMacro kind: FilterKind) -> Set<String>? {
        switch kind {
        case .audio: audio
        case .video: videos
        case .doc: documents
        case .exe: executables
        default: nil
        }
    }
}

/// `ext:jpg;.PNG` → `["jpg", "png"]`: trimmed, leading dots removed, lowercased, empties dropped.
public func normalizedExtensions(_ arg: FilterArgument) -> Set<String> {
    let values: [String] = if case .list(let items) = arg.kind { items } else { [arg.raw] }
    var result = Set<String>()
    for value in values {
        let ext = value.trimmingCharacters(in: .whitespaces).drop { $0 == "." }.lowercased()
        if !ext.isEmpty { result.insert(ext) }
    }
    return result
}

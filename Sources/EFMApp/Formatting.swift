import AppKit
import Foundation

/// Shared, reused formatters (creating formatters per row is expensive).
enum Formatting {
    static let count: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = false
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    static func number(_ n: Int) -> String {
        count.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func size(_ n: Int64) -> String {
        bytes.string(fromByteCount: n)
    }

    static func unixDate(_ seconds: Int64) -> String {
        guard seconds > 0 else { return "—" }
        return date.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    static func milliseconds(_ seconds: TimeInterval) -> String {
        let ms = seconds * 1000
        if ms < 10 { return String(format: "%.1f ms", ms) }
        return "\(number(Int(ms.rounded()))) ms"
    }

    /// Name with every occurrence of `terms` emphasised (case-insensitive, overlapping
    /// ranges merged).
    private static let truncatingTail: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    static func highlighted(_ name: String, terms: [String], font: NSFont, boldFont: NSFont,
                            color: NSColor, accent: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString(string: name, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: truncatingTail])
        guard !terms.isEmpty, !name.isEmpty else { return out }
        let ns = name as NSString
        for term in terms where !term.isEmpty {
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let r = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                if r.location == NSNotFound || r.length == 0 { break }
                out.addAttributes([.font: boldFont, .foregroundColor: accent], range: r)
                let next = r.location + r.length
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        return out
    }
}

import Foundation
import Testing
@testable import EFMQuery

private func arg(_ filterText: String) throws -> FilterArgument {
    guard case .term(.filter(let f)) = try parseQuery(filterText), let a = f.argument else {
        throw FilterValueError("no argument in \(filterText)")
    }
    return a
}

private func size(_ text: String) throws -> SizePredicate {
    try SizePredicate.parse(arg("size:" + text))
}

@Suite struct SizePredicateTests {
    @Test func comparisons() throws {
        let gt = try size(">1GB")
        #expect(!gt.matches(1 << 30))
        #expect(gt.matches((1 << 30) + 1))
        #expect(try size(">=1gb").matches(1 << 30))
        #expect(try size("<10mb").matches(10 * 1_048_576 - 1))
        #expect(!(try size("<10mb").matches(10 * 1_048_576)))
        #expect(try size("<=10mb").matches(10 * 1_048_576))
        #expect(try size("=1k").matches(1024))
        #expect(!(try size("=1k").matches(1025)))
        #expect(try size("!=1k").matches(1025))
        #expect(!(try size("!=1k").matches(1024)))
        #expect(!(try size("<0").matches(0)))
    }

    @Test func rangesAreInclusive() throws {
        let p = try size("1mb..10mb")
        #expect(!p.matches(1_048_575))
        #expect(p.matches(1_048_576))
        #expect(p.matches(10_485_760))
        #expect(!p.matches(10_485_761))
        #expect(try size("..10mb").matches(0))
        #expect(try size("1mb..").matches(Int64.max))
    }

    @Test func keywords() throws {
        #expect(try size("empty").matches(0))
        #expect(!(try size("empty").matches(1)))
        #expect(try size("tiny").matches(10 * 1024))
        #expect(!(try size("tiny").matches(10 * 1024 + 1)))
        #expect(try size("small").matches(10 * 1024 + 1))
        #expect(try size("small").matches(100 * 1024))
        #expect(try size("Medium").matches(1_048_576))
        #expect(try size("large").matches(16 * 1_048_576))
        #expect(try size("huge").matches(128 * 1_048_576))
        #expect(!(try size("huge").matches(128 * 1_048_576 + 1)))
        #expect(try size("gigantic").matches(128 * 1_048_576 + 1))
        #expect(try size("giant") == size("gigantic"))
    }

    @Test func units() throws {
        #expect(try size("1.5kb") == SizePredicate(lowerBound: 1536, upperBound: 1536))
        #expect(try size("2KiB").lowerBound == 2048)
        #expect(try size("3kilobytes").lowerBound == 3072)
        #expect(try size("1m").lowerBound == 1 << 20)
        #expect(try size("1megabyte").lowerBound == 1 << 20)
        #expect(try size("1gib").lowerBound == 1 << 30)
        #expect(try size("1tb").lowerBound == 1 << 40)
        #expect(try size("1petabytes").lowerBound == 1 << 50)
        #expect(try size("100").lowerBound == 100)
        #expect(try size("7b").lowerBound == 7)
        #expect(try size("99999999999p").lowerBound == Int64.max)
    }

    @Test func errors() {
        for bad in [">tiny", "abc", "10xb", "jpg;png", "10mb..1mb", "kb"] {
            #expect(throws: FilterValueError.self, "\(bad)") { try size(bad) }
        }
    }
}

@Suite struct DatePredicateTests {
    let tz = TimeZone(identifier: "America/New_York")!
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    /// Wednesday 2026-10-14 15:30 New York.
    var now: Date { at(2026, 10, 14, 15, 30) }

    func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
    }

    func ts(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Int64 {
        Int64(at(y, m, d, h, mi, s).timeIntervalSince1970)
    }

    /// Interval from the start of day `a` to the end of day `b`.
    func days(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> DatePredicate {
        DatePredicate(lowerBound: ts(a.0, a.1, a.2), upperBound: ts(b.0, b.1, b.2 + 1) - 1)
    }

    func date(_ text: String, now: Date? = nil, calendar: Calendar? = nil) throws -> DatePredicate {
        try DatePredicate.parse(arg("dm:" + text), now: now ?? self.now, calendar: calendar ?? self.calendar)
    }

    @Test func relativeKeywords() throws {
        #expect(try date("today") == days((2026, 10, 14), (2026, 10, 14)))
        #expect(try date("TODAY") == days((2026, 10, 14), (2026, 10, 14)))
        #expect(try date("yesterday") == days((2026, 10, 13), (2026, 10, 13)))
        #expect(try date("thisweek") == days((2026, 10, 12), (2026, 10, 18)))
        #expect(try date("lastweek") == days((2026, 10, 5), (2026, 10, 11)))
        #expect(try date("thismonth") == days((2026, 10, 1), (2026, 10, 31)))
        #expect(try date("lastmonth") == days((2026, 9, 1), (2026, 9, 30)))
        #expect(try date("thisyear") == days((2026, 1, 1), (2026, 12, 31)))
        #expect(try date("lastyear") == days((2025, 1, 1), (2025, 12, 31)))
        #expect(try date("pastweek") == days((2026, 10, 7), (2026, 10, 14)))
        #expect(try date("pastmonth") == days((2026, 9, 14), (2026, 10, 14)))
        #expect(try date("pastyear") == days((2025, 10, 14), (2026, 10, 14)))
    }

    @Test func weekStartsOnMondayEvenOnSunday() throws {
        #expect(try date("thisweek", now: at(2026, 10, 18, 23)) == days((2026, 10, 12), (2026, 10, 18)))
        #expect(try date("thisweek", now: at(2026, 10, 12, 0, 0, 1)) == days((2026, 10, 12), (2026, 10, 18)))
    }

    @Test func lastMonthInJanuary() throws {
        #expect(try date("lastmonth", now: at(2026, 1, 10)) == days((2025, 12, 1), (2025, 12, 31)))
    }

    @Test func absoluteFormats() throws {
        let jan15 = days((2024, 1, 15), (2024, 1, 15))
        for text in ["2024-01-15", "2024/01/15", "2024.01.15", "15-01-2024", "01/15/2024", "15/01/2024", "15.01.2024", "2024/1/15"] {
            #expect(try date(text) == jan15, "\(text)")
        }
        // Month-first wins for `/` when ambiguous; day-first for `-`.
        #expect(try date("02/03/2024") == days((2024, 2, 3), (2024, 2, 3)))
        #expect(try date("02-03-2024") == days((2024, 3, 2), (2024, 3, 2)))
    }

    @Test func yearAndMonthShorthands() throws {
        #expect(try date("2024") == days((2024, 1, 1), (2024, 12, 31)))
        #expect(try date("2024-02") == days((2024, 2, 1), (2024, 2, 29)))
        #expect(try date("2023/02") == days((2023, 2, 1), (2023, 2, 28)))
    }

    @Test func rangesCoverWholeDays() throws {
        let p = try date("2024-01-01..2024-12-31")
        #expect(p == days((2024, 1, 1), (2024, 12, 31)))
        #expect(p.matches(ts(2024, 12, 31, 23, 59, 59)))
        #expect(!p.matches(ts(2025, 1, 1)))
        #expect(!p.matches(ts(2023, 12, 31, 23, 59, 59)))
        #expect(try date("..2024-01-01") == DatePredicate(lowerBound: .min, upperBound: ts(2024, 1, 2) - 1))
        #expect(try date("2024-01-01..") == DatePredicate(lowerBound: ts(2024, 1, 1), upperBound: .max))
        #expect(try date("2014/8/1-2014/8/31") == days((2014, 8, 1), (2014, 8, 31)))
        #expect(try date("2023..2024") == days((2023, 1, 1), (2024, 12, 31)))
    }

    @Test func comparisons() throws {
        let start = ts(2024, 1, 1), end = ts(2024, 1, 2) - 1
        #expect(try date("<2024-01-01") == DatePredicate(lowerBound: .min, upperBound: start - 1))
        #expect(try date("<=2024-01-01") == DatePredicate(lowerBound: .min, upperBound: end))
        #expect(try date(">2024-01-01") == DatePredicate(lowerBound: end + 1, upperBound: .max))
        #expect(try date(">=2024/01/01") == DatePredicate(lowerBound: start, upperBound: .max))
        #expect(try date("=2024-01-01") == DatePredicate(lowerBound: start, upperBound: end))
        let ne = try date("!=2024-01-01")
        #expect(ne.matches(start - 1) && ne.matches(end + 1))
        #expect(!ne.matches(start) && !ne.matches(end))
        #expect(try date(">=today").matches(ts(2026, 10, 14, 0, 0, 0)))
    }

    @Test func dstDayIsShort() throws {
        let p = try date("2026-03-08")
        #expect(p.upperBound - p.lowerBound + 1 == 23 * 3600)
    }

    @Test func usesCalendarTimeZone() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(try date("2024-01-01", calendar: utc) == DatePredicate(lowerBound: 1_704_067_200, upperBound: 1_704_153_599))
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(try date("2024-01-01", calendar: tokyo).lowerBound == 1_704_067_200 - 9 * 3600)
    }

    @Test func nonGregorianCalendarStillReadsGregorianDates() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "UTC")!
        #expect(try date("2024-01-01", calendar: buddhist).lowerBound == 1_704_067_200)
    }

    @Test func errors() {
        for bad in ["2024-02-30", "2024-13-01", "someday", "2024-01-01;2024-02-01", "2024-12-31..2024-01-01", "24-01-01", "2024-1-1-1"] {
            #expect(throws: FilterValueError.self, "\(bad)") { try date(bad) }
        }
    }
}

@Suite struct TypeGroupTests {
    @Test func synonyms() {
        for name in ["picture", "pictures", "image", "images", "photo", "Photos"] {
            #expect(TypeGroups.extensions(forTypeName: name)?.contains("jpg") == true, "\(name)")
        }
        #expect(TypeGroups.extensions(forTypeName: "movies") == TypeGroups.videos)
        #expect(TypeGroups.extensions(forTypeName: "song") == TypeGroups.audio)
        #expect(TypeGroups.extensions(forTypeName: "office")?.contains("docx") == true)
        #expect(TypeGroups.extensions(forTypeName: "slides")?.contains("key") == true)
        #expect(TypeGroups.extensions(forTypeName: "excel")?.contains("numbers") == true)
        #expect(TypeGroups.extensions(forTypeName: "pdf") == ["pdf"])
        #expect(TypeGroups.extensions(forTypeName: "zip")?.contains("dmg") == true)
        #expect(TypeGroups.extensions(forTypeName: "dev")?.contains("swift") == true)
        #expect(TypeGroups.extensions(forTypeName: "apps")?.contains("app") == true)
        #expect(TypeGroups.extensions(forTypeName: "nonsense") == nil)
    }

    @Test func fileAndFolderCategories() {
        #expect(TypeGroups.extensions(forTypeName: "file") == nil)
        #expect(TypeGroups.target(forTypeName: "files") == .files)
        #expect(TypeGroups.target(forTypeName: "directory") == .folders)
    }

    @Test func macros() {
        #expect(TypeGroups.extensions(forMacro: .audio) == TypeGroups.extensions(forTypeName: "audio"))
        #expect(TypeGroups.extensions(forMacro: .video) == TypeGroups.extensions(forTypeName: "video"))
        #expect(TypeGroups.extensions(forMacro: .doc) == TypeGroups.extensions(forTypeName: "doc"))
        #expect(TypeGroups.extensions(forMacro: .exe) == TypeGroups.extensions(forTypeName: "exe"))
        #expect(TypeGroups.extensions(forMacro: .size) == nil)
    }

    @Test func normalizedExtensionLists() throws {
        #expect(normalizedExtensions(try arg("ext:jpg;.PNG")) == ["jpg", "png"])
        #expect(normalizedExtensions(try arg("ext:.Md")) == ["md"])
        #expect(normalizedExtensions(try arg("ext:tar.gz")) == ["tar.gz"])
        #expect(normalizedExtensions(try arg("ext:;.;rs")) == ["rs"])
        #expect(normalizedExtensions(try arg("ext:\"JPG\"")) == ["jpg"])
    }
}

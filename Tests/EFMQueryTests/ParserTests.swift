// Cases ported from cardisoft/cardinal (MIT): cardinal-syntax/tests and lib.rs unit tests.

import Testing
@testable import EFMQuery

func word(_ s: String) -> Expr { .term(.word(s)) }
func phrase(_ s: String) -> Expr { .term(.phrase(s)) }
func filter(_ kind: FilterKind, _ arg: FilterArgument? = nil) -> Expr { .term(.filter(Filter(kind: kind, argument: arg))) }
func bare(_ s: String) -> FilterArgument { FilterArgument(raw: s, kind: .bare) }

func parse(_ s: String) throws -> Expr { try parseQuery(s) }

func parseError(_ s: String) -> ParseError? {
    do {
        _ = try parseQuery(s)
        return nil
    } catch {
        return error
    }
}

func filterArgument(_ e: Expr) -> FilterArgument? {
    guard case .term(.filter(let f)) = e else { return nil }
    return f.argument
}

@Suite struct BooleanTests {
    @Test func emptyInput() throws {
        #expect(try parse("") == .empty)
        #expect(try parse("   ") == .empty)
    }

    @Test func implicitAnd() throws {
        #expect(try parse("foo bar baz") == .and([word("foo"), word("bar"), word("baz")]))
    }

    @Test func orBindsTighterThanAnd() throws {
        #expect(try parse("a b|c d") == .and([word("a"), .or([word("b"), word("c")]), word("d")]))
        #expect(try parse("foo bar|\"baz qux\" !temp") ==
            .and([word("foo"), .or([word("bar"), phrase("baz qux")]), .not(word("temp"))]))
    }

    @Test func notBindsTightest() throws {
        #expect(try parse("!foo | bar baz") == .and([.or([.not(word("foo")), word("bar")]), word("baz")]))
    }

    @Test func notChainsCollapseByParity() throws {
        #expect(try parse("!x") == .not(word("x")))
        #expect(try parse("!!x") == word("x"))
        #expect(try parse("!!!x") == .not(word("x")))
        #expect(try parse("NOT !x") == word("x"))
        #expect(try parse("!!ext:rs") == filter(.ext, bare("rs")))
    }

    @Test func textualKeywords() throws {
        #expect(try parse("foo AND bar") == .and([word("foo"), word("bar")]))
        #expect(try parse("foo OR bar") == .or([word("foo"), word("bar")]))
        #expect(try parse("foo or bar") == .or([word("foo"), word("bar")]))
        #expect(try parse("NOT temp") == .not(word("temp")))
        #expect(try parse("NOT/Users") == .not(word("/Users")))
        #expect(try parse("Notes ORACLE android") == .and([word("Notes"), word("ORACLE"), word("android")]))
    }

    @Test func emptyOperandsArePreserved() throws {
        #expect(try parse("  AND foo") == .and([.empty, word("foo")]))
        #expect(try parse("foo AND ") == .and([word("foo"), .empty]))
        #expect(try parse(" AND ") == .and([.empty, .empty]))
        #expect(try parse("kksk | ") == .or([word("kksk"), .empty]))
        #expect(try parse(" | ") == .or([.empty, .empty]))
        #expect(try parse("| foo") == .or([.empty, word("foo")]))
        #expect(try parse("foo||bar") == .or([word("foo"), .empty, word("bar")]))
        #expect(try parse("| foo |") == .or([.empty, word("foo"), .empty]))
        #expect(try parse("a|\"\"") == .or([word("a"), .empty]))
    }

    @Test func emptyPhraseMidQueryIsAccepted() throws {
        // Cardinal rejects this with "unexpected trailing characters".
        #expect(try parse("foo \"\" bar") == .and([word("foo"), .empty, word("bar")]))
    }

    @Test func unixPaths() throws {
        #expect(try parse("/Users/demo/Documents report") == .and([word("/Users/demo/Documents"), word("report")]))
        #expect(try parse("/Volumes/Data OR /Users") == .or([word("/Volumes/Data"), word("/Users")]))
    }
}

@Suite struct GroupTests {
    @Test func angleBracketGroup() throws {
        #expect(try parse("<D: | E:> *.mp3") ==
            .and([.or([filter(.unsupported("D")), filter(.unsupported("E"))]), word("*.mp3")]))
    }

    @Test func parenthesesFlattenIntoAnd() throws {
        #expect(try parse("(foo bar) baz") == .and([word("foo"), word("bar"), word("baz")]))
    }

    @Test func nestedGroups() throws {
        #expect(try parse("(foo <bar|baz>) qux") == .and([word("foo"), .or([word("bar"), word("baz")]), word("qux")]))
        #expect(try parse("good (<src|tests> ext:rs)") ==
            .and([word("good"), .or([word("src"), word("tests")]), filter(.ext, bare("rs"))]))
        #expect(try parse("(a|b)|c") == .or([word("a"), word("b"), word("c")]))
    }

    @Test func notOfGroup() throws {
        #expect(try parse("!(ext:zip report)") == .not(.and([filter(.ext, bare("zip")), word("report")])))
    }

    @Test func emptyGroup() throws {
        #expect(try parse("()") == .empty)
    }

    @Test func unmatchedDelimiters() {
        #expect(parseError("<foo bar")?.message.contains("expected '>'") == true)
        #expect(parseError("(foo")?.message.contains("expected ')'") == true)
        #expect(parseError(")foo")?.message.contains("unexpected closing") == true)
        #expect(parseError("foo)")?.message.contains("unexpected closing") == true)
        #expect((parseError("<a b")?.position ?? 0) > 0)
    }
}

@Suite struct PhraseAndWordTests {
    @Test func wordsAndWildcards() throws {
        #expect(try parse("report") == word("report"))
        #expect(try parse("*.mp3") == word("*.mp3"))
        #expect(try parse("report-??.txt") == word("report-??.txt"))
        #expect(try parse("报告") == word("报告"))
        #expect(try parse(":") == word(":"))
    }

    @Test func quotedPhrases() throws {
        #expect(try parse("\"summer holiday\"") == phrase("summer holiday"))
        #expect(try parse("\" \"") == phrase(" "))
        #expect(try parse("\"*.rs\"") == phrase("*.rs"))
        #expect(try parse("foo \"bar baz\" qux") == .and([word("foo"), phrase("bar baz"), word("qux")]))
        #expect(try parse("\"hello\"\"world\"") == phrase("helloworld"))
        #expect(try parse("\"line1\nline2\"") == phrase("line1\nline2"))
        #expect(try parse("!\"exclude\"") == .not(phrase("exclude")))
    }

    @Test func emptyQuotes() throws {
        #expect(try parse("\"\"") == .empty)
        #expect(try parse("\"\"\"\"") == .empty)
        #expect(try parse("a\"\"b") == word("ab"))
    }

    @Test func mixedQuotedTokensBecomeWords() throws {
        #expect(try parse("\"Trae CN\"/emm.db") == word("Trae CN/emm.db"))
        #expect(try parse("a\"b~\"c") == word("ab~c"))
        #expect(try parse("a\"b\"c\"d\"e") == word("abcde"))
        #expect(try parse("\"prefix\"suffix") == word("prefixsuffix"))
        #expect(try parse("prefix\"suffix\"") == word("prefixsuffix"))
    }

    @Test func escapes() throws {
        #expect(try parse("\\\"") == word("\""))
        #expect(try parse("word\\\"part") == word("word\"part"))
        #expect(try parse("\"a \\\"b\\\" c\"") == phrase("a \"b\" c"))
        #expect(try parse("\"a \\ b c\"") == phrase("a \\ b c"))
        #expect(try parse("\"C:\\\\Users\"") == phrase("C:\\Users"))
        #expect(try parse("\"trailing\\\\\"") == phrase("trailing\\"))
        #expect(try parse("a\"b\\\"c\"d") == word("ab\"cd"))
        #expect(try parse("\"你好\\\"世界\"") == phrase("你好\"世界"))
        #expect(try parse("foo\\\"bar \"baz\\\"qux\" xyz") == .and([word("foo\"bar"), phrase("baz\"qux"), word("xyz")]))
    }

    @Test func unclosedQuotes() {
        for input in ["\"unterminated", "foo \"unclosed bar", "ext:\"txt", "foo OR \"bar", "(\"foo bar)",
                      "\"你好", "\"test\\\"", "\"value\\", "content:\"test\\\"value", "ext:\"jpg\";\"png\\\""] {
            #expect(parseError(input)?.message.contains("missing closing quote") == true, "\(input)")
        }
        #expect(parseError("foo \"bar")?.position == 4)
    }
}

@Suite struct FilterTests {
    @Test func keywordsAndAliases() throws {
        let cases: [(String, FilterKind)] = [
            ("file:", .file), ("folder:", .folder), ("ext:", .ext), ("type:", .type),
            ("audio:", .audio), ("video:", .video), ("doc:", .doc), ("exe:", .exe), ("size:", .size),
            ("dm:", .dateModified), ("datemodified:", .dateModified), ("DM:", .dateModified),
            ("dc:", .dateCreated), ("datecreated:", .dateCreated), ("parent:", .parent),
            ("infolder:", .inFolder), ("in:", .inFolder), ("nosubfolders:", .noSubfolders),
            ("content:", .content), ("tag:", .tag), ("t:", .tag), ("case:", .caseSensitive),
            ("da:", .unsupported("da")), ("dupe:", .unsupported("dupe")), ("attrib:", .unsupported("attrib")),
            ("proj:", .unsupported("proj")),
        ]
        for (input, kind) in cases {
            #expect(try parse(input) == filter(kind), "\(input)")
        }
    }

    @Test func bareArguments() throws {
        #expect(try parse("folder:Projects") == filter(.folder, bare("Projects")))
        #expect(try parse("content:error") == filter(.content, bare("error")))
        #expect(try parse("in:/Users/demo") == filter(.inFolder, bare("/Users/demo")))
        #expect(try parse("child:*.mp3") == filter(.unsupported("child"), bare("*.mp3")))
        #expect(try parse("dm:pastyear") == filter(.dateModified, bare("pastyear")))
    }

    @Test func whitespaceEndsFilter() throws {
        #expect(try parse("file: *.md dm:pastyear") ==
            .and([filter(.file), word("*.md"), filter(.dateModified, bare("pastyear"))]))
        #expect(try parse("file: 报告") == .and([filter(.file), word("报告")]))
    }

    @Test func adjacentFilterIsNotArgument() throws {
        #expect(try parse("video:size:>1gb") ==
            .and([filter(.video), filter(.size, FilterArgument(raw: ">1gb", kind: .comparison(.gt, "1gb")))]))
    }

    @Test func filterArgumentStopsAtOperators() throws {
        #expect(try parse("ext:jpg|ext:png") == .or([filter(.ext, bare("jpg")), filter(.ext, bare("png"))]))
        #expect(try parse("(ext:jpg)") == filter(.ext, bare("jpg")))
        #expect(try parse("<ext:jpg>") == filter(.ext, bare("jpg")))
        #expect(try parse("<size:<10>") == filter(.size, FilterArgument(raw: "<10", kind: .comparison(.lt, "10"))))
    }

    @Test func lists() throws {
        #expect(filterArgument(try parse("ext:jpg;png;jpeg"))?.kind == .list(["jpg", "png", "jpeg"]))
        #expect(filterArgument(try parse("ext:jpg;"))?.kind == .list(["jpg"]))
        #expect(filterArgument(try parse("tag:Orange;"))?.kind == .list(["Orange"]))
        #expect(filterArgument(try parse("ext:\"jpg\";\"png\""))?.kind == .list(["jpg", "png"]))
        #expect(filterArgument(try parse("tag:\"Red;Orange\";Blue")) ==
            FilterArgument(raw: "Red;Orange;Blue", kind: .list(["Red;Orange", "Blue"])))
        #expect(filterArgument(try parse("ext:\"a\\\"b\";\"c\\\"d\""))?.kind == .list(["a\"b", "c\"d"]))
    }

    @Test func phrases() throws {
        #expect(filterArgument(try parse("parent:\"/Users/demo\"")) == FilterArgument(raw: "/Users/demo", kind: .phrase))
        #expect(filterArgument(try parse("folder:\"My Documents\"")) == FilterArgument(raw: "My Documents", kind: .phrase))
        #expect(filterArgument(try parse("content:\"foo\\\"bar\"")) == FilterArgument(raw: "foo\"bar", kind: .phrase))
        #expect(filterArgument(try parse("content:\"a;b\"")) == FilterArgument(raw: "a;b", kind: .phrase))
        #expect(filterArgument(try parse("content:\"v1..2\"")) == FilterArgument(raw: "v1..2", kind: .phrase))
        #expect(filterArgument(try parse("folder:\"part1\"\"part2\"")) == FilterArgument(raw: "part1part2", kind: .phrase))
        #expect(filterArgument(try parse("folder:prefix\"middle\"suffix")) == FilterArgument(raw: "prefixmiddlesuffix", kind: .bare))
        #expect(try parse("content:\"\"") == filter(.content))
    }

    @Test func comparisons() throws {
        let ops: [(String, ComparisonOp)] = [(">", .gt), (">=", .gte), ("<", .lt), ("<=", .lte), ("=", .eq), ("!=", .ne)]
        for (token, op) in ops {
            #expect(filterArgument(try parse("size:\(token)10mb")) == FilterArgument(raw: "\(token)10mb", kind: .comparison(op, "10mb")))
        }
        #expect(filterArgument(try parse("dm:>=2024-01-01"))?.kind == .comparison(.gte, "2024-01-01"))
        #expect(filterArgument(try parse("parent:>\"path\""))?.kind == .comparison(.gt, "path"))
        #expect(filterArgument(try parse("size:>"))?.kind == .bare)
    }

    @Test func ranges() throws {
        #expect(filterArgument(try parse("size:1mb..10mb"))?.kind == .range(lower: "1mb", upper: "10mb"))
        #expect(filterArgument(try parse("size:..10mb"))?.kind == .range(lower: nil, upper: "10mb"))
        #expect(filterArgument(try parse("size:1mb.."))?.kind == .range(lower: "1mb", upper: nil))
        #expect(filterArgument(try parse("dm:2024-01-01..2024-12-31"))?.kind == .range(lower: "2024-01-01", upper: "2024-12-31"))
        #expect(filterArgument(try parse("parent:\"start\"..\"end\""))?.kind == .range(lower: "start", upper: "end"))
        // No digits and no quotes on either side: not a range.
        #expect(filterArgument(try parse("folder:a..b"))?.kind == .bare)
    }

    @Test func hyphenDateRanges() throws {
        #expect(filterArgument(try parse("dc:2014/8/1-2014/8/31"))?.kind == .range(lower: "2014/8/1", upper: "2014/8/31"))
        #expect(filterArgument(try parse("dc:1/8/2014-31/8/2014"))?.kind == .range(lower: "1/8/2014", upper: "31/8/2014"))
        #expect(filterArgument(try parse("dm:2024-01-01"))?.kind == .bare)
        #expect(filterArgument(try parse("size:2014/8/1-2014/8/31"))?.kind == .bare)
    }

    @Test func filtersMixWithTerms() throws {
        #expect(try parse("ext:png;jpg travel|vacation") ==
            .and([filter(.ext, FilterArgument(raw: "png;jpg", kind: .list(["png", "jpg"]))), .or([word("travel"), word("vacation")])]))
        #expect(try parse("in:/Users demo!.psd") ==
            .and([filter(.inFolder, bare("/Users")), word("demo"), .not(word(".psd"))]))
    }

    @Test func regex() throws {
        #expect(try parse("regex:^Report.*2025$") == .term(.regex("^Report.*2025$")))
        #expect(try parse(" regex:[^\\x00-\\x7f] ") == .term(.regex("[^\\x00-\\x7f]")))
        #expect(try parse("REGEX:foo") == .term(.regex("foo")))
        #expect(try parse("regex:\"a b\"") == .term(.regex("a b")))
        #expect(try parse("regex:[a b] x") == .and([.term(.regex("[a b]")), word("x")]))
        #expect(try parse("(regex:(a|b) x)") == .and([.term(.regex("(a|b)")), word("x")]))
        #expect(try parse("<regex:a>") == .term(.regex("a")))
        #expect(try parse("regex:^README\\.md$ parent:/Users/demo") ==
            .and([.term(.regex("^README\\.md$")), filter(.parent, bare("/Users/demo"))]))
        #expect(parseError("regex:")?.message.contains("requires a pattern") == true)
    }

    @Test func specExamplesParse() throws {
        let examples = [
            "report draft", "ext:pdf briefing", "parent:/Users demo!.psd", "regex:^Report.*2025$",
            "ext:png;jpg travel|vacation", "src/**/Cargo.toml", "\"Application Support\"",
            "folder:Pictures vacation", "file: invoice dm:pastyear", "ext:md content:\"TODO\"",
            "ext:pdf briefing parent:/Users/demo/Reports", "type:picture vacation", "type:code \"Cardinal\"",
            "audio: piano", "video:\"Keynote\"", "size:>1GB", "size:1mb..10mb", "size:tiny", "dm:today",
            "dc:lastyear", "dm:>=2024/01/01", "*.md content:\"Bearer \"", "tag:ProjectA;ProjectB report",
            "in:/Users/demo/Documents tag:\"Q4\"", "parent:/Users/demo/Documents !ext:pdf",
            "D:\\Music\\ !child:*.mp3", "%TEMP%\\*.log", "!.", "D: *.jpg|*.png", "musiclastyear:",
            "dimensions:1920x1080", "size:>1gb sizedupe:",
        ]
        for example in examples {
            #expect(parseError(example) == nil, "\(example)")
        }
    }
}

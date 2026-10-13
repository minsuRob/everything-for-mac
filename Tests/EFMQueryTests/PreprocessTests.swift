// Cases ported from cardisoft/cardinal (MIT): search-cache/src/query_preprocessor.rs and cardinal-syntax/tests/optimizer_*.rs.

import Testing
@testable import EFMQuery

private let home = "/Users/demo"

private func pre(_ s: String) throws -> Expr {
    preprocess(try parseQuery(s), homeDirectory: home)
}

@Suite struct HomeExpansionTests {
    @Test func words() throws {
        #expect(try pre("~/code") == word("/Users/demo/code"))
        #expect(try pre("~") == word("/Users/demo"))
        #expect(try pre("docs") == word("docs"))
        #expect(try pre("~someone/x") == word("~someone/x"))
        #expect(try pre("backup~") == word("backup~"))
        #expect(try pre("foo~/docs") == word("foo~/docs"))
    }

    @Test func phrasesAndRegexesAreLiteral() throws {
        #expect(try pre("\"~/docs\"") == phrase("~/docs"))
        #expect(try pre("regex:^~/docs$") == .term(.regex("^~/docs$")))
    }

    @Test func pathFilters() throws {
        #expect(try pre("infolder:~/projects") == filter(.inFolder, bare("/Users/demo/projects")))
        #expect(try pre("parent:~") == filter(.parent, bare("/Users/demo")))
        #expect(try pre("nosubfolders:~/x") == filter(.noSubfolders, bare("/Users/demo/x")))
        #expect(try pre("in:\"~/My Documents\"") == filter(.inFolder, FilterArgument(raw: "/Users/demo/My Documents", kind: .phrase)))
        #expect(try pre("ext:~") == filter(.ext, bare("~")))
        #expect(try pre("content:~/x") == filter(.content, bare("~/x")))
    }

    @Test func listsRangesComparisons() throws {
        #expect(try pre("parent:~/src;~/lib") ==
            filter(.parent, FilterArgument(raw: "/Users/demo/src;~/lib", kind: .list(["/Users/demo/src", "/Users/demo/lib"]))))
        let range = preprocess(filter(.inFolder, FilterArgument(raw: "~..~/scratch", kind: .range(lower: "~", upper: "~/scratch"))), homeDirectory: home)
        #expect(filterArgument(range)?.kind == .range(lower: "/Users/demo", upper: "/Users/demo/scratch"))
        let cmp = preprocess(filter(.parent, FilterArgument(raw: ">~/a", kind: .comparison(.gt, "~/a"))), homeDirectory: home)
        #expect(filterArgument(cmp)?.kind == .comparison(.gt, "/Users/demo/a"))
    }

    @Test func nested() throws {
        #expect(try pre("~/docs OR NOT parent:~/Downloads") ==
            .or([word("/Users/demo/docs"), .not(filter(.parent, bare("/Users/demo/Downloads")))]))
    }

    @Test func trailingSlashHome() {
        #expect(preprocess(word("~/x"), homeDirectory: "/Users/demo/") == word("/Users/demo/x"))
    }
}

@Suite struct OptimizerTests {
    @Test func emptyHandling() throws {
        #expect(try pre("foo||bar") == .empty)
        #expect(try pre("| foo") == .empty)
        #expect(try pre("foo |") == .empty)
        #expect(try pre("a|\"\"") == .empty)
        #expect(try pre(" AND ") == .empty)
        #expect(try pre(" | ") == .empty)
        #expect(try pre("foo AND ") == word("foo"))
        #expect(try pre("foo \"\" bar") == .and([word("foo"), word("bar")]))
        #expect(try pre("") == .empty)
    }

    @Test func flattening() {
        let nested: Expr = .and([word("a"), .and([word("b"), .and([word("c")])]), .or([.or([word("d"), word("e")])])])
        #expect(preprocess(nested, homeDirectory: home) == .and([word("a"), word("b"), word("c"), .or([word("d"), word("e")])]))
        #expect(preprocess(.or([.and([word("a")]), .or([word("b"), word("c")])]), homeDirectory: home) ==
            .or([word("a"), word("b"), word("c")]))
    }

    @Test func filtersMoveAfterTerms() throws {
        #expect(try pre("folder: dm:pastmonth ext:docx report") ==
            .and([word("report"), filter(.folder), filter(.dateModified, bare("pastmonth")), filter(.ext, bare("docx"))]))
        #expect(try pre("foo dc:thisweek bar dm:pastmonth ext:rs") ==
            .and([word("foo"), word("bar"), filter(.dateCreated, bare("thisweek")), filter(.dateModified, bare("pastmonth")), filter(.ext, bare("rs"))]))
    }

    @Test func scopeFirstTagAndContentLast() throws {
        #expect(try pre("tag:x content:y report parent:/a ext:md in:/b") ==
            .and([filter(.parent, bare("/a")), filter(.inFolder, bare("/b")), word("report"),
                  filter(.ext, bare("md")), filter(.tag, bare("x")), filter(.content, bare("y"))]))
    }

    @Test func negatedFiltersCountAsTerms() throws {
        #expect(try pre("!dm:today a") == .and([.not(filter(.dateModified, bare("today"))), word("a")]))
        #expect(try pre("folder:\"a\\\"b\" \"c\\\"d\"") == .and([phrase("c\"d"), filter(.folder, FilterArgument(raw: "a\"b", kind: .phrase))]))
    }

    @Test func groupsAreOptimizedRecursively() throws {
        // `report |` is "everything", so only the filter remains under the NOT.
        #expect(try pre("!(ext:zip report |)") == .not(filter(.ext, bare("zip"))))
    }
}

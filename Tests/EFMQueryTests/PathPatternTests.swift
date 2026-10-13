// Cases ported from cardisoft/cardinal (MIT): query-segmentation/src/lib.rs and search-cache/src/segment.rs.

import Testing
import EFMQuery

private func segs(_ word: String) -> [Segment] { pathPattern(forWord: word).segments }

@Suite struct PathPatternTests {
    @Test func specSection2_3Examples() {
        #expect(segs("elloworl") == [.literal("elloworl", .substr)])
        #expect(segs("/root") == [.literal("root", .prefix)])
        #expect(segs("root/") == [.literal("root", .suffix)])
        #expect(segs("/root/") == [.literal("root", .exact)])
        #expect(segs("/root/bar") == [.literal("root", .exact), .literal("bar", .prefix)])
        #expect(segs("/root/bar/kksk") == [.literal("root", .exact), .literal("bar", .exact), .literal("kksk", .prefix)])
        #expect(segs("foo/bar/kks") == [.literal("foo", .suffix), .literal("bar", .exact), .literal("kks", .prefix)])
        #expect(segs("gaea/lil/bee/") == [.literal("gaea", .suffix), .literal("lil", .exact), .literal("bee", .exact)])
        #expect(segs("bab/bob/") == [.literal("bab", .suffix), .literal("bob", .exact)])
        #expect(segs("/byb/huh/good/") == [.literal("byb", .exact), .literal("huh", .exact), .literal("good", .exact)])
    }

    @Test func twoSegments() {
        #expect(segs("foo/bar") == [.literal("foo", .suffix), .literal("bar", .prefix)])
        #expect(segs("foo/bar/") == [.literal("foo", .suffix), .literal("bar", .exact)])
        #expect(segs("/foo/bar") == [.literal("foo", .exact), .literal("bar", .prefix)])
        #expect(segs("/报告/测试/") == [.literal("报告", .exact), .literal("测试", .exact)])
    }

    @Test func starsAndGlobstars() {
        #expect(segs("*") == [.star])
        #expect(segs("**") == [.globstar])
        #expect(segs("foo/**/bar") == [.literal("foo", .suffix), .globstar, .literal("bar", .prefix)])
        #expect(segs("foo/*/bar") == [.literal("foo", .suffix), .star, .literal("bar", .prefix)])
        #expect(segs("/**/foo") == [.globstar, .literal("foo", .prefix)])
        #expect(segs("foo/**") == [.literal("foo", .suffix), .globstar])
        #expect(segs("src/**/Cargo.toml") == [.literal("src", .suffix), .globstar, .literal("Cargo.toml", .prefix)])
    }

    @Test func wildcardSegments() {
        #expect(segs("*.rs") == [.wildcard("*.rs")])
        #expect(segs("report-??.txt") == [.wildcard("report-??.txt")])
        #expect(segs("ers/demo/Proj*/**") == [.literal("ers", .suffix), .literal("demo", .exact), .wildcard("Proj*"), .globstar])
        #expect(segs("***") == [.wildcard("***")])
    }

    @Test func degenerateInputs() {
        #expect(segs("").isEmpty)
        #expect(segs("/").isEmpty)
        #expect(segs("///").isEmpty)
        #expect(segs("/a//b/").isEmpty)
        #expect(segs("/a/") == [.literal("a", .exact)])
        #expect(segs("//a") == [.literal("a", .prefix)])
    }
}

@Suite struct GlobTests {
    @Test func basics() {
        #expect(globMatches("*.rs", "main.rs", caseInsensitive: false))
        #expect(!globMatches("*.rs", "main.rsx", caseInsensitive: false))
        #expect(globMatches("report-??.txt", "report-01.txt", caseInsensitive: false))
        #expect(!globMatches("report-??.txt", "report-1.txt", caseInsensitive: false))
        #expect(globMatches("a*b", "ab", caseInsensitive: false))
        #expect(globMatches("a*b", "axxxb", caseInsensitive: false))
        #expect(!globMatches("a*b", "axxxbc", caseInsensitive: false))
        #expect(globMatches("*", "", caseInsensitive: false))
        #expect(globMatches("", "", caseInsensitive: false))
        #expect(!globMatches("", "a", caseInsensitive: false))
        #expect(!globMatches("?", "", caseInsensitive: false))
        #expect(globMatches("**", "anything", caseInsensitive: false))
        #expect(globMatches("*a*a*a*", "banana and a", caseInsensitive: false))
        #expect(!globMatches("*a*a*a*b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", caseInsensitive: false))
    }

    @Test func wholeStringOnly() {
        #expect(!globMatches("foo*", "xfoo", caseInsensitive: false))
        #expect(!globMatches("*foo", "foox", caseInsensitive: false))
    }

    @Test func regexMetacharactersAreLiteral() {
        #expect(globMatches("a.b(c)+[d]", "a.b(c)+[d]", caseInsensitive: false))
        #expect(!globMatches("a.b", "axb", caseInsensitive: false))
    }

    @Test func caseSensitivity() {
        #expect(!globMatches("*.RS", "main.rs", caseInsensitive: false))
        #expect(globMatches("*.RS", "Main.rs", caseInsensitive: true))
        #expect(globMatches("readme*", "README.md", caseInsensitive: true))
    }

    @Test func unicode() {
        #expect(globMatches("?", "é", caseInsensitive: false))
        #expect(globMatches("?", "😀", caseInsensitive: false))
        #expect(globMatches("报?", "报告", caseInsensitive: false))
        #expect(!globMatches("报??", "报告", caseInsensitive: false))
        #expect(globMatches("*告", "报告", caseInsensitive: false))
        #expect(globMatches("caf?.txt", "café.txt", caseInsensitive: true))
        #expect(globMatches("ÉTÉ*", "été.jpg", caseInsensitive: true))
        #expect(!globMatches("ÉTÉ*", "été.jpg", caseInsensitive: false))
        #expect(globMatches("*ü?", "Müller", caseInsensitive: false) == false)
        #expect(globMatches("*ü*", "Müller", caseInsensitive: false))
    }

    @Test func precompiledPatternOnBytes() {
        let glob = GlobPattern("*.JPG", caseInsensitive: true)
        let name = Array("Photo.jpg".utf8)
        #expect(name.withUnsafeBufferPointer { glob.matches(utf8: $0) })
        #expect(!glob.matches("photo.png"))
    }
}

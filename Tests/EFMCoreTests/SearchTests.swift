import CoreServices
import XCTest
@testable import EFMCore

final class SearchTests: XCTestCase {
    var root: String!
    var index: FileIndex!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "efm-test-\(UUID().uuidString)"
        let fm = FileManager.default
        let files: [String: Int] = [
            "Projects/cardinal/src/main.rs": 10,
            "Projects/cardinal/Cargo.toml": 5,
            "Projects/efm/Sources/Search.swift": 2_000,
            "Projects/efm/README.md": 100,
            "Documents/Report Draft.pdf": 3_000_000,
            "Documents/report-final.PDF": 10,
            "Documents/notes.txt": 0,
            "Documents/\u{1107}\u{1169}\u{1100}\u{1169}\u{1109}\u{1165}.txt": 1, // 보고서 in NFD
            "Documents/회의록 2026.md": 1,                                         // NFC
            "Music/song.mp3": 4_000,
            "src/lib/src/deep.rs": 1,
        ]
        for (path, size) in files {
            let full = root + "/" + path
            try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: full, contents: Data(count: size))
        }
        try "the Bearer token is here".write(toFile: root + "/Documents/notes.txt", atomically: false, encoding: .utf8)
        index = FileIndex(rootPath: root)
        Scanner(index: index, options: ScanOptions()).scan(path: root, entry: 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    func names(_ q: String, caseSensitive: Bool = false, sort: SearchSort = .default) throws -> [String] {
        let r = try index.search(q, options: SearchOptions(caseSensitive: caseSensitive, sort: sort))
        return r.entries.map { index.nameOf($0) }
    }

    func rel(_ q: String) throws -> Set<String> {
        let r = try index.search(q)
        return Set(r.entries.map { String(index.path(of: $0).dropFirst(root.count + 1)) })
    }

    func testScanCountsEverything() {
        // 11 files + 10 folders
        XCTAssertEqual(index.liveCount - 1, 21)
    }

    func testSubstringIsCaseInsensitiveByDefault() throws {
        XCTAssertEqual(Set(try names("report")), ["Report Draft.pdf", "report-final.PDF"])
        XCTAssertEqual(try names("Report", caseSensitive: true), ["Report Draft.pdf"])
    }

    func testAndOrNot() throws {
        XCTAssertEqual(try names("report draft"), ["Report Draft.pdf"])
        XCTAssertEqual(Set(try names("main.rs | cargo")), ["main.rs", "Cargo.toml"])
        XCTAssertEqual(try names("report !draft"), ["report-final.PDF"])
    }

    func testWildcards() throws {
        XCTAssertEqual(Set(try names("*.pdf")), ["Report Draft.pdf", "report-final.PDF"])
        XCTAssertEqual(try names("ma?n.rs"), ["main.rs"])
        XCTAssertEqual(try names("*.rs").count, 2)
    }

    func testKoreanMatchesAcrossNormalization() throws {
        XCTAssertEqual(try names("보고서").count, 1, "NFC query must match an NFD name")
        XCTAssertEqual(try names("회의"), ["회의록 2026.md"])
    }

    func testExtAndTypeFilters() throws {
        XCTAssertEqual(Set(try names("ext:pdf")), ["Report Draft.pdf", "report-final.PDF"])
        XCTAssertEqual(Set(try names("ext:rs;toml")), ["main.rs", "Cargo.toml", "deep.rs"])
        XCTAssertEqual(try names("audio:"), ["song.mp3"])
    }

    func testFileFolderFilters() throws {
        XCTAssertEqual(Set(try names("folder:src")), ["src"])
        XCTAssertEqual(try names("file: cargo"), ["Cargo.toml"])
    }

    func testSizeFilter() throws {
        XCTAssertEqual(try names("size:>1mb"), ["Report Draft.pdf"])
        XCTAssertTrue(try names("size:empty").isEmpty || (try names("size:empty")) == ["notes.txt"])
    }

    func testFolderScopes() throws {
        XCTAssertEqual(Set(try names("parent:\(root!)/Projects/cardinal")), ["src", "Cargo.toml"])
        XCTAssertEqual(Set(try names("in:\(root!)/Projects/efm")), ["Sources", "Search.swift", "README.md"])
    }

    func testPathSegments() throws {
        XCTAssertEqual(try rel("cardinal/src/main"), ["Projects/cardinal/src/main.rs"])
        XCTAssertEqual(try rel("efm/Sources/"), ["Projects/efm/Sources"])
        XCTAssertEqual(try rel("src/**/deep.rs"), ["src/lib/src/deep.rs"])
        XCTAssertEqual(try rel("/efm/**"), ["Projects/efm/Sources", "Projects/efm/Sources/Search.swift", "Projects/efm/README.md"])
    }

    func testRegex() throws {
        XCTAssertEqual(try names("regex:^main\\.rs$"), ["main.rs"])
    }

    func testContentFilter() throws {
        XCTAssertEqual(try names("ext:txt content:bearer"), ["notes.txt"])
        XCTAssertEqual(try names("ext:txt content:Bearer", caseSensitive: true), ["notes.txt"])
        XCTAssertTrue(try names("ext:txt content:BEARER", caseSensitive: true).isEmpty)
    }

    func testSorting() throws {
        let bySize = try names("file:", sort: SearchSort(.size, ascending: false))
        XCTAssertEqual(bySize.first, "Report Draft.pdf")
        let byName = try names("ext:rs;toml")
        XCTAssertEqual(byName, ["Cargo.toml", "deep.rs", "main.rs"])
        let byPath = try index.search("ext:rs", options: SearchOptions(sort: SearchSort(.path))).entries.map { index.path(of: $0) }
        XCTAssertEqual(byPath, byPath.sorted())
    }

    /// The cached-permutation path (used for large result sets) must agree with a direct sort,
    /// including entries added or modified after the permutation was built.
    func testPermutationSortMatchesDirectSort() throws {
        func run(_ q: String, _ sort: SearchSort) throws -> [UInt32] {
            try index.search(q, options: SearchOptions(sort: sort)).entries
        }
        let keys: [SortKey] = [.name, .path, .size, .dateModified]
        let saved = FileIndex.permutationThreshold
        defer { FileIndex.permutationThreshold = saved }
        FileIndex.permutationThreshold = 0
        for k in keys { _ = try run("", SearchSort(k)) } // build every permutation
        // Changes after the permutations were built.
        var info = efm_dirent_for_test(type: 0)
        info.size = 123_456
        info.mtime = 2_000_000_000
        let docs = index.lookup(path: root + "/Documents")!
        index.addEntry(name: "aaa-new.txt", parent: docs, info: info)
        index.addEntry(name: "zzz-new.txt", parent: 0, info: info)
        index.update(index.lookup(path: root + "/Music/song.mp3")!, info: info)
        index.names.commitOrder()
        for k in keys {
            for asc in [true, false] {
                for q in ["", "file:", "new"] {
                    FileIndex.permutationThreshold = 0
                    let viaPermutation = try run(q, SearchSort(k, ascending: asc))
                    FileIndex.permutationThreshold = .max
                    let direct = try run(q, SearchSort(k, ascending: asc))
                    if k == .name || k == .path {
                        XCTAssertEqual(viaPermutation, direct, "\(k) asc=\(asc) q=\(q)")
                    } else {
                        // Equal keys may tie in either order; compare the key sequence.
                        let key: (UInt32) -> Int64 = { k == .size ? self.index.sizeOf($0) : self.index.mtimeOf($0) }
                        XCTAssertEqual(viaPermutation.map(key), direct.map(key), "\(k) asc=\(asc) q=\(q)")
                        XCTAssertEqual(Set(viaPermutation), Set(direct))
                    }
                }
            }
        }
    }

    func testEmptyQueryReturnsAllButRoot() throws {
        XCTAssertEqual(try index.search("").entries.count, 21)
    }

    func testRemoveAndReuseSlots() throws {
        let docs = index.lookup(path: root + "/Documents")!
        index.remove(docs)
        XCTAssertTrue(try names("report").isEmpty)
        XCTAssertNil(index.lookup(path: root + "/Documents/notes.txt"))
        var info = efm_dirent_for_test(type: 0)
        let e = index.addEntry(name: "new-report.txt", parent: 0, info: info)
        XCTAssertEqual(try names("report"), ["new-report.txt"])
        info.size = 5
        index.update(e, info: info)
        XCTAssertEqual(index.sizeOf(e), 5)
    }
}

import CEFM
func efm_dirent_for_test(type: Int) -> efm_dirent {
    var d = efm_dirent()
    d.type = UInt8(type)
    return d
}

final class StoreTests: XCTestCase {
    func testEventsUpdateIndexAndCacheRoundTrips() throws {
        let root = NSTemporaryDirectory() + "efm-store-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/a/b", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/a/b/one.txt", contents: nil)
        defer { try? fm.removeItem(atPath: root) }
        let cache = URL(fileURLWithPath: root + "-cache.idx")
        defer { try? fm.removeItem(at: cache) }

        let store = IndexStore(rootPath: root, cacheURL: cache)
        let ready = expectation(description: "ready")
        store.onStateChange = { if $0 == .ready { ready.fulfill() } }
        store.start()
        wait(for: [ready], timeout: 10)
        store.stop()
        store.waitUntilIdle()
        func count(_ q: String) throws -> Int { try store.search(q, options: SearchOptions(), token: CancelToken()).entries.count }
        XCTAssertEqual(try count("one"), 1)

        // New file, new folder with contents, removal — delivered as file-level events.
        fm.createFile(atPath: root + "/a/two.txt", contents: nil)
        try fm.createDirectory(atPath: root + "/a/c/d", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/a/c/d/three.txt", contents: nil)
        try fm.removeItem(atPath: root + "/a/b/one.txt")
        let flags = { (f: Int) in FSEventStreamEventFlags(f) }
        store.apply([
            FSEvent(path: store.rootPath + "/a/two.txt", flags: flags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile), id: 10),
            FSEvent(path: store.rootPath + "/a/c", flags: flags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir), id: 11),
            FSEvent(path: store.rootPath + "/a/b/one.txt", flags: flags(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile), id: 12),
        ])
        XCTAssertEqual(try count("two"), 1)
        XCTAssertEqual(try count("three"), 1, "contents of a new folder are scanned")
        XCTAssertEqual(try count("one"), 0)

        // Default (name) order holds for the full listing after scan + incremental updates.
        let all = try store.search("", options: SearchOptions(), token: CancelToken()).entries
        let folded = store.read { idx in all.map { idx.nameOf($0).precomposedStringWithCanonicalMapping.lowercased() } }
        XCTAssertEqual(folded, folded.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })

        try store.save()
        let reloaded = IndexStore(rootPath: root, cacheURL: cache)
        let ready2 = expectation(description: "ready2")
        reloaded.onStateChange = { if $0 == .ready { ready2.fulfill() } }
        reloaded.start()
        wait(for: [ready2], timeout: 10)
        reloaded.stop()
        reloaded.waitUntilIdle()
        XCTAssertEqual(try reloaded.search("three", options: SearchOptions(), token: CancelToken()).entries.count, 1)
        XCTAssertEqual(reloaded.entryCount, store.entryCount)
    }

    /// Real FSEvents end to end: files created/renamed/deleted on disk show up in searches.
    func testLiveFSEvents() throws {
        // Deliberately under /var (a symlink to /private/var): the store must canonicalise it.
        let root = NSTemporaryDirectory() + "efm-live-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        let store = IndexStore(rootPath: root, cacheURL: URL(fileURLWithPath: root + ".idx"))
        defer { try? fm.removeItem(atPath: root + ".idx") }
        let ready = expectation(description: "ready")
        store.onStateChange = { if $0 == .ready { ready.fulfill() } }
        store.start()
        wait(for: [ready], timeout: 10)
        store.waitUntilIdle()
        defer { store.stop() }

        func eventually(_ q: String, _ want: Int, file: StaticString = #filePath, line: UInt = #line) {
            var got = -1
            for _ in 0..<50 {
                got = (try? store.search(q, options: SearchOptions(), token: CancelToken()).entries.count) ?? -1
                if got == want { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
            XCTFail("\(q): expected \(want), got \(got)", file: file, line: line)
        }

        fm.createFile(atPath: root + "/live-alpha.txt", contents: nil)
        try fm.createDirectory(atPath: root + "/dir/sub", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/dir/sub/live-beta.txt", contents: nil)
        eventually("live-alpha", 1)
        eventually("live-beta", 1)

        try fm.moveItem(atPath: root + "/live-alpha.txt", toPath: root + "/live-gamma.txt")
        eventually("live-alpha", 0)
        eventually("live-gamma", 1)

        try fm.moveItem(atPath: root + "/dir", toPath: root + "/renamed-dir")
        eventually("renamed-dir/sub/live-beta", 1)
        eventually("dir/sub/live-beta", 1) // "dir" is a suffix match of "renamed-dir"
        eventually("/dir/", 0)

        try fm.removeItem(atPath: root + "/renamed-dir")
        eventually("live-beta", 0)
    }

    func testMinimalCover() {
        XCTAssertEqual(Set(minimalCover(["/a/b", "/a", "/a-b", "/a/b/c", "/c"])), ["/a", "/a-b", "/c"])
    }
}

import Foundation

extension QueryEvaluator {
    /// `content:` — streams each candidate file looking for a byte substring (ASCII case folding
    /// when case-insensitive, like Cardinal). Runs on all cores; only regular files are read.
    func contentFilter(needle: String, candidates: BitSet?, caseSensitive cs: Bool) throws -> BitSet {
        let src = candidates ?? live
        var files: [UInt32] = []
        src.forEach { e in
            if self.index.flags[e] & (EntryFlags.directory.rawValue | EntryFlags.symlink.rawValue) == 0 {
                files.append(UInt32(e))
            }
        }
        let paths = files.map { index.path(of: $0) }
        let needleBytes = Array((cs ? needle : needle.lowercased()).utf8)
        let out = BitSet(count: index.capacity)
        let hits = UnsafeMutablePointer<UInt8>.allocate(capacity: max(files.count, 1))
        hits.initialize(repeating: 0, count: max(files.count, 1))
        defer { hits.deallocate() }
        let flag = token.flag
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            if flag.pointee != 0 { return }
            if fileContains(paths[i], needleBytes, foldASCII: !cs, cancel: flag) { hits[i] = 1 }
        }
        try checkCancelled()
        for (i, e) in files.enumerated() where hits[i] != 0 { out.insert(Int(e)) }
        return out
    }

    /// `tag:` — Finder tags from the `com.apple.metadata:_kMDItemUserTags` xattr. Values in the
    /// list are ORed; matching is by substring.
    func tagFilter(wanted: [String], candidates: BitSet?, caseSensitive cs: Bool) throws -> BitSet {
        let src = candidates ?? live
        var ids: [UInt32] = []
        src.forEach { ids.append(UInt32($0)) }
        let paths = ids.map { index.path(of: $0) }
        let needles = wanted.map { cs ? $0 : $0.lowercased() }
        let hits = UnsafeMutablePointer<UInt8>.allocate(capacity: max(ids.count, 1))
        hits.initialize(repeating: 0, count: max(ids.count, 1))
        defer { hits.deallocate() }
        let flag = token.flag
        DispatchQueue.concurrentPerform(iterations: ids.count) { i in
            if flag.pointee != 0 { return }
            let tags = finderTags(paths[i]).map { cs ? $0 : $0.lowercased() }
            if tags.contains(where: { t in needles.contains { t.contains($0) } }) { hits[i] = 1 }
        }
        try checkCancelled()
        let out = BitSet(count: index.capacity)
        for (i, e) in ids.enumerated() where hits[i] != 0 { out.insert(Int(e)) }
        return out
    }
}

func fileContains(_ path: String, _ needle: [UInt8], foldASCII: Bool, cancel: UnsafeMutablePointer<Int32>) -> Bool {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    _ = fcntl(fd, F_NOCACHE, 1)
    let chunk = 1 << 20
    let keep = needle.count - 1
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk + keep)
    defer { buf.deallocate() }
    var carry = 0
    while cancel.pointee == 0 {
        let n = read(fd, buf + carry, chunk)
        if n <= 0 { return false }
        let total = carry + n
        if foldASCII {
            for i in carry..<total where buf[i] &- 65 < 26 { buf[i] |= 0x20 }
        }
        if total >= needle.count {
            let found = needle.withUnsafeBufferPointer { nd in
                memmem(buf, total, nd.baseAddress!, nd.count) != nil
            }
            if found { return true }
        }
        carry = min(keep, total)
        if carry > 0 { memmove(buf, buf + total - carry, carry) }
    }
    return false
}

func finderTags(_ path: String) -> [String] {
    let name = "com.apple.metadata:_kMDItemUserTags"
    let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return [] }
    var data = Data(count: size)
    let got = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
    guard got > 0,
          let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
    // Entries look like "Red\n6" (name, newline, colour index).
    return list.map { $0.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? $0 }
}

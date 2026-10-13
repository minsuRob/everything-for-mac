import CEFM
import Foundation

public struct ScanOptions: Sendable {
    public var ignorePaths: Set<String>
    /// Descend into other mounted volumes (external disks, network shares) under the root.
    public var crossDevices: Bool

    public init(ignorePaths: Set<String> = [], crossDevices: Bool = false) {
        self.ignorePaths = ignorePaths
        self.crossDevices = crossDevices
    }

    /// Cardinal's default: on "/", skip the Data volume mount because firmlinks already
    /// expose its contents (/Users, /Applications…) and it would index everything twice.
    public static func defaults(for root: String) -> ScanOptions {
        ScanOptions(ignorePaths: root == "/" ? ["/System/Volumes/Data"] : [])
    }
}

/// Parallel directory walker built on `getattrlistbulk` (one syscall returns names, types,
/// sizes and dates for a batch of children). Cardinal walks with `read_dir` and leaves
/// size/dates unfetched, so its `size:` / `dm:` filters and size/date sorting `lstat` each
/// candidate at query time; here they are collected during the walk at no extra syscalls.
final class Scanner: @unchecked Sendable {
    private let index: FileIndex
    private let options: ScanOptions
    private let allowedDevices: Set<UInt32>
    private let cond = NSCondition()
    private var jobs: [(path: String, entry: UInt32)] = []
    private var pending = 0
    private var cancelled: @Sendable () -> Bool
    private(set) var scannedCount = 0
    private let progress: (@Sendable (Int) -> Void)?

    init(index: FileIndex, options: ScanOptions,
         cancelled: @escaping @Sendable () -> Bool = { false },
         progress: (@Sendable (Int) -> Void)? = nil) {
        self.index = index
        self.options = options
        self.cancelled = cancelled
        self.progress = progress
        var devs: Set<UInt32> = []
        var info = efm_dirent()
        if efm_stat_path(index.rootPath, &info) == 0 { devs.insert(info.dev) }
        if index.rootPath == "/", efm_stat_path("/System/Volumes/Data", &info) == 0 { devs.insert(info.dev) }
        allowedDevices = devs
    }

    /// Scans the directory at `path` (already present as `entry`) and everything below it,
    /// adding children to the index. The caller must hold exclusive access to the index.
    /// Returns false if cancelled.
    @discardableResult
    func scan(path: String, entry: UInt32) -> Bool {
        jobs = [(path, entry)]
        pending = 1
        let workers = max(2, min(activeProcessorCount * 2, 24))
        let group = DispatchGroup()
        for _ in 0..<workers {
            group.enter()
            let t = Thread { [self] in
                work()
                group.leave()
            }
            t.stackSize = 1 << 20
            t.qualityOfService = .userInitiated
            t.start()
        }
        group.wait()
        return !cancelled()
    }

    private func work() {
        var buf = efm_dirbuf()
        efm_dirbuf_init(&buf)
        defer { efm_dirbuf_free(&buf) }
        var lastReported = 0
        while true {
            cond.lock()
            while jobs.isEmpty && pending > 0 { cond.wait() }
            if pending == 0 {
                cond.unlock()
                return
            }
            let job = jobs.removeLast()
            cond.unlock()

            let err = cancelled() ? ECANCELED : job.path.withCString { efm_read_dir($0, &buf) }

            cond.lock()
            if err == 0 {
                addChildren(of: job, &buf)
                if let progress, scannedCount - lastReported > 50_000 {
                    lastReported = scannedCount
                    progress(scannedCount)
                }
            }
            pending -= 1
            if pending == 0 || !jobs.isEmpty { cond.broadcast() }
            cond.unlock()
        }
    }

    /// Called with `cond` held.
    private func addChildren(of job: (path: String, entry: UInt32), _ buf: inout efm_dirbuf) {
        let prefix = job.path == "/" ? "" : job.path
        for i in 0..<buf.count {
            let d = buf.ents[i]
            let namePtr = UnsafeRawPointer(buf.names + Int(d.name_off)).assumingMemoryBound(to: UInt8.self)
            let isDir = Int(d.type) == EFM_TYPE_DIR
            var childPath: String?
            if isDir || !options.ignorePaths.isEmpty {
                let name = String(decoding: UnsafeBufferPointer(start: namePtr, count: Int(d.name_len)), as: UTF8.self)
                let p = prefix + "/" + name
                if options.ignorePaths.contains(p) { continue }
                childPath = p
            }
            let id = index.names.intern(namePtr, Int(d.name_len))
            let e = index.addEntry(nameId: id, parent: job.entry, info: d)
            scannedCount += 1
            if isDir, let childPath {
                if options.crossDevices || allowedDevices.isEmpty || allowedDevices.contains(d.dev) {
                    jobs.append((childPath, e))
                    pending += 1
                } else {
                    index.setFlag(e, .mountPoint, true)
                }
            }
        }
    }
}

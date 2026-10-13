import CoreServices
import Foundation

public struct FSEvent: Sendable {
    public var path: String
    public var flags: FSEventStreamEventFlags
    public var id: FSEventStreamEventId

    public func has(_ f: Int) -> Bool { flags & FSEventStreamEventFlags(f) != 0 }
    public var isDirectory: Bool { has(kFSEventStreamEventFlagItemIsDir) }
    /// Kernel or user-space queue overflow, or an explicit "rescan below here".
    public var needsSubtreeScan: Bool {
        has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagUserDropped)
            || has(kFSEventStreamEventFlagKernelDropped)
    }
    public var isHistoryDone: Bool { has(kFSEventStreamEventFlagHistoryDone) }
    public var rootChanged: Bool { has(kFSEventStreamEventFlagRootChanged) }
}

/// File-level FSEvents stream on the watch root, replaying from `sinceWhen` on start.
final class Watcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "efm.fsevents", qos: .utility)
    private let handler: @Sendable ([FSEvent]) -> Void

    init(handler: @escaping @Sendable ([FSEvent]) -> Void) {
        self.handler = handler
    }

    deinit { stop() }

    func start(path: String, sinceWhen: FSEventStreamEventId, latency: TimeInterval = 0.1) {
        stop()
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            let me = Unmanaged<Watcher>.fromOpaque(info!).takeUnretainedValue()
            let cfPaths = unsafeBitCast(paths, to: NSArray.self)
            var events: [FSEvent] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                guard let p = cfPaths[i] as? String else { continue }
                events.append(FSEvent(path: p, flags: flags[i], id: ids[i]))
            }
            me.handler(events)
        }
        let createFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [path] as CFArray, sinceWhen, latency, createFlags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    static var currentEventId: FSEventStreamEventId { FSEventsGetCurrentEventId() }
}

/// Smallest set of paths covering every change: drops paths whose ancestor is already listed
/// (same idea as Cardinal's `scan_paths`).
func minimalCover(_ paths: [String]) -> [String] {
    // Sorting by "path/" puts every descendant of X directly after X ("X/" is a prefix of them),
    // so one comparison with the last kept path suffices: O(n log n).
    let keyed = Set(paths).map { $0.hasSuffix("/") ? $0 : $0 + "/" }.sorted()
    var kept: [String] = []
    var last: String?
    for k in keyed {
        if let l = last, k.hasPrefix(l) { continue }
        last = k
        kept.append(k == "/" ? "/" : String(k.dropLast()))
    }
    return kept
}

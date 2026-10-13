import EFMCore
import Foundation

func usage() -> Never {
    print("""
    usage:
      efm search [--root PATH] [--cache FILE] [--case] [--sort KEY[:desc]] [--limit N] QUERY...
          Load (or build) the index and run each QUERY, printing timings and the first results.
      efm bench [--root PATH] [--cache FILE] [--repeat N] QUERY...
          Like search, but prints only timings (median of N runs).
      efm scan [--root PATH] [--cache FILE]
          Build the index from scratch and save it.
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

var root = "/"
var cachePath: String?
var options = SearchOptions()
var limit = 10
var repeatCount = 5
var queries: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--root": root = args.removeFirst()
    case "--cache": cachePath = args.removeFirst()
    case "--case": options.caseSensitive = true
    case "--limit": limit = Int(args.removeFirst()) ?? 10
    case "--repeat": repeatCount = Int(args.removeFirst()) ?? 5
    case "--sort":
        let parts = args.removeFirst().split(separator: ":")
        guard let key = SortKey(rawValue: String(parts[0])) else { usage() }
        options.sort = SearchSort(key, ascending: parts.count < 2 || parts[1] != "desc")
    default: queries.append(a)
    }
}
if root != "/" && root.hasSuffix("/") { root.removeLast() }

let cacheURL = URL(fileURLWithPath: cachePath ?? NSTemporaryDirectory() + "efm-\(abs(root.hashValue)).idx")
let store = IndexStore(rootPath: root, cacheURL: cacheURL)
let ready = DispatchSemaphore(value: 0)
store.onStateChange = { state in
    switch state {
    case .ready, .failed: ready.signal()
    case .scanning: break
    default: break
    }
}
let t0 = Date()
if command == "scan" { try? FileManager.default.removeItem(at: cacheURL) }
store.start()
ready.wait()
store.stop()
store.waitUntilIdle() // let the post-scan save finish
FileHandle.standardError.write("\n".data(using: .utf8)!)
print(String(format: "index ready: %d entries in %.2fs", store.entryCount, Date().timeIntervalSince(t0)))

switch command {
case "scan":
    break
case "search":
    for q in queries {
        do {
            let r = try store.search(q, options: options, token: CancelToken())
            print(String(format: "\n%@  →  %d results in %.2f ms", q, r.entries.count, r.elapsed * 1000))
            store.read { idx in
                for e in r.entries.prefix(limit) { print("  " + idx.path(of: e)) }
            }
        } catch {
            print("\n\(q)  →  error: \(error)")
        }
    }
case "bench":
    print("query\tresults\tfirst_ms\tmedian_ms\tmin_ms")
    for q in queries {
        var times: [Double] = []
        var n = 0
        for _ in 0..<repeatCount {
            guard let r = try? store.search(q, options: options, token: CancelToken()) else { break }
            times.append(r.elapsed * 1000)
            n = r.entries.count
        }
        guard !times.isEmpty else { print("\(q)\terror"); continue }
        let first = times[0]
        times.sort()
        print(String(format: "%@\t%d\t%.2f\t%.2f\t%.2f", q, n, first, times[times.count / 2], times[0]))
    }
default:
    usage()
}

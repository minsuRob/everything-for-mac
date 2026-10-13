import AppKit
import UniformTypeIdentifiers

/// Row icons without per-row `icon(forFile:)` calls: one folder icon, one icon per
/// extension (via UTType), and real icons for `.app` bundles loaded off the main thread
/// and cached by path.
final class IconCache {
    static let shared = IconCache()

    /// Called on the main thread when an asynchronously loaded icon becomes available.
    var onIconLoaded: ((String) -> Void)?

    private let folder: NSImage
    private let genericFile: NSImage
    private var byExtension: [String: NSImage] = [:]
    private var packageByExtension: [String: NSImage] = [:]
    private var appIcons: [String: NSImage] = [:]
    private var pending = Set<String>()
    private let loader = DispatchQueue(label: "efm.icons", qos: .utility)
    private let maxAppIcons = 2000

    private init() {
        folder = NSWorkspace.shared.icon(for: .folder)
        genericFile = NSWorkspace.shared.icon(for: .data)
        folder.size = NSSize(width: 16, height: 16)
        genericFile.size = NSSize(width: 16, height: 16)
    }

    /// Main thread only.
    func icon(name: String, path: @autoclosure () -> String, isDirectory: Bool) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        if isDirectory {
            if ext.isEmpty { return folder }
            if ext == "app" { return appIcon(path: path()) }
            if let img = packageByExtension[ext] { return img }
            var img = folder
            if let t = UTType(filenameExtension: ext, conformingTo: .directory), t.conforms(to: .package) {
                img = NSWorkspace.shared.icon(for: t)
                img.size = NSSize(width: 16, height: 16)
            }
            packageByExtension[ext] = img
            return img
        }
        if ext.isEmpty { return genericFile }
        if let img = byExtension[ext] { return img }
        var img = genericFile
        if let t = UTType(filenameExtension: ext) {
            img = NSWorkspace.shared.icon(for: t)
            img.size = NSSize(width: 16, height: 16)
        }
        byExtension[ext] = img
        return img
    }

    private func appIcon(path: String) -> NSImage {
        if let img = appIcons[path] { return img }
        let placeholder = packageByExtension["app"] ?? {
            let img = NSWorkspace.shared.icon(for: .applicationBundle)
            img.size = NSSize(width: 16, height: 16)
            packageByExtension["app"] = img
            return img
        }()
        if pending.insert(path).inserted {
            loader.async { [weak self] in
                let img = NSWorkspace.shared.icon(forFile: path)
                img.size = NSSize(width: 16, height: 16)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pending.remove(path)
                    if self.appIcons.count >= self.maxAppIcons { self.appIcons.removeAll(keepingCapacity: true) }
                    self.appIcons[path] = img
                    self.onIconLoaded?(path)
                }
            }
        }
        return placeholder
    }
}

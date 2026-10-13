import AppKit
import Darwin

/// Full Disk Access detection: TCC gives EPERM when opening protected files without it.
enum FullDiskAccess {
    enum Status { case granted, denied, unknown }

    static func check() -> Status {
        let home = NSHomeDirectory()
        let probes = [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
            home + "/Library/Mail",
            home + "/Library/Safari",
        ]
        var sawDenied = false
        for p in probes {
            let fd = open(p, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            if fd >= 0 {
                close(fd)
                // Directories open fine even without access; list them to be sure.
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                    if (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil { return .granted }
                    sawDenied = true
                    continue
                }
                return .granted
            }
            if errno == EPERM || errno == EACCES { sawDenied = true }
        }
        return sawDenied ? .denied : .unknown
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

import AppKit
import EFMCore

/// Coalesces bursts of background signals into at most one main-thread call per interval.
final class Throttler: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false
    private let interval: TimeInterval
    private let action: @MainActor () -> Void

    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    func signal() {
        lock.lock()
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [self] in
            lock.lock()
            scheduled = false
            lock.unlock()
            MainActor.assumeIsolated { action() }
        }
    }
}

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func testAndClear() -> Bool { lock.lock(); defer { lock.unlock() }; let v = value; value = false; return v }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var store: IndexStore!
    private var mainWC: MainWindowController!
    private var prefsWC: PreferencesWindowController?
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var saveTimer: Timer?
    private let changedSinceSave = AtomicFlag()
    private var fullDiskAccess: FullDiskAccess.Status = .unknown
    private let saveQueue = DispatchQueue(label: "efm.save", qos: .utility)
    private lazy var changeThrottle = Throttler(interval: 0.3) { [weak self] in self?.mainWC?.indexDidChange() }
    private lazy var stateThrottle = Throttler(interval: 0.2) { [weak self] in self?.mainWC?.updateIndexStatus() }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(Settings.shared.hideDockIcon ? .accessory : .regular)
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = makeStore()
        mainWC = MainWindowController(store: store)
        mainWC.onRescan = { [weak self] in self?.rescanIndex(nil) }
        store.start()

        applyUIPreferences()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .efmSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)

        checkFullDiskAccess(initial: true)

        // Periodic save when the index changed (FSEvents updates).
        saveTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveInBackground() }
        }

        NSApp.activate(ignoringOtherApps: true)
        mainWC.show()
    }

    private func makeStore() -> IndexStore {
        let root = Settings.shared.watchRoot
        let s = IndexStore(rootPath: root, cacheURL: Settings.cacheURL(for: root),
                           scanOptions: Settings.shared.scanOptions(for: root))
        s.onChange = { [weak self] in
            guard let self else { return }
            self.changedSinceSave.set()
            self.changeThrottle.signal()
        }
        s.onStateChange = { [weak self] _ in self?.stateThrottle.signal() }
        NSLog("EFM: watching %@ (cache %@)", root, Settings.cacheURL(for: root).path)
        return s
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWC.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        mainWC?.history.persist()
        store?.stop()
        do { try store?.save() } catch { NSLog("EFM: saving index failed: %@", "\(error)") }
    }

    private func saveInBackground() {
        guard changedSinceSave.testAndClear(), let store else { return }
        saveQueue.async {
            do { try store.save() } catch { NSLog("EFM: periodic save failed: %@", "\(error)") }
        }
    }

    // MARK: Preferences

    @objc func showPreferences(_ sender: Any?) {
        if prefsWC == nil {
            let wc = PreferencesWindowController()
            wc.onApplyIndexSettings = { [weak self] rootChanged in self?.applyIndexSettings(rootChanged: rootChanged) }
            prefsWC = wc
        }
        prefsWC?.load()
        NSApp.activate(ignoringOtherApps: true)
        prefsWC?.showWindow(nil)
        prefsWC?.window?.makeKeyAndOrderFront(nil)
    }

    private func applyIndexSettings(rootChanged: Bool) {
        let root = Settings.shared.watchRoot
        if rootChanged || Settings.canonical(root) != store.rootPath {
            let old = store!
            old.onChange = nil
            old.onStateChange = nil
            old.stop()
            saveQueue.async { try? old.save() }
            store = makeStore()
            mainWC.setStore(store)
            store.start()
        } else {
            store.updateScanOptions(Settings.shared.scanOptions(for: root))
        }
    }

    @objc private func settingsChanged() {
        applyUIPreferences()
    }

    private func applyUIPreferences() {
        let s = Settings.shared
        let policy: NSApplication.ActivationPolicy = s.hideDockIcon ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
        }

        if s.showStatusItem, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "EFM")
            item.button?.image?.isTemplate = true
            let menu = NSMenu()
            menu.addItem(withTitle: "Show EFM", action: #selector(showMainWindow(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Rescan", action: #selector(rescanIndex(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Preferences…", action: #selector(showPreferences(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit EFM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            item.menu = menu
            statusItem = item
        } else if !s.showStatusItem, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }

        if s.globalHotKeyEnabled, hotKey == nil {
            hotKey = GlobalHotKey { [weak self] in self?.toggleMainWindow() }
        } else if !s.globalHotKeyEnabled, let hk = hotKey {
            hk.unregister()
            hotKey = nil
        }
    }

    // MARK: Window / actions

    private func toggleMainWindow() {
        if mainWC.isVisibleAndKey {
            mainWC.hide()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            mainWC.show()
        }
    }

    @objc func showMainWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        mainWC.show()
    }

    @objc func rescanIndex(_ sender: Any?) {
        store.rescan()
    }

    @objc func showSearchHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Search Syntax"
        alert.informativeText = """
        report draft — names containing both words
        "Application Support" — exact phrase
        *.swift, report-??.txt — wildcards
        src/**/Package.swift — path segments
        ext:pdf;png   type:picture   size:>10mb   dm:today
        parent:/Users   infolder:~/Documents
        a|b — OR,  !tmp — NOT,  regex:^Report.*$

        ↑/↓ in the search field cycle history; ↓ moves to results.
        Enter / ⌘O open · ⌘R reveal · Space Quick Look · ⌘C copy files · ⇧⌘C copy paths
        ⌘⇧Space shows EFM from anywhere · Esc hides it.
        """
        alert.runModal()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(rescanIndex(_:)) {
            if case .scanning = store.state { return false }
            if case .loading = store.state { return false }
        }
        return true
    }

    // MARK: Full Disk Access

    @objc private func appBecameActive() {
        checkFullDiskAccess(initial: false)
    }

    private func checkFullDiskAccess(initial: Bool) {
        let previous = fullDiskAccess
        let now = FullDiskAccess.check()
        fullDiskAccess = now
        mainWC.setPermissionBannerVisible(now == .denied)
        if initial {
            NSLog("EFM: Full Disk Access %@", now == .granted ? "granted" : now == .denied ? "denied" : "unknown")
        } else if previous == .denied && now == .granted {
            NSLog("EFM: Full Disk Access granted — rescanning")
            store.rescan()
        }
    }
}

import AppKit

/// Programmatic main menu. Actions use the responder chain (nil target) so the search
/// field's editor, the results table, the window controller and the app delegate each
/// handle what they own.
enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }

        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            menu.addItem(item)
            return item
        }

        // App
        let app = submenu("EFM")
        add(app, "About EFM", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        app.addItem(.separator())
        add(app, "Settings…", #selector(AppDelegate.showPreferences(_:)), ",")
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        app.addItem(services)
        app.addItem(.separator())
        add(app, "Hide EFM", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "")
        app.addItem(.separator())
        add(app, "Quit EFM", #selector(NSApplication.terminate(_:)), "q")

        // File
        let file = submenu("File")
        add(file, "Open", #selector(MainWindowController.openSelection(_:)), "o")
        add(file, "Reveal in Finder", #selector(MainWindowController.revealInFinder(_:)), "r")
        add(file, "Quick Look", #selector(MainWindowController.toggleQuickLook(_:)), "y")
        file.addItem(.separator())
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")

        // Edit
        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Delete", #selector(NSText.delete(_:)), "")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Copy Path", #selector(MainWindowController.copyPaths(_:)), "c", [.command, .shift])
        add(edit, "Copy Name", #selector(MainWindowController.copyNames(_:)), "")
        add(edit, "Copy File", #selector(MainWindowController.copyFiles(_:)), "")
        edit.addItem(.separator())
        add(edit, "Find…", #selector(MainWindowController.focusSearch(_:)), "f")

        // View
        let view = submenu("View")
        add(view, "Files", #selector(MainWindowController.showFiles(_:)), "1")
        add(view, "Recent Changes", #selector(MainWindowController.showEvents(_:)), "2")
        view.addItem(.separator())
        add(view, "Match Case", #selector(MainWindowController.toggleCaseSensitive(_:)), "c", [.command, .option])
        view.addItem(.separator())
        add(view, "Rescan Index", #selector(AppDelegate.rescanIndex(_:)), "r", [.command, .shift])
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        // Window
        let window = submenu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        window.addItem(.separator())
        add(window, "Search Window", #selector(AppDelegate.showMainWindow(_:)), "0")
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "")
        NSApp.windowsMenu = window

        // Help
        let help = submenu("Help")
        add(help, "Search Syntax", #selector(AppDelegate.showSearchHelp(_:)), "?")
        NSApp.helpMenu = help

        return main
    }
}

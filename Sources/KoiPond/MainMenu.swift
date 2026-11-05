import AppKit

/// The menu bar Koi Pond shows while it's the active app: the usual App, Edit and Window menus, with Settings
/// on Command-Comma and the Home window on Command-0.
enum MainMenu {
    static func make(openHome: @escaping () -> Void, openSettings: @escaping () -> Void) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Koi Pond")
        app.addItem(ClosureMenuItem("About Koi Pond", handler: StatusMenuController.showAbout))
        app.addItem(.separator())
        app.addItem(ClosureMenuItem("Settings…", key: ",", handler: openSettings))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide Koi Pond", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let others = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(others)
        app.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit Koi Pond", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        add(app, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        add(edit, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(.separator())
        window.addItem(ClosureMenuItem("Koi Pond", key: "0", handler: openHome))
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        add(window, to: main)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(ClosureMenuItem("Koi Pond on GitHub", key: "") {
            if let url = URL(string: "https://github.com/Tiger0821/koi-pond") { NSWorkspace.shared.open(url) }
        })
        add(help, to: main)
        NSApp.helpMenu = help
        return main
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}

import AppKit

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
    }
}

/// The menu bar fish: About, the Home window, Settings and Quit. Every pond setting lives in the Settings window.
final class StatusMenuController {
    private let statusItem: NSStatusItem

    /// Hidden when the user keeps Koi Pond in the Dock only.
    var isVisible: Bool {
        get { statusItem.isVisible }
        set { statusItem.isVisible = newValue }
    }

    init(openHome: @escaping () -> Void, openSettings: @escaping () -> Void) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: "Koi Pond")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("About Koi Pond", handler: Self.showAbout))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Open Koi Pond", handler: openHome))
        menu.addItem(ClosureMenuItem("Settings…", key: ",", handler: openSettings))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Koi Pond", key: "q") { NSApp.terminate(nil) })
        statusItem.menu = menu
    }

    static func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Koi Pond",
            .credits: NSAttributedString(string: "A living koi pond for your desktop, lock screen and screen saver."),
        ])
    }
}

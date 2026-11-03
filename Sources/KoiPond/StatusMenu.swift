import AppKit

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
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

/// The menu bar fish: About, Settings and Quit. Every pond setting lives in the Settings window.
final class StatusMenuController {
    private let statusItem: NSStatusItem

    init(openSettings: @escaping () -> Void) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: "Koi Pond")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("About Koi Pond") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [
                .applicationName: "Koi Pond",
                .credits: NSAttributedString(string: "A living koi pond for your desktop, lock screen and screen saver."),
            ])
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Open Settings…", key: ",", handler: openSettings))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Koi Pond", key: "q") { NSApp.terminate(nil) })
        statusItem.menu = menu
    }
}

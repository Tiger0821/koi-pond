import AppKit
import KoiPondRender

/// macOS's own desktop widgets: the switch behind System Settings › Desktop & Dock › Widgets ›
/// Show Widgets › On Desktop, which hides or shows them so the pond is clear.
enum DesktopWidgets {
    private static let domain = "com.apple.WindowManager" as CFString
    private static let key = "StandardHideWidgets" as CFString

    static var hidden: Bool {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? Bool ?? false
    }

    static func setHidden(_ hidden: Bool) {
        CFPreferencesSetAppValue(key, hidden as CFBoolean, domain)
        CFPreferencesAppSynchronize(domain)
        // Check that Window Manager picked the change up: the widgets are Notification Center's windows
        // just above the desktop icons.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Log.info("desktop widgets \(hidden ? "hidden" : "shown"); widget windows on screen: \(visibleCount())")
        }
    }

    static func visibleCount() -> Int {
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter {
            ($0[kCGWindowOwnerName as String] as? String) == "Notification Center"
                && ($0[kCGWindowLayer as String] as? Int).map { $0 > iconLevel && $0 < 0 } == true
        }.count
    }
}

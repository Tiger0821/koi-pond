import Foundation

/// Edits on the property list behind System Settings › Wallpaper
/// (~/Library/Application Support/com.apple.wallpaper/Store/Index.plist). It holds a `Desktop` and an
/// `Idle` (screen saver) entry per Space, per display and as system defaults; each entry's
/// `Content.Choices` names a provider plus a binary-plist configuration.
public enum WallpaperChoices {
    public enum Kind: String, Sendable {
        case desktop = "Desktop"
        case idle = "Idle"
    }

    public static func aerial(assetID: String) -> [String: Any] {
        choice(provider: "com.apple.wallpaper.choice.aerials", configuration: ["assetID": assetID])
    }

    public static func screenSaver(module: URL) -> [String: Any] {
        choice(provider: "com.apple.wallpaper.choice.screen-saver",
               configuration: ["module": ["relative": module.absoluteString]])
    }

    /// Provider and decoded configuration of a choice, for matching against a marker such as an asset ID.
    public static func describe(_ choice: [String: Any]) -> String {
        var text = choice["Provider"] as? String ?? ""
        if let data = choice["Configuration"] as? Data,
           let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            text += " \(configuration)"
        }
        return text
    }

    /// Every entry of `kind`, keyed by its path through the store.
    public static func entries(_ kind: Kind, in root: NSDictionary) -> [(path: String, entry: NSMutableDictionary)] {
        var found: [(String, NSMutableDictionary)] = []
        func visit(_ node: NSDictionary, _ path: String) {
            for case let (key as String, value as NSMutableDictionary) in node {
                let childPath = path.isEmpty ? key : "\(path)/\(key)"
                if key == kind.rawValue, value["Content"] is NSDictionary {
                    found.append((childPath, value))
                } else {
                    visit(value, childPath)
                }
            }
        }
        visit(root, "")
        return found.sorted { $0.0 < $1.0 }
    }

    public static func everywhere(_ kind: Kind, in root: NSDictionary, contains marker: String) -> Bool {
        let all = entries(kind, in: root)
        return !all.isEmpty && all.allSatisfy { current($0.entry).contains(marker) }
    }

    /// Points every `kind` entry at `choice`; returns the choices it replaced, keyed by path.
    public static func apply(_ choice: [String: Any], to kind: Kind, in root: NSMutableDictionary,
                             now: Date = Date()) -> [String: Any] {
        var previous: [String: Any] = [:]
        for (path, entry) in entries(kind, in: root) {
            guard let content = entry["Content"] as? NSMutableDictionary else { continue }
            previous[path] = content["Choices"] ?? [Any]()
            content["Choices"] = [choice]
            entry["LastSet"] = now
        }
        return previous
    }

    /// Puts `previous` back wherever an entry still holds a choice mentioning `marker`, leaving entries
    /// the user has changed since alone. Returns how many entries were restored.
    @discardableResult
    public static func restore(_ previous: [String: Any], kind: Kind, marker: String, in root: NSMutableDictionary,
                               now: Date = Date()) -> Int {
        var restored = 0
        for (path, entry) in entries(kind, in: root) {
            guard let content = entry["Content"] as? NSMutableDictionary, current(entry).contains(marker),
                  let choices = previous[path] else { continue }
            content["Choices"] = choices
            entry["LastSet"] = now
            restored += 1
        }
        return restored
    }

    private static func current(_ entry: NSDictionary) -> String {
        guard let content = entry["Content"] as? NSDictionary,
              let first = (content["Choices"] as? [Any])?.first as? [String: Any] else { return "" }
        return describe(first)
    }

    private static func choice(provider: String, configuration: [String: Any]) -> [String: Any] {
        let data = (try? PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)) ?? Data()
        return ["Provider": provider, "Files": [Any](), "Configuration": data]
    }
}

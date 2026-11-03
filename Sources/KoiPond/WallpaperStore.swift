import Foundation
import KoiPondCore
import KoiPondRender

/// Reads and writes macOS's wallpaper store file and makes WallpaperAgent pick up the change.
/// The edits themselves live in `WallpaperChoices`.
enum WallpaperStore {
    enum StoreError: LocalizedError {
        case unreadable
        case reverted

        var errorDescription: String? {
            switch self {
            case .unreadable: "macOS's wallpaper settings file couldn't be read."
            case .reverted: "macOS put the previous choice back right away."
            }
        }
    }

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    static func everywhere(_ kind: WallpaperChoices.Kind, contains marker: String) -> Bool {
        guard let root = try? load() else { return false }
        return WallpaperChoices.everywhere(kind, in: root, contains: marker)
    }

    /// Points every `kind` entry at `choice` and returns what it replaced. Blocks for a few seconds
    /// while it checks that the agent kept the change, so call it off the main thread.
    static func apply(_ choice: [String: Any], to kind: WallpaperChoices.Kind, marker: String) throws -> [String: Any] {
        try backUpOnce()
        let root = try load()
        let previous = WallpaperChoices.apply(choice, to: kind, in: root)
        for attempt in 1...2 {
            try save(root)
            reloadAgent()
            Thread.sleep(forTimeInterval: 1.5)
            if everywhere(kind, contains: marker) { break }
            if attempt == 2 { throw StoreError.reverted }
        }
        Log.info("set the \(kind.rawValue.lowercased()) choice on \(previous.count) Space and display entries")
        return previous
    }

    static func restore(_ previous: [String: Any], kind: WallpaperChoices.Kind, marker: String) throws {
        let root = try load()
        let restored = WallpaperChoices.restore(previous, kind: kind, marker: marker, in: root)
        guard restored > 0 else { return }
        try save(root)
        reloadAgent()
        Log.info("restored \(restored) \(kind.rawValue.lowercased()) entries")
    }

    /// A copy of the store as it was before Koi Pond first touched it.
    private static func backUpOnce() throws {
        let backup = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoiPond/Index.plist.before-koipond")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: backup)
    }

    private static func load() throws -> NSMutableDictionary {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves,
                                                                     format: nil) as? NSMutableDictionary
        else { throw StoreError.unreadable }
        return root
    }

    private static func save(_ root: NSMutableDictionary) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// SIGKILL rather than SIGTERM so the agent can't save its in-memory copy over ours on the way out;
    /// launchd starts it again and it reads the file fresh.
    private static func reloadAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-KILL", "WallpaperAgent"]
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}

import Foundation
import os

/// Writes to the unified log and to ~/Library/Logs/KoiPond.log.
public enum Log {
    private static let logger = Logger(subsystem: "com.koifishwallpaper.koipond", category: "app")
    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/KoiPond.log")

    /// Per-click logging, turned on with `defaults write com.koifishwallpaper.koipond DebugLogging -bool YES`.
    public static var debug: Bool { UserDefaults.standard.bool(forKey: "DebugLogging") }

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }
}

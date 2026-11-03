import Combine
import Foundation
import KoiPondCore

/// The one copy of the user's settings, saved to UserDefaults on every change.
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: PondSettings

    private let key = "PondSettings"
    private let migrationKey = "SettingsMigration"
    /// Trial settings (see `AppDelegate`) are used as given and never saved.
    private let persists: Bool

    init(trial: Data? = nil) {
        if let trial {
            settings = PondSettings.load(from: trial)
            persists = false
            return
        }
        persists = true
        var loaded = PondSettings.load(from: UserDefaults.standard.data(forKey: key))
        if UserDefaults.standard.integer(forKey: migrationKey) < 2 {
            // 0.1.0 rested the pond behind windows by default, which also froze it while the desktop was revealed.
            loaded.pauseWhenCovered = false
            UserDefaults.standard.set(2, forKey: migrationKey)
        }
        settings = loaded
        save(loaded)
    }

    func update(_ change: (inout PondSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        save(next)
    }

    private func save(_ settings: PondSettings) {
        guard persists else { return }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

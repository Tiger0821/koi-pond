import AppKit
import KoiPondCore
import ServiceManagement
import SwiftUI

/// The panes of the Settings window, in toolbar order.
enum SettingsPane: String, CaseIterable {
    case general, pond, fish, plants, music, lockScreen, performance

    var title: String {
        switch self {
        case .general: "General"
        case .pond: "Pond"
        case .fish: "Fish"
        case .plants: "Plants"
        case .music: "Music"
        case .lockScreen: "Lock Screen"
        case .performance: "Performance"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .pond: "drop.fill"
        case .fish: "fish.fill"
        case .plants: "leaf.fill"
        case .music: "music.note"
        case .lockScreen: "lock.fill"
        case .performance: "gauge.with.dots.needle.33percent"
        }
    }

    /// The pane's height, so the window fits each pane the way Mac settings windows do.
    var height: CGFloat {
        switch self {
        case .general: 640
        case .pond: 668
        case .fish: 430
        case .plants: 440
        case .music: 860
        case .lockScreen: 452
        case .performance: 450
        }
    }

    static let width: CGFloat = 560
}

/// The Settings window, as on every Mac: opened from the App menu with Command-Comma, a toolbar of panes that
/// always shows which is open, the window titled after the pane and sized to it, no minimize or zoom, and
/// reopening on the pane last used.
final class SettingsWindowController {
    private let store: SettingsStore
    private let lockScreen: LockScreenInstaller
    private let screenSaver: ScreenSaverInstaller
    private let music: MusicPlayer
    private let beat: MusicBeat
    private let lyrics: PondLyrics
    private var window: NSWindow?
    private var tabs: SettingsTabs?

    var isVisible: Bool { window?.isVisible ?? false }

    init(store: SettingsStore, lockScreen: LockScreenInstaller, screenSaver: ScreenSaverInstaller, music: MusicPlayer, beat: MusicBeat,
         lyrics: PondLyrics) {
        self.store = store
        self.lockScreen = lockScreen
        self.screenSaver = screenSaver
        self.music = music
        self.beat = beat
        self.lyrics = lyrics
    }

    func show(pane: SettingsPane? = nil) {
        if window == nil { build() }
        if let pane { tabs?.select(pane) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        // Read before adding the panes: adding the first one selects it, which would overwrite it.
        let last = SettingsPane(rawValue: UserDefaults.standard.string(forKey: SettingsTabs.lastPaneKey) ?? "") ?? .general
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: content(for: pane))
            host.sizingOptions = []
            host.title = pane.title
            host.preferredContentSize = NSSize(width: SettingsPane.width, height: pane.height)
            host.view.frame = NSRect(x: 0, y: 0, width: SettingsPane.width, height: pane.height)
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        tabs.select(last)
        tabs.remembers = true
        window.center()
        self.window = window
        self.tabs = tabs
    }

    private func content(for pane: SettingsPane) -> AnyView {
        switch pane {
        case .general: AnyView(GeneralPane(store: store))
        case .pond: AnyView(PondPane(store: store))
        case .fish: AnyView(FishPane(store: store))
        case .plants: AnyView(PlantsPane(store: store))
        case .music: AnyView(MusicPane(store: store, music: music, beat: beat, lyrics: lyrics))
        case .lockScreen: AnyView(LockScreenPane(store: store, lockScreen: lockScreen, screenSaver: screenSaver))
        case .performance: AnyView(PerformancePane(store: store))
        }
    }
}

/// Keeps the window sized to the open pane, top edge fixed, and remembers the pane.
private final class SettingsTabs: NSTabViewController {
    static let lastPaneKey = "SettingsPane"
    /// Off while the panes are being added.
    var remembers = false

    func select(_ pane: SettingsPane) {
        guard let index = SettingsPane.allCases.firstIndex(of: pane) else { return }
        selectedTabViewItemIndex = index
        fit(pane, animate: false)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let item = tabViewItem, let index = tabView.tabViewItems.firstIndex(of: item) else { return }
        let pane = SettingsPane.allCases[index]
        if remembers { UserDefaults.standard.set(pane.rawValue, forKey: Self.lastPaneKey) }
        fit(pane, animate: view.window?.isVisible ?? false)
    }

    private func fit(_ pane: SettingsPane, animate: Bool) {
        guard let window = view.window else { return }
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: SettingsPane.width, height: pane.height)).size
        let frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        if window.frame != frame { window.setFrame(frame, display: true, animate: animate) }
    }
}

// MARK: Shared pieces

extension SettingsStore {
    func binding<T>(_ keyPath: WritableKeyPath<PondSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    func count(_ keyPath: WritableKeyPath<PondSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(self.settings[keyPath: keyPath]) },
                set: { value in self.update { $0[keyPath: keyPath] = Int(value.rounded()) } })
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

private struct PercentSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: 0...1)
                Text("\(Int((value * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

private struct CountSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent {
            HStack {
                // No step: a tick mark for every fish is just noise. The binding rounds to whole numbers.
                Slider(value: $value, in: range)
                Text("\(Int(value))").monospacedDigit().foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

/// The water color presets, plus any color.
struct WaterSwatches: View {
    @ObservedObject var store: SettingsStore

    private var custom: Binding<Color> {
        Binding(get: { Color(store.settings.waterColor) }, set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            store.update { $0.waterColor = RGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)) }
        })
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WaterPreset.allCases, id: \.self) { preset in
                let chosen = store.settings.waterColor == preset.color
                Button {
                    store.update { $0.waterColor = preset.color }
                } label: {
                    Circle().fill(Color(preset.color)).frame(width: 20, height: 20)
                        .overlay(Circle().stroke(chosen ? Color.accentColor : .primary.opacity(0.2), lineWidth: chosen ? 2.5 : 1)
                            .padding(chosen ? -3 : 0))
                }
                .buttonStyle(.plain)
                .help(preset.title)
                .accessibilityLabel(preset.title)
            }
            ColorPicker("Custom color", selection: custom, supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 34)
                .help("Any color")
        }
    }
}

/// A short explanation under a group of settings, left-aligned like the rest of the form.
private struct Note: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Puts one pane's settings back to how they come.
private struct RestoreDefaults: View {
    @ObservedObject var store: SettingsStore
    let group: SettingsGroup

    var body: some View {
        HStack {
            Spacer()
            Button("Restore Defaults") { store.update { $0.restoreDefaults(group) } }
        }
    }
}

// MARK: Panes

private struct GeneralPane: View {
    @ObservedObject var store: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var widgetsHidden = DesktopWidgets.hidden
    @State private var loginError: String?
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Picker("Show Koi Pond in", selection: store.binding(\.presence)) {
                    ForEach(AppPresence.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Koi charge when Koi Pond opens", isOn: store.binding(\.launchCharge))
            } header: {
                Text("App")
            } footer: {
                Note("Opening Koi Pond sends ten koi crashing into your screen. It stays quiet when it opens at login.")
            }
            Section {
                Toggle("Pause the pond", isOn: store.binding(\.paused))
                Toggle("Hide macOS widgets on the desktop", isOn: Binding(get: { widgetsHidden }, set: { hidden in
                    DesktopWidgets.setHidden(hidden)
                    widgetsHidden = hidden
                }))
            } header: {
                Text("Desktop")
            } footer: {
                Note("Hiding widgets is the same switch as System Settings › Desktop & Dock › Show Widgets.")
            }
            Section {
                Toggle("Listen to Music so the fish can dance", isOn: store.binding(\.danceToMusic))
                DisclosureGroup("What Koi Pond can see and hear") {
                    Text("While a song plays and this is on, Koi Pond hears Music's sound, and only Music's (never the microphone or other apps), to find the beat; each moment of sound is measured and thrown away, and nothing is recorded or saved. It doesn't use Screen Recording, Accessibility or Input Monitoring: it reads click positions and window frames only to tell desktop clicks apart. What leaves your Mac: when Music has no cover for a song, the Now Playing player asks Apple's iTunes Search for it by song and artist name; and with Rock and Roll lyrics on, each new song's title, artist, album and length go to NetEase Cloud Music and LRCLIB to find its lyrics, which are then kept on your Mac.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Privacy")
            } footer: {
                Note("Turn listening off and Koi Pond never hears any sound; the fish just swim, and the player still shows what's playing.")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset All Settings", role: .destructive) { store.update { $0 = PondSettings() } }
        } message: {
            Text("Everything goes back to how Koi Pond comes, and the pond lock screen and screen saver are turned off.")
        }
        .onAppear { widgetsHidden = DesktopWidgets.hidden }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginError = "Approve Koi Pond in System Settings › General › Login Items."
        }
    }
}

private struct PondPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Weather", selection: store.binding(\.weather)) {
                    ForEach(WeatherPreset.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
            } header: {
                Text("Weather")
            } footer: {
                Note("Follow Device Time moves from dawn to moonlight with your clock.")
            }
            Section("Water") {
                LabeledContent("Color") { WaterSwatches(store: store) }
                PercentSlider(title: "Clarity", value: store.binding(\.clarity))
            }
            Section {
                Toggle("Ripples where you click", isOn: store.binding(\.touchRipples))
                Toggle("Clicking drops fish food", isOn: store.binding(\.feedTheFish))
            } header: {
                Text("Touch")
            } footer: {
                Note("Click bare desktop to touch the water. Press on a koi to pick it up and fling it.")
            }
            Section {
                Toggle("Currents", isOn: store.binding(\.currentsEnabled))
                DisclosureGroup("Advanced") {
                    PercentSlider(title: "Strength", value: store.binding(\.currentStrength))
                    PercentSlider(title: "Speed", value: store.binding(\.currentSpeed))
                    PercentSlider(title: "Glow", value: store.binding(\.coreGlow))
                }
                .disabled(!store.settings.currentsEnabled)
            } header: {
                Text("Currents")
            } footer: {
                Note("Slow currents carry the fish and leaves along and light up the water where they run.")
            }
            RestoreDefaults(store: store, group: .pond)
        }
        .formStyle(.grouped)
    }
}

private struct FishPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("How many") {
                CountSlider(title: "Koi", symbol: "fish.fill", value: store.count(\.koiCount), range: 0...40)
                CountSlider(title: "Small fish", symbol: "fish", value: store.count(\.smallFishCount), range: 0...60)
                CountSlider(title: "Turtles", symbol: "tortoise.fill", value: store.count(\.turtleCount), range: 0...4)
            }
            Section {
                Picker("Koi", selection: store.binding(\.behavior)) {
                    ForEach(FishBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Swimming speed") {
                    HStack {
                        Slider(value: store.binding(\.motionSpeed), in: 0.25...2)
                        Text(String(format: "%.2g×", store.settings.motionSpeed)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } header: {
                Text("Behavior")
            } footer: {
                Note(store.settings.behavior.summary)
            }
            RestoreDefaults(store: store, group: .fish)
        }
        .formStyle(.grouped)
    }
}

private struct PlantsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Lily pads") {
                CountSlider(title: "Lily pads", symbol: "circle.fill", value: store.count(\.lilyPadCount), range: 0...40)
            }
            Section {
                Picker("Kind", selection: store.binding(\.flowerStyle)) {
                    ForEach(FlowerStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                CountSlider(title: "Flowers", symbol: "camera.macro", value: store.count(\.flowerCount), range: 0...15)
            } header: {
                Text("Flowers")
            } footer: {
                Note("Flowers grow on lily pads, so there are never more flowers than pads.")
            }
            Section("Underwater") {
                CountSlider(title: "Plants", symbol: "leaf.fill", value: store.count(\.plantCount), range: 0...60)
            }
            RestoreDefaults(store: store, group: .plants)
        }
        .formStyle(.grouped)
    }
}

private struct MusicPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var music: MusicPlayer
    @ObservedObject var beat: MusicBeat
    @ObservedObject var lyrics: PondLyrics

    /// The style picker: one style for everything, or nil to match the styles to each song.
    private var style: Binding<RockStyle?> {
        Binding(get: { store.settings.rockStyle }, set: { value in store.update { $0.rockStyle = value } })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show the player on the desktop", isOn: store.binding(\.nowPlaying))
                if store.settings.nowPlaying {
                    Picker("Size", selection: store.binding(\.nowPlayingSize)) {
                        ForEach(NowPlayingSize.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Move to corner") {
                        HStack {
                            ForEach(ScreenCorner.allCases, id: \.self) { corner in
                                Button {
                                    store.update {
                                        $0.nowPlayingX = corner.fraction.x
                                        $0.nowPlayingY = corner.fraction.y
                                    }
                                } label: { Image(systemName: corner.symbol) }
                                .help(corner.title)
                            }
                        }
                    }
                    LabeledContent("Status", value: music.status)
                    if music.access == .denied {
                        Button("Allow Koi Pond to Control Music…") { MusicPlayer.openAutomationSettings() }
                    }
                }
            } header: {
                Text("Now Playing")
            } footer: {
                Note("A pixel-art Apple Music player above your desktop icons. Drag it to move it; click the cover to open Music.")
            }
            Section {
                Toggle("Rock and Roll lyrics in the middle of the pond", isOn: store.binding(\.rockLyrics))
                if store.settings.rockLyrics {
                    Picker("Style", selection: style) {
                        Text("Match the song").tag(RockStyle?.none)
                        Section("Calm") {
                            ForEach(RockStyle.styles(for: .standard), id: \.self) { Text($0.title).tag(Optional($0)) }
                        }
                        Section("Wild") {
                            ForEach(RockStyle.styles(for: .exaggerated), id: \.self) { Text($0.title).tag(Optional($0)) }
                        }
                    }
                    LabeledContent("Status", value: lyrics.status)
                }
            } header: {
                Text("Lyrics")
            } footer: {
                Note("The line being sung plays big in the middle of the pond, and the pond dims a little behind it. Matched to the song, a ballad gets the calm styles (Poster Stomp, Rocking Boat) and a hard-hitting song the wild ones (Stage Dive, Mosh Pit), judged by how fast the words come and, while the fish dance, by the beat; the styles change at new parts of the song, wilder in its loud parts. Lyrics are looked up on NetEase Cloud Music and LRCLIB. With Reduce Motion on, they change colour but stay still.")
            }
            Section {
                Toggle("A koi delivers each new song", isOn: store.binding(\.songCard))
            } header: {
                Text("Song changes")
            } footer: {
                Note("When the song changes, a koi smacks a big card of it onto the glass.")
            }
            Section {
                Toggle("Fish dance to the music", isOn: store.binding(\.danceToMusic))
                if store.settings.danceToMusic {
                    Picker("Bounce", selection: store.binding(\.danceBounce)) {
                        ForEach(DanceBounce.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Status", value: beat.status)
                }
            } header: {
                Text("Dance")
            } footer: {
                Note("On every beat the fish bounce, squashing and springing back with a jolt of the head. To find the beat Koi Pond listens to Music's sound only, and records nothing. Turn this off and it never listens at all.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct LockScreenPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var lockScreen: LockScreenInstaller
    @ObservedObject var screenSaver: ScreenSaverInstaller

    var body: some View {
        Form {
            Section {
                Toggle("Show the pond on the lock screen", isOn: store.binding(\.animatedLockScreen))
                if store.settings.animatedLockScreen {
                    LabeledContent("Status", value: lockScreen.statusText)
                    Button("Open Wallpaper Settings…") { LockScreenInstaller.openWallpaperSettings() }
                }
            } header: {
                Text("Lock screen")
            } footer: {
                Note("Records a 3-minute pond video into one of your downloaded Apple aerials (macOS 26 or later). Turning it off puts Apple's video and your wallpaper back.")
            }
            Section {
                Toggle("Use the pond as the screen saver", isOn: store.binding(\.pondScreenSaver))
                if store.settings.pondScreenSaver {
                    LabeledContent("Status", value: screenSaver.status)
                    Button("Open Screen Saver Settings…") { ScreenSaverInstaller.openScreenSaverSettings() }
                }
            } header: {
                Text("Screen saver")
            } footer: {
                Note("Runs the live pond with your settings. Turning it off puts your previous screen saver back.")
            }
        }
        .formStyle(.grouped)
        .onAppear { lockScreen.refreshSelection() }
    }
}

private struct PerformancePane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Frame rate", selection: store.binding(\.frameRate)) {
                    ForEach(FrameRate.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Drawing")
            } footer: {
                Note("The pond is drawn as pixel art, which also keeps it light on battery.")
            }
            Section {
                Picker("On battery", selection: store.binding(\.onBattery)) {
                    ForEach(BatteryMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Pause in Low Power Mode", isOn: store.binding(\.pauseInLowPower))
                DisclosureGroup("Advanced") {
                    Toggle("Pause a display while windows cover it", isOn: store.binding(\.pauseWhenCovered))
                    Text("macOS still reports windows in place while you click the wallpaper to reveal the desktop, so this also freezes the pond you're looking at then.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Battery")
            } footer: {
                Note("The pond always rests while the Mac sleeps or the screen is locked.")
            }
            RestoreDefaults(store: store, group: .performance)
        }
        .formStyle(.grouped)
    }
}

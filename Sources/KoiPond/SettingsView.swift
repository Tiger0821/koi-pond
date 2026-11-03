import AppKit
import KoiPondCore
import ServiceManagement
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?

    func show(store: SettingsStore, lockScreen: LockScreenInstaller, screenSaver: ScreenSaverInstaller, music: MusicPlayer,
              beat: MusicBeat) {
        if window == nil {
            let view = SettingsView(store: store, lockScreen: lockScreen, screenSaver: screenSaver, music: music, beat: beat)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Koi Pond Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let lockScreen: LockScreenInstaller
    let screenSaver: ScreenSaverInstaller
    let music: MusicPlayer
    let beat: MusicBeat

    var body: some View {
        TabView {
            PondTab(store: store).tabItem { Label("Pond", systemImage: "drop.fill") }
            AnimalsTab(store: store).tabItem { Label("Animals", systemImage: "fish.fill") }
            BloomsTab(store: store).tabItem { Label("Blooms", systemImage: "camera.macro") }
            NowPlayingTab(store: store, music: music, beat: beat).tabItem { Label("Now Playing", systemImage: "music.note") }
            PerformanceTab(store: store).tabItem { Label("Performance", systemImage: "gauge.with.dots.needle.33percent") }
            GeneralTab(store: store, lockScreen: lockScreen, screenSaver: screenSaver)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 470)
    }
}

extension SettingsStore {
    func binding<T>(_ keyPath: WritableKeyPath<PondSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    func count(_ keyPath: WritableKeyPath<PondSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(self.settings[keyPath: keyPath]) },
                set: { value in self.update { $0[keyPath: keyPath] = Int(value.rounded()) } })
    }
}

private extension Color {
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
                Text("\(Int((value * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }
}

private struct CountSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: 1)
                Text("\(Int(value))").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }
}

private struct PondTab: View {
    @ObservedObject var store: SettingsStore

    private var waterColor: Binding<Color> {
        Binding(get: { Color(store.settings.waterColor) }, set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            store.update { $0.waterColor = RGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)) }
        })
    }

    var body: some View {
        Form {
            Section("Weather") {
                Picker("Weather", selection: store.binding(\.weather)) {
                    ForEach(WeatherPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Follow Device Time drifts from dawn to moonlight with your clock.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Water") {
                LabeledContent("Color") {
                    HStack(spacing: 8) {
                        ForEach(WaterPreset.allCases, id: \.self) { preset in
                            Button {
                                store.update { $0.waterColor = preset.color }
                            } label: {
                                Circle().fill(Color(preset.color)).frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(.primary.opacity(0.2)))
                            }
                            .buttonStyle(.plain)
                            .help(preset.title)
                        }
                        ColorPicker("", selection: waterColor, supportsOpacity: false).labelsHidden()
                    }
                }
                PercentSlider(title: "Clarity", value: store.binding(\.clarity))
                Toggle("Touch ripples", isOn: store.binding(\.touchRipples))
                Toggle("Feed the fish (click the water to drop food)", isOn: store.binding(\.feedTheFish))
            }
            Section("Currents") {
                Toggle("Currents", isOn: store.binding(\.currentsEnabled))
                PercentSlider(title: "Strength", value: store.binding(\.currentStrength))
                    .disabled(!store.settings.currentsEnabled)
                PercentSlider(title: "Speed", value: store.binding(\.currentSpeed))
                    .disabled(!store.settings.currentsEnabled)
                PercentSlider(title: "Core glow", value: store.binding(\.coreGlow))
            }
        }
        .formStyle(.grouped)
    }
}

private struct AnimalsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Counts") {
                CountSlider(title: "Koi", value: store.count(\.koiCount), range: 0...40)
                CountSlider(title: "Small fish", value: store.count(\.smallFishCount), range: 0...60)
                CountSlider(title: "Turtles", value: store.count(\.turtleCount), range: 0...4)
            }
            Section("Behavior") {
                Picker("Koi behavior", selection: store.binding(\.behavior)) {
                    ForEach(FishBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(store.settings.behavior.summary).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Motion speed") {
                    HStack {
                        Slider(value: store.binding(\.motionSpeed), in: 0.25...2)
                        Text(String(format: "%.2g×", store.settings.motionSpeed)).monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct BloomsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Lily pads") {
                CountSlider(title: "Lily pads", value: store.count(\.lilyPadCount), range: 0...40)
            }
            Section("Flowers") {
                Picker("Style", selection: store.binding(\.flowerStyle)) {
                    ForEach(FlowerStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                CountSlider(title: "Flowers", value: store.count(\.flowerCount), range: 0...15)
                Text("Flowers grow on lily pads, so there are never more flowers than pads.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Underwater plants") {
                CountSlider(title: "Plants", value: store.count(\.plantCount), range: 0...60)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NowPlayingTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var music: MusicPlayer
    @ObservedObject var beat: MusicBeat

    var body: some View {
        Form {
            Section("Apple Music") {
                Toggle("Show what's playing on the desktop", isOn: store.binding(\.nowPlaying))
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
                .disabled(!store.settings.nowPlaying)
                Picker("Size", selection: store.binding(\.nowPlayingSize)) {
                    ForEach(NowPlayingSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!store.settings.nowPlaying)
                if store.settings.nowPlaying {
                    LabeledContent("Status", value: music.status)
                    if music.access == .denied {
                        Button("Open Automation Settings…") { MusicPlayer.openAutomationSettings() }
                    }
                }
                Text("A pixel-art player with the song's cover, title and artist, and previous, play/pause and next buttons. It shows on your main display, above the desktop icons, while Music has a song playing or paused. Drag it by its cover or title to move it: it snaps to the screen's edges and middle, and to a grid elsewhere. The first time, macOS asks whether Koi Pond may control Music.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Song change") {
                Toggle("A koi delivers each new song", isOn: store.binding(\.songCard))
                Text("When the song changes, a koi bursts out of the middle of the pond head-first, smacks into the glass with a big card of the new song, then slides down and drops back in. The card shows the title, then the cover slides in pixelated and sharpens, then the artist; after a few seconds it sinks with a splash. The desktop player changes songs with one of four transitions, picked at random each time. With Reduce Motion on, the flash and shake are left out.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dance") {
                Toggle("Fish dance to the music", isOn: store.binding(\.danceToMusic))
                if store.settings.danceToMusic {
                    LabeledContent("Status", value: beat.status)
                }
                Text("While Music plays, the fish headbang to the beat, squashing and springing back with a jolt of the head, and every half minute or so the whole pond does a disco spin. Koi Pond listens to Music's sound only, measures it and throws it away; nothing is recorded. The first time, macOS asks whether Koi Pond may hear other apps' audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PerformanceTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Rendering") {
                Picker("Quality", selection: store.binding(\.quality)) {
                    ForEach(RenderQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Frame rate", selection: store.binding(\.frameRate)) {
                    ForEach(FrameRate.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Pixel draws a quarter of the pixels Balanced does and is the lightest on battery.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Saving power") {
                Picker("On battery", selection: store.binding(\.onBattery)) {
                    ForEach(BatteryMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Pause in Low Power Mode (otherwise slow down)", isOn: store.binding(\.pauseInLowPower))
                Toggle("Pause a display while app windows cover it", isOn: store.binding(\.pauseWhenCovered))
                Text("The pond always rests while the Mac sleeps or the screen is locked. Pausing behind windows also freezes it while you reveal the desktop by clicking the wallpaper, because macOS still reports the windows in place.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var lockScreen: LockScreenInstaller
    @ObservedObject var screenSaver: ScreenSaverInstaller
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var widgetsHidden = DesktopWidgets.hidden
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Lock screen") {
                Toggle("Animated lock screen", isOn: store.binding(\.animatedLockScreen))
                if store.settings.animatedLockScreen {
                    LabeledContent("Status", value: lockScreen.statusText)
                    Button("Open Wallpaper Settings…") { LockScreenInstaller.openWallpaperSettings() }
                }
                Text("Records a 3-minute pond video into one of your downloaded Apple aerials and makes that aerial your wallpaper on every Space, so it plays on the lock screen, in Mission Control and while switching Spaces. Turning this off puts Apple's video and your previous wallpaper back. Needs macOS 26 or later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Screen saver") {
                Toggle("Pond screen saver", isOn: store.binding(\.pondScreenSaver))
                if store.settings.pondScreenSaver {
                    LabeledContent("Status", value: screenSaver.status)
                    Button("Open Screen Saver Settings…") { ScreenSaverInstaller.openScreenSaverSettings() }
                }
                Text("Runs the live pond, with your settings, as the screen saver on every Space. Turning this off puts your previous screen saver back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Desktop") {
                Toggle("Hide macOS widgets", isOn: Binding(get: { widgetsHidden }, set: { hidden in
                    DesktopWidgets.setHidden(hidden)
                    widgetsHidden = hidden
                }))
                Text("Hides the calendar, weather, clock and other macOS widgets on the desktop so the pond is clear. It's the same switch as System Settings › Desktop & Dock › Show Widgets › On Desktop. Koi Pond's own Now Playing player is under Now Playing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Pond") {
                Toggle("Pause pond", isOn: store.binding(\.paused))
                Button("Reset all settings") { store.update { $0 = PondSettings() } }
            }
            Section("Privacy") {
                Text("Koi Pond needs no Screen Recording, Accessibility or Input Monitoring permission. It reads click positions and window frames only to tell desktop clicks apart. The only thing that leaves your Mac: when Music has no cover for a song, the Now Playing player asks Apple's iTunes Search for it by song and artist name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            lockScreen.refreshSelection()
            widgetsHidden = DesktopWidgets.hidden
        }
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

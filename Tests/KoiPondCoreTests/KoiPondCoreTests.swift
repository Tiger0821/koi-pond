import CoreGraphics
import Foundation
import simd
import XCTest
@testable import KoiPondCore

final class DesktopHitTestTests: XCTestCase {
    let iconLevel = -2_147_483_603
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let ownPID: Int32 = 99

    /// Mirrors a real window list captured on macOS 27: desktop icons, a full-screen event shield,
    /// a Window Server band under the menu bar, a full-screen overlay from another app, widgets,
    /// an app window, and the menu bar.
    var windows: [WindowSnapshot] {
        [
            WindowSnapshot(layer: iconLevel, bounds: screen, ownerPID: 1, ownerName: "Finder"),
            WindowSnapshot(layer: iconLevel, bounds: screen, ownerPID: 2, ownerName: "WindowManager"),
            WindowSnapshot(layer: iconLevel + 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 83), ownerPID: 3, ownerName: "Window Server"),
            WindowSnapshot(layer: iconLevel + 5, bounds: screen, ownerPID: 4, ownerName: "Wax"),
            WindowSnapshot(layer: iconLevel + 2, bounds: CGRect(x: 8, y: 156, width: 360, height: 180), ownerPID: 5, ownerName: "Notification Center"),
            WindowSnapshot(layer: 0, bounds: CGRect(x: 600, y: 200, width: 500, height: 400), ownerPID: 6, ownerName: "Notes"),
            WindowSnapshot(layer: 25, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33), ownerPID: 7, ownerName: "MenuBarAgent"),
            WindowSnapshot(layer: iconLevel + 1, bounds: screen, ownerPID: ownPID, ownerName: "KoiPond"),
            // Left on screen by the Screenshot tool after a capture; clicks pass through it.
            WindowSnapshot(layer: 24, bounds: screen, ownerPID: 8, ownerName: "Screenshot"),
        ]
    }

    func isDesktop(_ x: CGFloat, _ y: CGFloat) -> Bool {
        DesktopHitTest.isDesktop(at: CGPoint(x: x, y: y), windows: windows, ownPID: ownPID, iconLevel: iconLevel,
                                 screens: [screen])
    }

    func testOpenDesktopCountsDespiteShellLayersAndOverlays() {
        XCTAssertTrue(isDesktop(1200, 800))
        XCTAssertTrue(isDesktop(700, 60), "Window Server band below the menu bar should not swallow clicks")
    }

    func testWindowsWidgetsAndMenuBarBlock() {
        XCTAssertFalse(isDesktop(700, 300), "app window")
        XCTAssertFalse(isDesktop(100, 200), "desktop widget")
        XCTAssertFalse(isDesktop(700, 10), "menu bar")
    }

    func testShowDesktopPassesClicksButMaximizedWindowsBlock() {
        let showDesktop = WindowSnapshot(layer: 20, bounds: screen, ownerPID: 9, ownerName: "Dock")
        let maximized = WindowSnapshot(layer: 0, bounds: CGRect(x: 0, y: 32, width: 1512, height: 950), ownerPID: 10, ownerName: "Safari")
        func isDesktop(with window: WindowSnapshot) -> Bool {
            DesktopHitTest.isDesktop(at: CGPoint(x: 1200, y: 800), windows: [window] + windows, ownPID: ownPID,
                                     iconLevel: iconLevel, screens: [screen])
        }
        XCTAssertTrue(isDesktop(with: showDesktop))
        XCTAssertFalse(isDesktop(with: maximized))
    }

    func testCoveredFractionCountsOverlapOnce() {
        let left = WindowSnapshot(layer: 0, bounds: CGRect(x: 0, y: 0, width: 756, height: 982), ownerPID: 1, ownerName: "A")
        let overlap = WindowSnapshot(layer: 0, bounds: CGRect(x: 0, y: 0, width: 756, height: 491), ownerPID: 2, ownerName: "B")
        let menuBar = WindowSnapshot(layer: 25, bounds: screen, ownerPID: 3, ownerName: "MenuBarAgent")
        let fraction = DesktopHitTest.coveredFraction(of: screen, windows: [left, overlap, menuBar], ownPID: ownPID)
        XCTAssertEqual(fraction, 0.5, accuracy: 0.01)
    }
}

final class WeatherTests: XCTestCase {
    func testDeviceTimeFollowsTheDay() {
        XCTAssertEqual(WeatherPreset.look(atHour: 12), WeatherPreset.sunny.fixedLook)
        XCTAssertEqual(WeatherPreset.look(atHour: 18.5), WeatherPreset.sunset.fixedLook)
        XCTAssertEqual(WeatherPreset.look(atHour: 2), WeatherPreset.moonlight.fixedLook)
        let dusk = WeatherPreset.look(atHour: 19.1)
        XCTAssertLessThan(dusk.tint.x, WeatherPreset.sunset.fixedLook!.tint.x)
        XCTAssertGreaterThan(dusk.tint.x, WeatherPreset.twilight.fixedLook!.tint.x)
    }

    func testDayPhaseChangesOnlyAtCycleBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func phase(_ hour: Int, _ minute: Int = 0) -> Int {
            WeatherPreset.dayPhase(at: calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: hour, minute: minute))!,
                                   calendar: calendar)
        }
        XCTAssertEqual(phase(9), phase(16, 59), "one long sunny stretch")
        XCTAssertNotEqual(phase(16, 59), phase(17, 1))
        XCTAssertNotEqual(phase(1, 48), phase(9))
    }
}

final class WallpaperChoicesTests: XCTestCase {
    let image: [String: Any] = {
        let config = try! PropertyListSerialization.data(fromPropertyList: ["type": "imageFile", "url": ["relative": "file:///wax.jpg"]],
                                                         format: .binary, options: 0)
        return ["Provider": "com.apple.wallpaper.choice.image", "Files": [Any](), "Configuration": config]
    }()
    let waxSaver = WallpaperChoices.screenSaver(module: URL(fileURLWithPath: "/Users/me/Library/Screen Savers/Wax.saver"))

    func entry(_ choice: [String: Any]) -> NSMutableDictionary {
        NSMutableDictionary(dictionary: [
            "LastSet": Date(timeIntervalSince1970: 0),
            "Content": NSMutableDictionary(dictionary: ["Choices": NSMutableArray(array: [choice]), "Shuffle": "$null"]),
        ])
    }

    /// The shape of a real store on macOS 27: shared Idle, system defaults, and a Space with a display.
    func makeStore() -> NSMutableDictionary {
        NSMutableDictionary(dictionary: [
            "AllSpacesAndDisplays": NSMutableDictionary(dictionary: ["Type": "idle", "Idle": entry(waxSaver)]),
            "SystemDefault": NSMutableDictionary(dictionary: ["Type": "individual", "Desktop": entry(image), "Idle": entry(waxSaver)]),
            "Spaces": NSMutableDictionary(dictionary: [
                "SPACE-1": NSMutableDictionary(dictionary: [
                    "Default": NSMutableDictionary(dictionary: ["Desktop": entry(image), "Idle": entry(waxSaver)]),
                    "Displays": NSMutableDictionary(dictionary: [
                        "DISPLAY-1": NSMutableDictionary(dictionary: ["Desktop": entry(image), "Idle": entry(waxSaver)]),
                    ]),
                ]),
            ]),
        ])
    }

    func testApplyTouchesEveryDesktopAndNothingElse() {
        let store = makeStore()
        let previous = WallpaperChoices.apply(WallpaperChoices.aerial(assetID: "POND-ID"), to: .desktop, in: store)
        XCTAssertEqual(previous.keys.sorted(), [
            "Spaces/SPACE-1/Default/Desktop", "Spaces/SPACE-1/Displays/DISPLAY-1/Desktop", "SystemDefault/Desktop",
        ])
        XCTAssertTrue(WallpaperChoices.everywhere(.desktop, in: store, contains: "POND-ID"))
        XCTAssertTrue(WallpaperChoices.everywhere(.idle, in: store, contains: "Wax.saver"))
        XCTAssertEqual(WallpaperChoices.entries(.idle, in: store).count, 4)
    }

    func testRestoreLeavesEntriesTheUserChangedSince() {
        let store = makeStore()
        let previous = WallpaperChoices.apply(WallpaperChoices.aerial(assetID: "POND-ID"), to: .desktop, in: store)
        // The user picks another aerial on one display afterwards.
        let display = WallpaperChoices.entries(.desktop, in: store).first { $0.path.contains("DISPLAY-1") }!.entry
        (display["Content"] as! NSMutableDictionary)["Choices"] = [WallpaperChoices.aerial(assetID: "OTHER")]

        let restored = WallpaperChoices.restore(previous, kind: .desktop, marker: "POND-ID", in: store)
        XCTAssertEqual(restored, 2)
        XCTAssertTrue(WallpaperChoices.entries(.desktop, in: store).allSatisfy {
            let first = (($0.entry["Content"] as! NSDictionary)["Choices"] as! [[String: Any]])[0]
            return WallpaperChoices.describe(first).contains($0.path.contains("DISPLAY-1") ? "OTHER" : "wax.jpg")
        })
    }

    func testStoreSurvivesABinaryPlistRoundTrip() throws {
        let store = makeStore()
        _ = WallpaperChoices.apply(WallpaperChoices.screenSaver(module: URL(fileURLWithPath: "/Users/me/Library/Screen Savers/KoiPond.saver")),
                                   to: .idle, in: store)
        let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        let reread = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil) as! NSMutableDictionary
        XCTAssertTrue(WallpaperChoices.everywhere(.idle, in: reread, contains: "Screen%20Savers/KoiPond.saver"))
        XCTAssertTrue(WallpaperChoices.everywhere(.desktop, in: reread, contains: "wax.jpg"))
    }
}

final class SettingsDefaultsTests: XCTestCase {
    func testPondKeepsMovingBehindWindowsByDefault() {
        XCTAssertFalse(PondSettings().pauseWhenCovered)
        XCTAssertFalse(PondSettings().animatedLockScreen)
    }
}

final class SettingsTests: XCTestCase {
    func testMissingKeysKeepDefaults() {
        let stored = #"{"koiCount": 3, "weather": "storm"}"#.data(using: .utf8)
        let settings = PondSettings.load(from: stored)
        XCTAssertEqual(settings.koiCount, 3)
        XCTAssertEqual(settings.weather, .storm)
        XCTAssertEqual(settings.lilyPadCount, PondSettings().lilyPadCount)
    }

    func testUnreadableDataFallsBackToDefaults() {
        XCTAssertEqual(PondSettings.load(from: Data("nope".utf8)), PondSettings())
        XCTAssertEqual(PondSettings.load(from: #"{"weather": "hail"}"#.data(using: .utf8)), PondSettings())
    }
}

final class PondTests: XCTestCase {
    func testConfigureMatchesCounts() {
        let pond = Pond(size: [1512, 982])
        pond.configure(PondConfig(koiCount: 9, smallFishCount: 20, turtleCount: 2, lilyPadCount: 10,
                                  flowerCount: 4, flowerStyle: .mixed, plantCount: 7))
        XCTAssertEqual(pond.koi.count, 9)
        XCTAssertEqual(pond.smallFish.count, 20)
        XCTAssertEqual(pond.turtles.count, 2)
        XCTAssertEqual(pond.pads.count, 10)
        XCTAssertEqual(pond.flowers.count, 4)
        XCTAssertEqual(pond.plants.count, 7)
        pond.configure(PondConfig(koiCount: 3))
        XCTAssertEqual(pond.koi.count, 3)
    }

    func testKoiFindAndEatFood() {
        let pond = Pond(size: [800, 600])
        pond.configure(PondConfig(koiCount: 6, smallFishCount: 0, turtleCount: 0, lilyPadCount: 0, flowerCount: 0, plantCount: 0))
        pond.dropFood(at: [400, 300], count: 6)
        for _ in 0..<(30 * 12) { pond.step(dt: 1 / 30) }
        XCTAssertLessThan(pond.food.count, 6)
    }

    func testAnimalsStayInThePond() {
        let pond = Pond(size: [1000, 700], seed: 3)
        pond.configure(PondConfig(koiCount: 20, smallFishCount: 30, turtleCount: 2))
        pond.behavior = .shy
        pond.cursor = [500, 350]
        for frame in 0..<(30 * 120) {
            if frame % 90 == 0 { pond.touch(at: [Float(frame % 1000), 350]) }
            pond.step(dt: 1 / 30)
        }
        for k in pond.koi {
            XCTAssert(k.pos.x >= -k.length && k.pos.x <= 1000 + k.length && k.pos.y >= -k.length && k.pos.y <= 700 + k.length)
            XCTAssertFalse(k.pos.x.isNaN || k.heading.isNaN)
        }
        for f in pond.smallFish { XCTAssertFalse(f.pos.x.isNaN || f.pos.y.isNaN) }
    }

    func testRainMakesRipples() {
        let pond = Pond(size: [1512, 982])
        pond.rain = 1
        for _ in 0..<30 { pond.step(dt: 1 / 30) }
        XCTAssertGreaterThan(pond.ripples.count, 10)
    }
}

final class BeatDetectorTests: XCTestCase {
    /// A kick drum on every beat at 120 BPM over a steady hi-hat-like hiss.
    func testFindsTheBeatOfAKickDrum() {
        let rate: Float = 48000
        var detector = BeatDetector(sampleRate: rate)
        var rng = SplitMix64(seed: 3)
        let seconds: Float = 10
        for n in 0..<Int(rate * seconds) {
            let t = Float(n) / rate
            let sinceKick = t.truncatingRemainder(dividingBy: 0.5)
            let kick = sin(2 * .pi * 55 * sinceKick) * exp(-sinceKick * 18) * 0.8
            detector.add(kick + rng.float(in: -0.05...0.05))
        }
        XCTAssertEqual(detector.music.beats, 20, accuracy: 2)
        XCTAssertGreaterThan(detector.music.level, 0.1)
    }

    func testSilenceHasNoBeatAndNoLevel() {
        var detector = BeatDetector(sampleRate: 44100)
        for _ in 0..<44100 * 3 { detector.add(0) }
        XCTAssertEqual(detector.music, PondMusic())
    }
}

final class KoiHandlingTests: XCTestCase {
    func testGrabDragAndRelease() {
        let pond = Pond(size: SIMD2(1512, 982), seed: 5)
        pond.configure(PondConfig(koiCount: 3, smallFishCount: 0, turtleCount: 0))
        for _ in 0..<60 { pond.step(dt: 1 / 30) }
        XCTAssertFalse(pond.grab(at: SIMD2(-500, -500)), "nothing to catch off the pond")
        let koi = pond.koi[0]
        XCTAssertTrue(pond.grab(at: koi.pos))
        XCTAssertTrue(pond.isHolding)
        let target = SIMD2<Float>(300, 300)
        pond.drag(to: target)
        for _ in 0..<60 { pond.step(dt: 1 / 30) }
        let held = pond.koi.min { simd_distance($0.pos, target) < simd_distance($1.pos, target) }!
        XCTAssertLessThan(simd_distance(held.pos, target), 10)
        XCTAssertGreaterThan(held.lift, 0.9)
        pond.release()
        XCTAssertFalse(pond.isHolding)
    }

    func testKoiDanceOnlyToMusic() {
        let pond = Pond(size: SIMD2(1512, 982), seed: 6)
        pond.configure(PondConfig(koiCount: 4))
        for _ in 0..<60 { pond.step(dt: 1 / 30) }
        XCTAssertEqual(pond.koi.map(\.dance).max(), 0)
        for beat in 1...6 {
            pond.music = PondMusic(level: 0.9, beats: beat)
            for _ in 0..<15 { pond.step(dt: 1 / 30) }
        }
        XCTAssertGreaterThan(pond.koi.map(\.dance).max() ?? 0, 0.3)
    }
}

final class SnappingTests: XCTestCase {
    let area = CGRect(x: 20, y: 20, width: 1472, height: 900)
    let size = CGSize(width: 330, height: 98)

    func testSnapsToEdgesAndCenterLines() {
        XCTAssertEqual(Snapping.snap(CGPoint(x: 40, y: 830), size: size, area: area), CGPoint(x: 20, y: 822))
        XCTAssertEqual(Snapping.snap(CGPoint(x: 600, y: 440), size: size, area: area).x, 591)
    }

    func testElsewhereLandsOnTheGridAndStaysOnScreen() {
        let p = Snapping.snap(CGPoint(x: 333, y: 205), size: size, area: area)
        XCTAssertEqual((p.x - area.minX).truncatingRemainder(dividingBy: 24), 0)
        XCTAssertEqual((p.y - area.minY).truncatingRemainder(dividingBy: 24), 0)
        XCTAssertEqual(Snapping.snap(CGPoint(x: -500, y: 5000), size: size, area: area), CGPoint(x: 20, y: 822))
    }
}

final class RippleTests: XCTestCase {
    func testRingsSpreadAtTheGroupSpeedOfTheirLongestWaves() {
        var ripple = Ripple(pos: .zero, life: 3, strength: 1, wavenumber: 0.3, bandwidth: 0.4, phase: 0, wobble: 0, seed: 0)
        ripple.age = 1
        let lead: Float = 0.3 * (1 - 1.4 * 0.4)
        XCTAssertEqual(ripple.radius, 0.5 * (Ripple.gravity / lead).squareRoot(), accuracy: 0.01)
        let atOne = ripple.radius
        ripple.age = 2
        XCTAssertEqual(ripple.radius, atOne * 2, accuracy: 0.01, "deep-water groups move at a steady speed")
    }

    func testEverySplashDiffersAndBiggerOnesMakeLongerWaves() {
        let pond = Pond(size: SIMD2(800, 600), seed: 9)
        for _ in 0..<20 { pond.addRipple(at: SIMD2(400, 300), strength: 1) }
        let big = pond.ripples
        XCTAssertGreaterThan(Set(big.map(\.wavenumber)).count, 15)
        XCTAssertGreaterThan(Set(big.map(\.phase)).count, 15)
        for _ in 0..<20 { pond.addRipple(at: SIMD2(400, 300), strength: 0.2) }
        let small = pond.ripples.suffix(20)
        let meanWavelength = { (rs: [Ripple]) in rs.map { 2 * Float.pi / $0.wavenumber }.reduce(0, +) / Float(rs.count) }
        XCTAssertGreaterThan(meanWavelength(Array(big)), meanWavelength(Array(small)) * 1.5)
    }

    func testFeedingClickMakesOneSplash() {
        let pond = Pond(size: SIMD2(800, 600), seed: 2)
        pond.touch(at: SIMD2(400, 300))
        pond.dropFood(at: SIMD2(400, 300), count: 4, ripple: false)
        XCTAssertEqual(pond.ripples.count, 1)
        XCTAssertEqual(pond.food.count, 4)
    }
}

final class RateLimiterTests: XCTestCase {
    func testOnePerIntervalWhateverTheRate() {
        var limit = RateLimiter(interval: 0.05)
        // An auto clicker at 1,000 clicks a second for one second.
        let allowed = (0..<1000).filter { limit.allow(at: Double($0) / 1000) }.count
        XCTAssertEqual(allowed, 20)
        XCTAssertTrue(limit.allow(at: 5))
    }
}

final class BorrowedKoiTests: XCTestCase {
    func testKoiLeavesThePondAndComesBackWithASplash() {
        let pond = Pond(size: SIMD2(1512, 982), seed: 4)
        pond.configure(PondConfig(koiCount: 3, smallFishCount: 0, turtleCount: 0))
        let center = SIMD2<Float>(756, 491)
        guard let borrowed = pond.borrowKoi(near: center) else { return XCTFail("no koi borrowed") }
        XCTAssertEqual(pond.koi.filter(\.away).count, 1)
        XCTAssertNil(pond.borrowKoi(near: center), "one at a time")
        XCTAssertFalse(pond.grab(at: borrowed.position), "an absent koi can't be picked up")
        let still = pond.koi.first(where: \.away)!.pos
        for _ in 0..<30 { pond.step(dt: 1 / 30) }
        XCTAssertEqual(pond.koi.first(where: \.away)!.pos, still, "it doesn't swim while away")
        let ripples = pond.ripples.count
        pond.returnKoi(at: SIMD2(700, 300))
        XCTAssertFalse(pond.hasBorrowedKoi)
        XCTAssertEqual(pond.koi.filter(\.away).count, 0)
        XCTAssertGreaterThan(pond.ripples.count, ripples)
    }
}

final class DanceMovesTests: XCTestCase {
    func testHeadbangEasesInSpringsBackAndSettles() {
        let pond = Pond(size: SIMD2(800, 600), seed: 3)
        pond.configure(PondConfig(koiCount: 2))
        pond.music = PondMusic(level: 1, beats: 1)
        pond.step(dt: 0.01)
        XCTAssertLessThan(pond.bang, 0.05, "no jump on the beat itself")
        var peak: Float = 0, deepest: Float = 0
        for _ in 0..<60 {
            pond.step(dt: 1 / 60)
            peak = max(peak, pond.bang)
            deepest = min(deepest, pond.bang)
        }
        XCTAssertGreaterThan(peak, 0.4, "squashes")
        XCTAssertLessThan(deepest, -0.1, "then stretches as it springs back")
        for _ in 0..<60 { pond.step(dt: 1 / 60) }
        XCTAssertLessThan(abs(pond.bang), 0.02, "and settles")
    }

    func testDiscoSpinAboutTwiceAMinuteNeverBackToBack() {
        let pond = Pond(size: SIMD2(800, 600), seed: 8)
        pond.configure(PondConfig(koiCount: 2))
        var starts: [Float] = [], clock: Float = 0, beats = 0, spinning = false
        // Ten minutes at 120 BPM.
        while clock < 600 {
            if clock >= Float(beats) * 0.5 { beats += 1; pond.music = PondMusic(level: 1, beats: beats) }
            pond.step(dt: 1 / 30)
            clock += 1 / 30
            if pond.spinAge != nil, !spinning { starts.append(clock) }
            spinning = pond.spinAge != nil
        }
        XCTAssertTrue((8...32).contains(starts.count), "\(starts.count) spins in ten minutes")
        XCTAssertGreaterThanOrEqual(zip(starts.dropFirst(), starts).map { $0 - $1 }.min() ?? 99, 12)
        XCTAssertEqual(pond.spinAngle(seed: 1), pond.spinAge == nil ? 0 : pond.spinAngle(seed: 1))
    }

    func testNoSpinInSilence() {
        let pond = Pond(size: SIMD2(800, 600), seed: 8)
        for beat in 1...400 {
            pond.music = PondMusic(level: 0, beats: beat)
            for _ in 0..<15 { pond.step(dt: 1 / 30) }
            XCTAssertNil(pond.spinAge)
        }
    }
}

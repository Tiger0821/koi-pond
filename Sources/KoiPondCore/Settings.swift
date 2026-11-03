import Foundation

public struct RGB: Codable, Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public var simd: SIMD3<Float> { SIMD3(Float(r), Float(g), Float(b)) }
}

public enum WaterPreset: String, CaseIterable, Sendable {
    case jade, deepBlue, moss, clearStream, amber

    public var title: String {
        switch self {
        case .jade: "Jade"
        case .deepBlue: "Deep Blue"
        case .moss: "Moss"
        case .clearStream: "Clear Stream"
        case .amber: "Amber"
        }
    }

    public var color: RGB {
        switch self {
        case .jade: RGB(0.17, 0.43, 0.41)
        case .deepBlue: RGB(0.11, 0.27, 0.43)
        case .moss: RGB(0.22, 0.37, 0.23)
        case .clearStream: RGB(0.31, 0.55, 0.57)
        case .amber: RGB(0.42, 0.36, 0.21)
        }
    }
}

public enum WeatherPreset: String, Codable, CaseIterable, Sendable {
    case followDeviceTime, sunny, crystal, dawn, sunset, twilight, moonlight, rain, storm

    public var title: String {
        switch self {
        case .followDeviceTime: "Follow Device Time"
        case .sunny: "Sunny"
        case .crystal: "Crystal"
        case .dawn: "Dawn"
        case .sunset: "Sunset"
        case .twilight: "Twilight"
        case .moonlight: "Moonlight"
        case .rain: "Rain"
        case .storm: "Storm"
        }
    }
}

public enum RenderQuality: String, Codable, CaseIterable, Sendable {
    case pixel, balanced, smooth

    public var title: String {
        switch self {
        case .pixel: "Pixel"
        case .balanced: "Balanced"
        case .smooth: "Smooth"
        }
    }

    /// How many offscreen texels each screen point gets before upscaling.
    public func texelsPerPoint(backingScale: Float) -> Float {
        switch self {
        case .pixel: 0.5
        case .balanced: 1
        case .smooth: max(backingScale, 1)
        }
    }
}

public enum FrameRate: Int, Codable, CaseIterable, Sendable {
    case fps15 = 15, fps24 = 24, fps30 = 30, fps60 = 60, max = 120

    public var title: String { self == .max ? "Max" : "\(rawValue) fps" }
}

public enum FishBehavior: String, Codable, CaseIterable, Sendable {
    case calm, curious, shy, schooling

    public var title: String {
        switch self {
        case .calm: "Calm"
        case .curious: "Curious"
        case .shy: "Shy"
        case .schooling: "Schooling"
        }
    }

    public var summary: String {
        switch self {
        case .calm: "Slow, wandering koi that rarely react."
        case .curious: "Koi gather under the cursor when it rests on the desktop."
        case .shy: "Koi scatter away from the cursor and clicks."
        case .schooling: "Koi swim together in loose groups."
        }
    }
}

public enum FlowerStyle: String, Codable, CaseIterable, Sendable {
    case lotus, waterLily, mixed

    public var title: String {
        switch self {
        case .lotus: "Lotus"
        case .waterLily: "Water Lily"
        case .mixed: "Mixed"
        }
    }
}

public enum BatteryMode: String, Codable, CaseIterable, Sendable {
    case keepRunning, slowDown, pause

    public var title: String {
        switch self {
        case .keepRunning: "Keep running"
        case .slowDown: "Slow down"
        case .pause: "Pause"
        }
    }
}

public enum ScreenCorner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }

    public var symbol: String {
        switch self {
        case .topLeft: "arrow.up.left"
        case .topRight: "arrow.up.right"
        case .bottomLeft: "arrow.down.left"
        case .bottomRight: "arrow.down.right"
        }
    }

    /// Where the corner is across and up the screen, from 0 to 1.
    public var fraction: (x: Double, y: Double) {
        (self == .topRight || self == .bottomRight ? 1 : 0, self == .topLeft || self == .topRight ? 1 : 0)
    }
}

public enum NowPlayingSize: String, Codable, CaseIterable, Sendable {
    case small, large

    public var title: String { self == .small ? "Small" : "Large" }

    /// Screen points per pixel of the pixel-art player.
    public var pointsPerPixel: Int { self == .small ? 2 : 3 }
}

public struct PondSettings: Codable, Equatable, Sendable {
    public var paused = false
    public var feedTheFish = true
    public var weather: WeatherPreset = .followDeviceTime
    public var waterColor: RGB = WaterPreset.jade.color
    public var clarity = 0.55
    public var touchRipples = true
    public var currentsEnabled = true
    public var currentStrength = 0.4
    public var currentSpeed = 0.4
    public var coreGlow = 0.5

    public var koiCount = 12
    public var smallFishCount = 24
    public var turtleCount = 1
    public var behavior: FishBehavior = .curious
    public var motionSpeed = 1.0

    public var lilyPadCount = 14
    public var flowerStyle: FlowerStyle = .lotus
    public var flowerCount = 5
    public var plantCount = 18

    public var quality: RenderQuality = .pixel
    public var frameRate: FrameRate = .fps30
    public var onBattery: BatteryMode = .slowDown
    public var pauseInLowPower = false
    /// Off by default: macOS reports windows at their old frames while the desktop is revealed,
    /// so resting behind windows would also freeze the pond the user is looking at.
    public var pauseWhenCovered = false
    public var animatedLockScreen = false
    public var pondScreenSaver = false
    /// The pixel-art Apple Music player on the desktop.
    public var nowPlaying = true
    /// Where the player sits on the main display, from 0 (left, bottom) to 1 (right, top) of the room it has.
    public var nowPlayingX = 0.0
    public var nowPlayingY = 0.0
    public var nowPlayingSize: NowPlayingSize = .small
    /// The fish rock to the beat of whatever Music is playing.
    public var danceToMusic = true
    /// When the song changes, a koi charges up out of the pond and smacks a big card of it onto the glass.
    public var songCard = true

    public init() {}

    /// Decodes stored settings on top of the defaults, so keys added in later versions keep their default.
    public static func load(from data: Data?) -> PondSettings {
        let defaults = PondSettings()
        guard let data,
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = try? JSONEncoder().encode(defaults),
              var merged = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else { return defaults }
        merged.merge(stored) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? JSONDecoder().decode(PondSettings.self, from: mergedData)
        else { return defaults }
        return settings
    }
}

import Foundation

/// Lighting and atmosphere for one moment of the pond's day.
public struct WeatherLook: Equatable, Sendable {
    public var tint: SIMD3<Float>
    public var ambient: Float
    public var saturation: Float
    public var caustics: Float
    public var glowColor: SIMD3<Float>
    public var glow: Float
    public var clarityBoost: Float
    public var rain: Float
    public var storm: Float

    public static func mix(_ a: WeatherLook, _ b: WeatherLook, _ t: Float) -> WeatherLook {
        func m(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        func m3(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> SIMD3<Float> { x + (y - x) * t }
        return WeatherLook(
            tint: m3(a.tint, b.tint),
            ambient: m(a.ambient, b.ambient),
            saturation: m(a.saturation, b.saturation),
            caustics: m(a.caustics, b.caustics),
            glowColor: m3(a.glowColor, b.glowColor),
            glow: m(a.glow, b.glow),
            clarityBoost: m(a.clarityBoost, b.clarityBoost),
            rain: m(a.rain, b.rain),
            storm: m(a.storm, b.storm))
    }
}

extension WeatherPreset {
    /// The look for a fixed preset; nil for Follow Device Time.
    public var fixedLook: WeatherLook? {
        switch self {
        case .followDeviceTime:
            nil
        case .sunny:
            WeatherLook(tint: [1.0, 1.0, 0.98], ambient: 0, saturation: 1.0, caustics: 1.0,
                        glowColor: [1.0, 0.97, 0.82], glow: 0.55, clarityBoost: 0, rain: 0, storm: 0)
        case .crystal:
            WeatherLook(tint: [1.0, 1.03, 1.05], ambient: 0.01, saturation: 1.05, caustics: 1.25,
                        glowColor: [0.85, 1.0, 1.0], glow: 0.6, clarityBoost: 0.35, rain: 0, storm: 0)
        case .dawn:
            WeatherLook(tint: [1.22, 0.92, 0.98], ambient: 0, saturation: 0.62, caustics: 0.55,
                        glowColor: [1.0, 0.72, 0.68], glow: 0.6, clarityBoost: 0, rain: 0, storm: 0)
        case .sunset:
            // Washes the water toward sepia before warming it, so teal water reads amber, not olive.
            WeatherLook(tint: [1.35, 0.95, 0.6], ambient: 0.01, saturation: 0.5, caustics: 0.5,
                        glowColor: [1.0, 0.62, 0.3], glow: 0.7, clarityBoost: 0, rain: 0, storm: 0)
        case .twilight:
            WeatherLook(tint: [0.62, 0.6, 0.88], ambient: 0, saturation: 0.8, caustics: 0.15,
                        glowColor: [0.62, 0.5, 0.95], glow: 0.35, clarityBoost: 0, rain: 0, storm: 0)
        case .moonlight:
            WeatherLook(tint: [0.4, 0.5, 0.74], ambient: 0, saturation: 0.65, caustics: 0.18,
                        glowColor: [0.75, 0.85, 1.0], glow: 0.45, clarityBoost: 0, rain: 0, storm: 0)
        case .rain:
            WeatherLook(tint: [0.74, 0.8, 0.82], ambient: 0, saturation: 0.7, caustics: 0.05,
                        glowColor: [0.85, 0.9, 0.95], glow: 0.15, clarityBoost: -0.1, rain: 0.45, storm: 0)
        case .storm:
            WeatherLook(tint: [0.5, 0.56, 0.62], ambient: 0, saturation: 0.55, caustics: 0,
                        glowColor: [0.7, 0.75, 0.85], glow: 0.1, clarityBoost: -0.2, rain: 1, storm: 1)
        }
    }

    public func look(at date: Date, calendar: Calendar = .current) -> WeatherLook {
        if let fixedLook { return fixedLook }
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
        return Self.look(atHour: hour)
    }

    static let dayCycle: [(hour: Double, preset: WeatherPreset)] = [
        (0, .moonlight), (4.5, .moonlight), (6, .dawn), (7.5, .sunny), (17, .sunny),
        (18.5, .sunset), (19.75, .twilight), (21, .moonlight), (24, .moonlight),
    ]

    /// Which stretch of the day cycle a date falls in, so cached renders know when the light has changed.
    public static func dayPhase(at date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        return dayCycle.indices.last { dayCycle[$0].hour <= hour } ?? 0
    }

    /// Blends between neighbouring presets so the pond drifts from dawn to moonlight over the day.
    public static func look(atHour hour: Double) -> WeatherLook {
        var h = hour.truncatingRemainder(dividingBy: 24)
        if h < 0 { h += 24 }
        for (a, b) in zip(dayCycle, dayCycle.dropFirst()) where h >= a.hour && h <= b.hour {
            let t = (h - a.hour) / (b.hour - a.hour)
            let eased = t * t * (3 - 2 * t)
            return .mix(a.preset.fixedLook!, b.preset.fixedLook!, Float(eased))
        }
        return WeatherPreset.moonlight.fixedLook!
    }
}

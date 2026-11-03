import Foundation

private let white = SIMD3<Float>(0.96, 0.94, 0.9)
private let red = SIMD3<Float>(0.86, 0.2, 0.12)
private let ink = SIMD3<Float>(0.1, 0.1, 0.12)

public enum KoiVariety: Int, CaseIterable, Sendable {
    case kohaku, sanke, showa, tancho, ogon, asagi, kigoi, chagoi, shiroUtsuri, benigoi

    public struct Look: Sendable {
        public var base: SIMD3<Float>
        public var patch: SIMD3<Float>
        public var accent: SIMD3<Float>
        /// Noise value above which the patch color shows; above 1 means no patches.
        public var patchThreshold: Float
        public var accentThreshold: Float
        /// Pattern handled in the shader: 1 tancho crown, 2 metallic sheen, 3 asagi flanks, 4 back stripe.
        public var special: Float
    }

    public var look: Look {
        switch self {
        case .kohaku: Look(base: white, patch: red, accent: ink, patchThreshold: 0.5, accentThreshold: 2, special: 0)
        case .sanke: Look(base: white, patch: red, accent: ink, patchThreshold: 0.52, accentThreshold: 0.66, special: 0)
        case .showa: Look(base: ink, patch: red, accent: white, patchThreshold: 0.47, accentThreshold: 0.6, special: 0)
        case .tancho: Look(base: white, patch: red, accent: ink, patchThreshold: 2, accentThreshold: 2, special: 1)
        case .ogon: Look(base: [0.98, 0.78, 0.3], patch: [0.98, 0.78, 0.3], accent: ink, patchThreshold: 2, accentThreshold: 2, special: 2)
        case .asagi: Look(base: [0.48, 0.58, 0.66], patch: [0.92, 0.48, 0.22], accent: ink, patchThreshold: 2, accentThreshold: 2, special: 3)
        case .kigoi: Look(base: [0.98, 0.86, 0.4], patch: white, accent: ink, patchThreshold: 2, accentThreshold: 2, special: 0)
        case .chagoi: Look(base: [0.62, 0.44, 0.27], patch: white, accent: ink, patchThreshold: 2, accentThreshold: 2, special: 0)
        case .shiroUtsuri: Look(base: ink, patch: white, accent: ink, patchThreshold: 0.44, accentThreshold: 2, special: 0)
        case .benigoi: Look(base: [0.92, 0.36, 0.16], patch: white, accent: ink, patchThreshold: 2, accentThreshold: 2, special: 0)
        }
    }

    public static func random<G: RandomNumberGenerator>(using rng: inout G) -> KoiVariety {
        let weights: [(KoiVariety, Float)] = [
            (.kohaku, 5), (.sanke, 4), (.showa, 3), (.tancho, 1.5), (.ogon, 1.5),
            (.asagi, 1), (.kigoi, 1), (.chagoi, 1), (.shiroUtsuri, 1.5), (.benigoi, 1),
        ]
        var r = Float.random(in: 0..<weights.reduce(0) { $0 + $1.1 }, using: &rng)
        for (variety, weight) in weights {
            if r < weight { return variety }
            r -= weight
        }
        return .kohaku
    }
}

public struct Koi: Sendable {
    public var pos: SIMD2<Float>
    public var heading: Float
    public var speed: Float
    public var turnRate: Float = 0
    public var length: Float
    public var variety: KoiVariety
    public var seed: Float
    public var phase: Float
    /// 0 at the surface, 1 at the pond floor.
    public var depth: Float
    var targetDepth: Float
    var depthTimer: Float
    var wanderTarget: SIMD2<Float>
    var wanderTimer: Float
    var startle: Float = 0
    var fleeDir = SIMD2<Float>(1, 0)
    /// 0…1: how hard it's moving to the music right now.
    public var dance: Float = 0
    /// 0…1: lifted towards the surface while held by the cursor.
    public var lift: Float = 0
    /// Out of the pond for a while (charging the viewer), so neither drawn nor moved.
    public var away = false
}

public struct SmallFish: Sendable {
    public var pos: SIMD2<Float>
    public var vel: SIMD2<Float>
    public var heading: Float = 0
    public var turnRate: Float = 0
    public var phase: Float
    public var seed: Float
    public var school: Int
    public var length: Float
    public var golden: Bool
    var startle: Float = 0
    var fleeDir = SIMD2<Float>.zero
}

public struct Turtle: Sendable {
    public var pos: SIMD2<Float>
    public var heading: Float
    public var speed: Float = 0
    public var turnRate: Float = 0
    public var phase: Float = 0
    public var depth: Float = 0.3
    public var length: Float
    public var seed: Float
    var targetDepth: Float = 0.3
    var target: SIMD2<Float>
    var timer: Float
    var resting: Float = 0
    var startle: Float = 0
    var fleeDir = SIMD2<Float>.zero
}

public struct Food: Sendable {
    public var pos: SIMD2<Float>
    public var age: Float
    /// 0 while floating, rising to 1 as it sinks away.
    public var sink: Float = 0
}

/// The rings from a splash, as linear deep-water wave theory has them: the splash puts its energy into a
/// band of wavelengths, each travels outwards at its own group speed ½√(g/k), so the longest waves lead,
/// the group spreads, and rings multiply and weaken as it goes. The shader draws the stationary-phase
/// solution; this holds what makes each splash its own.
public struct Ripple: Sendable {
    public var pos: SIMD2<Float>
    public var age: Float = 0
    public var life: Float
    /// 0…1: how hard the water was hit.
    public var strength: Float
    /// The wavenumber (radians per point) carrying most of the energy: bigger splashes make longer waves.
    public var wavenumber: Float
    /// How widely the energy spreads around `wavenumber`, as a fraction of it; wider makes more rings.
    public var bandwidth: Float
    /// Where the crests start, in radians.
    public var phase: Float
    /// How far the rings stray from round, as a fraction of their radius.
    public var wobble: Float
    public var seed: Float

    /// Gravity in points per second², taking a point as 3 mm of pond (9.81 m/s²).
    public static let gravity: Float = 3270

    /// The leading edge of the rings: the longest waves with real energy, at their group speed.
    public var radius: Float {
        let longest = wavenumber * max(0.2, 1 - 1.4 * bandwidth)
        return age * 0.5 * (Self.gravity / longest).squareRoot()
    }
}

public struct LilyPad: Sendable {
    public var pos: SIMD2<Float>
    public var radius: Float
    public var rotation: Float
    /// Half-angle of the notch cut into the pad.
    public var notch: Float
    public var seed: Float
    public var bobPhase: Float
    public var yellowing: Float
}

public struct Flower: Sendable {
    public var pad: Int
    public var offset: SIMD2<Float>
    public var radius: Float
    public var petals: Float
    public var isWaterLily: Bool
    public var seed: Float
}

public struct Plant: Sendable {
    public var pos: SIMD2<Float>
    public var size: Float
    public var seed: Float
}

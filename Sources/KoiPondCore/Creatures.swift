import Foundation

private let white = SIMD3<Float>(0.96, 0.94, 0.9)
private let red = SIMD3<Float>(0.86, 0.2, 0.12)
private let ink = SIMD3<Float>(0.1, 0.1, 0.12)
private let gold = SIMD3<Float>(1.0, 0.73, 0.16)
private let lemon = SIMD3<Float>(1.0, 0.93, 0.38)
private let platinum = SIMD3<Float>(0.9, 0.92, 0.94)

public enum KoiVariety: Int, CaseIterable, Sendable {
    case kohaku, sanke, showa, tancho, ogon, asagi, kigoi, chagoi, shiroUtsuri, benigoi

    public struct Look: Sendable {
        public var base: SIMD3<Float>
        public var patch: SIMD3<Float>
        public var accent: SIMD3<Float>
        /// Noise value above which the patch color shows; above 1 means no patches.
        public var patchThreshold: Float
        public var accentThreshold: Float
        /// Pattern handled in the shader: 1 tancho crown, 3 asagi (net scales, red cheeks and flanks), 4 back stripe.
        public var special: Float
        /// 0…1: a metallic shine, highlight and glinting scales, as on an Ogon.
        public var metallic: Float = 0
        public var fins: Fins = .plain
        /// Red eyes, as on an Akame Kigoi.
        public var redEyes = false
        /// Where the red plates go.
        public var pattern: Pattern = .noise
        /// What the scales look like.
        public var scales: Scales = .plain
        /// Red on the lips (kuchibeni).
        public var lips = false
        /// Patches with soft, graded ink edges, as a sumi-e brush leaves them.
        public var inkWash = false

        func with(_ change: (inout Look) -> Void) -> Look {
            var copy = self
            change(&copy)
            return copy
        }
    }

    /// The shape of the red pattern, by its show name.
    public enum Pattern: Float, Sendable {
        /// Free-form plates with a red head, white nose and white before the tail.
        case noise = 0
        /// One red band zigzagging like lightning from head to tail (inazuma).
        case lightning = 1
        /// Three separate plates (sandan).
        case steps = 2
        /// A round red crown plus separate plates on the body (maruten).
        case crownAndSteps = 3
        /// Black and white swirling like clouds, black on the head too (Kumonryu).
        case clouds = 4
        /// Red on single scales, like a fawn's dapples (kanoko).
        case dapples = 5
        /// Round black spots scattered over the back (Bekko).
        case spots = 6
    }

    /// The scale finish.
    public enum Scales: Float, Sendable {
        case plain = 0
        /// Rows of scales with a light rim on each and plate edges that follow them (fukurin, kiwa).
        case outlined = 1
        /// Sparkling mirror-like scales along the back (gin-rin).
        case sparkling = 2
        /// Scaleless skin with one row of big mirror scales beside the spine (doitsu).
        case mirror = 3
        /// Indigo edges on the red scales (koromo).
        case robed = 4
        /// A dark centre on every scale, like a pine cone (matsuba).
        case pineCone = 5
        /// A blue-grey net (Goshiki, Ochiba).
        case net = 6
    }

    /// How the pectoral fins are marked, the way judges look for them.
    public enum Fins: Float, Sendable {
        case plain = 0
        /// Black at the root (motoguro), as on Showa and Utsuri.
        case blackRoots = 1
        /// Black stripes through the rays (tejima), as on Sanke.
        case blackStripes = 2
        /// Red at the root (moto-aka), as on Asagi.
        case redRoots = 3
    }

    /// Every design a koi of this variety can wear, by its show name. A pond deals them out in turn, so koi of
    /// one variety look different from each other. No design is a single flat colour: one-coloured koi are
    /// judged on their scales, so each has a scale finish or a patterned cousin.
    public var designs: [Look] {
        let kohaku = Look(base: white, patch: red, accent: ink, patchThreshold: 0.5, accentThreshold: 2, special: 0)
        let sanke = Look(base: white, patch: red, accent: ink, patchThreshold: 0.52, accentThreshold: 0.66, special: 0,
                         fins: .blackStripes)
        let showa = Look(base: ink, patch: red, accent: white, patchThreshold: 0.47, accentThreshold: 0.6, special: 0,
                         fins: .blackRoots)
        // Yamabuki Ogon: deep metallic gold.
        let ogon = Look(base: gold, patch: gold, accent: ink, patchThreshold: 2, accentThreshold: 2, special: 0, metallic: 1)
        // A matte lemon Kigoi with red eyes (Akame Kigoi).
        let kigoi = Look(base: lemon, patch: white, accent: ink, patchThreshold: 2, accentThreshold: 2, special: 0,
                         redEyes: true)
        let chagoi = Look(base: [0.62, 0.44, 0.27], patch: white, accent: ink, patchThreshold: 2, accentThreshold: 2, special: 0)
        let benigoi = Look(base: [0.92, 0.36, 0.16], patch: white, accent: ink, patchThreshold: 2, accentThreshold: 2,
                           special: 0)
        switch self {
        case .kohaku: return [
                kohaku,
                kohaku.with { $0.pattern = .lightning; $0.scales = .outlined },               // Inazuma
                kohaku.with { $0.pattern = .steps; $0.lips = true; $0.scales = .outlined },   // Sandan with kuchibeni
                kohaku.with { $0.pattern = .dapples; $0.patchThreshold = 0.42 },              // Kanoko
                kohaku.with { $0.scales = .robed; $0.patchThreshold = 0.46 },                 // Ai-goromo
                kohaku.with { $0.base = [0.8, 0.84, 0.88]; $0.pattern = .steps; $0.scales = .net },   // Goshiki
                kohaku.with { $0.scales = .outlined },                                        // Fukurin
            ]
        case .sanke: return [sanke, sanke.with { $0.pattern = .crownAndSteps; $0.scales = .outlined }]   // Maruten Sanke
        case .showa: return [showa, showa.with { $0.inkWash = true }]                                    // Sumi-e
        case .tancho: return [Look(base: white, patch: red, accent: ink, patchThreshold: 2, accentThreshold: 2, special: 1)]
        case .ogon: return [
                ogon.with { $0.scales = .outlined },                                          // Fukurin
                ogon.with { $0.scales = .pineCone },                                          // Ki Matsuba
                ogon.with { $0.accentThreshold = 0.46; $0.pattern = .clouds; $0.scales = .mirror },   // Kin Kikokuryu
                ogon.with { $0.base = platinum; $0.patchThreshold = 0.5; $0.scales = .outlined },     // Hariwake
            ]
        case .asagi: return [Look(base: [0.48, 0.58, 0.66], patch: [0.92, 0.48, 0.22], accent: ink, patchThreshold: 2,
                                  accentThreshold: 2, special: 3, fins: .redRoots)]
        case .kigoi: return [
                kigoi.with { $0.scales = .net },
                kigoi.with { $0.scales = .sparkling },                                        // Gin-rin
                kigoi.with { $0.pattern = .spots; $0.fins = .blackStripes },                  // Ki Bekko
                kigoi.with {                                                                  // Ki Utsuri
                    $0.base = ink; $0.patch = [1.0, 0.9, 0.36]; $0.patchThreshold = 0.44; $0.fins = .blackRoots
                    $0.redEyes = false
                },
            ]
        case .chagoi: return [
                chagoi.with { $0.scales = .net },
                chagoi.with { $0.scales = .sparkling },                                       // Gin-rin
                chagoi.with {                                                                 // Ochiba Shigure
                    $0.base = [0.6, 0.67, 0.74]; $0.patch = [0.7, 0.45, 0.25]; $0.patchThreshold = 0.5; $0.scales = .net
                },
                chagoi.with { $0.scales = .mirror },                                          // Doitsu
            ]
        case .shiroUtsuri: return [Look(base: ink, patch: white, accent: ink, patchThreshold: 0.44, accentThreshold: 2,
                                        special: 0, fins: .blackRoots)]
        case .benigoi: return [
                benigoi.with { $0.scales = .pineCone },                                       // Aka Matsuba
                benigoi.with { $0.scales = .sparkling },                                      // Gin-rin
                benigoi.with {                                                                // Beni Kumonryu
                    $0.base = [0.95, 0.94, 0.92]; $0.patch = red; $0.patchThreshold = 0.5; $0.accentThreshold = 0.56
                    $0.pattern = .clouds; $0.scales = .mirror
                },
            ]
        }
    }

    /// The variety's first design, for where no particular fish is meant.
    public var look: Look { designs[0] }

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
    /// Which of its variety's designs it wears.
    public var design = 0
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

    public var look: KoiVariety.Look {
        let designs = variety.designs
        return designs[design % designs.count]
    }
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

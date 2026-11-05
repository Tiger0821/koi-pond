import Foundation
import simd

public struct PondConfig: Equatable, Sendable {
    public var koiCount: Int
    public var smallFishCount: Int
    public var turtleCount: Int
    public var lilyPadCount: Int
    public var flowerCount: Int
    public var flowerStyle: FlowerStyle
    public var plantCount: Int

    public init(koiCount: Int = 12, smallFishCount: Int = 24, turtleCount: Int = 1, lilyPadCount: Int = 14,
                flowerCount: Int = 5, flowerStyle: FlowerStyle = .lotus, plantCount: Int = 18) {
        self.koiCount = koiCount
        self.smallFishCount = smallFishCount
        self.turtleCount = turtleCount
        self.lilyPadCount = lilyPadCount
        self.flowerCount = flowerCount
        self.flowerStyle = flowerStyle
        self.plantCount = plantCount
    }

    public init(_ settings: PondSettings) {
        self.init(koiCount: settings.koiCount, smallFishCount: settings.smallFishCount,
                  turtleCount: settings.turtleCount, lilyPadCount: settings.lilyPadCount,
                  flowerCount: settings.flowerCount, flowerStyle: settings.flowerStyle,
                  plantCount: settings.plantCount)
    }
}

/// The pond simulation for one screen. Coordinates are points with the origin at the bottom left.
public final class Pond {
    public private(set) var size: SIMD2<Float>
    public private(set) var koi: [Koi] = []
    public private(set) var smallFish: [SmallFish] = []
    public private(set) var turtles: [Turtle] = []
    public private(set) var food: [Food] = []
    public private(set) var ripples: [Ripple] = []
    public private(set) var pads: [LilyPad] = []
    public private(set) var flowers: [Flower] = []
    public private(set) var plants: [Plant] = []
    public private(set) var time: Float = 0
    public private(set) var flowTime: Float = 0

    public var behavior: FishBehavior = .curious
    public var currentsEnabled = true
    public var currentStrength: Float = 0.4
    public var currentSpeed: Float = 0.4
    public var rain: Float = 0
    /// Cursor position while it rests over exposed desktop on this screen.
    public var cursor: SIMD2<Float>?
    /// What the music is doing; the fish rock to its beat.
    public var music = PondMusic()
    public var isHolding: Bool { held != nil }

    public static let maxFood = 120
    public static let maxRipples = 48

    private var rng: SplitMix64
    private let layoutSeed: UInt64
    private var config = PondConfig(koiCount: 0, smallFishCount: 0, turtleCount: 0, lilyPadCount: 0,
                                    flowerCount: 0, plantCount: 0)
    private var schoolTargets: [SIMD2<Float>] = []
    private var schoolTimers: [Float] = []
    private var rainBudget: Float = 0
    private var lastBeats = 0
    /// Seconds since the last beat.
    private var sinceBeat: Float = 10
    /// The headbang on the beat: positive squashes the fish short and fat, negative stretches it as it
    /// springs back. Scaled by how loud the song is; 0 in silence.
    public private(set) var bang: Float = 0
    /// Seconds into a disco spin, while one is running; about one every 30 seconds of dancing.
    public private(set) var spinAge: Float?
    private var sinceSpin: Float = 0
    public static let spinLength: Float = 0.7
    /// Scales the headbang: 0.5 gentle, 1 normal, 1.7 wild.
    public var danceStrength: Float = 1
    /// Whether the pond does its disco spins.
    public var discoSpins = true
    /// Flips every beat, so the head jolts one way and then the other.
    public private(set) var beatSide: Float = 1
    /// The koi held by the cursor, where the cursor is, and how fast the koi is being moved.
    private var held: (index: Int, target: SIMD2<Float>, velocity: SIMD2<Float>)?
    /// The koi off charging the viewer (see `borrowKoi`), hidden from the pond until it's returned.
    private var borrowed: Int?
    public var hasBorrowedKoi: Bool { borrowed != nil }

    public init(size: SIMD2<Float>, seed: UInt64 = 7) {
        self.size = SIMD2(max(size.x, 64), max(size.y, 64))
        rng = SplitMix64(seed: seed)
        layoutSeed = seed &* 31 &+ 17
    }

    // MARK: Configuration

    public func configure(_ c: PondConfig) {
        let old = config
        config = c
        while koi.count < c.koiCount { koi.append(makeKoi()) }
        if koi.count > c.koiCount { koi.removeLast(koi.count - c.koiCount) }
        if let held, held.index >= koi.count { self.held = nil }
        if let borrowed, borrowed >= koi.count { self.borrowed = nil }
        while turtles.count < c.turtleCount { turtles.append(makeTurtle()) }
        if turtles.count > c.turtleCount { turtles.removeLast(turtles.count - c.turtleCount) }
        if c.smallFishCount != old.smallFishCount { rebuildSmallFish(c.smallFishCount) }
        if c.lilyPadCount != old.lilyPadCount || c.flowerCount != old.flowerCount || c.flowerStyle != old.flowerStyle {
            layoutBlooms()
        }
        if c.plantCount != old.plantCount { layoutPlants() }
    }

    public func resize(to newSize: SIMD2<Float>) {
        let s = SIMD2(max(newSize.x, 64), max(newSize.y, 64))
        guard s != size else { return }
        let ratio = s / size
        size = s
        for i in koi.indices {
            koi[i].pos *= ratio
            koi[i].wanderTarget *= ratio
        }
        for i in smallFish.indices { smallFish[i].pos *= ratio }
        for i in turtles.indices {
            turtles[i].pos *= ratio
            turtles[i].target *= ratio
        }
        for i in food.indices { food[i].pos *= ratio }
        for i in ripples.indices { ripples[i].pos *= ratio }
        for i in schoolTargets.indices { schoolTargets[i] *= ratio }
        layoutBlooms()
        layoutPlants()
    }

    private func makeKoi() -> Koi {
        let length = rng.chance(0.2) ? rng.float(in: 100...124) : rng.float(in: 68...100)
        return Koi(pos: randomPoint(margin: 80), heading: rng.float(in: -Float.pi...Float.pi), speed: 20,
                   length: length, variety: KoiVariety.random(using: &rng), seed: rng.float(in: 0...100),
                   phase: rng.float(in: 0...(2 * .pi)), depth: rng.float(in: 0.1...0.6),
                   targetDepth: rng.float(in: 0.1...0.6), depthTimer: rng.float(in: 4...16),
                   wanderTarget: randomPoint(margin: 90), wanderTimer: rng.float(in: 2...10))
    }

    private func makeTurtle() -> Turtle {
        Turtle(pos: randomPoint(margin: 100), heading: rng.float(in: -Float.pi...Float.pi),
               length: rng.float(in: 76...96), seed: rng.float(in: 0...100),
               target: randomPoint(margin: 100), timer: rng.float(in: 10...20))
    }

    private func rebuildSmallFish(_ count: Int) {
        let schools = count == 0 ? 0 : max(1, Int((Float(count) / 14).rounded()))
        schoolTargets = (0..<schools).map { _ in randomPoint(margin: 120) }
        schoolTimers = (0..<schools).map { _ in rng.float(in: 5...12) }
        smallFish = (0..<count).map { i in
            let school = i % schools
            return SmallFish(pos: schoolTargets[school] + SIMD2(rng.float(in: -40...40), rng.float(in: -40...40)),
                             vel: SIMD2(rng.float(in: -30...30), rng.float(in: -30...30)),
                             phase: rng.float(in: 0...(2 * .pi)), seed: rng.float(in: 0...100), school: school,
                             length: rng.float(in: 16...23), golden: school % 2 == 1)
        }
    }

    /// Lily pads cluster toward the banks, like the reference ponds, and repeat for the same seed.
    private func layoutBlooms() {
        var r = SplitMix64(seed: layoutSeed &+ 101)
        let minDim = min(size.x, size.y)
        pads = []
        var attempts = 0
        while pads.count < config.lilyPadCount && attempts < config.lilyPadCount * 400 {
            attempts += 1
            let p = SIMD2(r.float(in: 0...size.x), r.float(in: 0...size.y))
            let edge = min(p.x, p.y, size.x - p.x, size.y - p.y)
            guard r.float(in: 0...1) < exp(-edge / (0.16 * minDim)) + 0.08 else { continue }
            let radius = r.float(in: 24...46)
            guard !pads.contains(where: { simd_distance($0.pos, p) < ($0.radius + radius) * 0.92 }) else { continue }
            pads.append(LilyPad(pos: p, radius: radius, rotation: r.float(in: 0...(2 * .pi)),
                                notch: r.float(in: 0.16...0.3), seed: r.float(in: 0...100),
                                bobPhase: r.float(in: 0...(2 * .pi)),
                                yellowing: r.chance(0.2) ? r.float(in: 0.2...0.5) : 0))
        }

        flowers = []
        var order = Array(pads.indices)
        order.shuffle(using: &r)
        for (n, i) in order.prefix(config.flowerCount).enumerated() {
            let pad = pads[i]
            let lily: Bool = switch config.flowerStyle {
            case .lotus: false
            case .waterLily: true
            case .mixed: n % 2 == 1
            }
            let a = r.float(in: 0...(2 * .pi))
            flowers.append(Flower(pad: i, offset: SIMD2(cos(a), sin(a)) * pad.radius * r.float(in: 0...0.25),
                                  radius: pad.radius * r.float(in: 0.55...0.72), petals: lily ? 12 : 8,
                                  isWaterLily: lily, seed: r.float(in: 0...100)))
        }
    }

    private func layoutPlants() {
        var r = SplitMix64(seed: layoutSeed &+ 202)
        plants = (0..<config.plantCount).map { _ in
            Plant(pos: SIMD2(r.float(in: 0...size.x), r.float(in: 0...size.y)),
                  size: r.float(in: 14...26), seed: r.float(in: 0...100))
        }
    }

    // MARK: Interaction

    /// A splash. No two are alike: the main wavelength follows the strength (a bigger splash, longer waves)
    /// give or take a fifth, and the band of wavelengths, the crests' starting phase, the rings' roundness,
    /// the strength and the lifetime all vary a little.
    public func addRipple(at p: SIMD2<Float>, strength: Float = 1, life: Float = 2.4) {
        if ripples.count >= Self.maxRipples { ripples.removeFirst() }
        let wavelength = (9 + 11 * strength) * rng.float(in: 0.8...1.25)
        ripples.append(Ripple(pos: p, life: life * rng.float(in: 0.85...1.2), strength: strength * rng.float(in: 0.8...1.15),
                              wavenumber: 2 * .pi / wavelength, bandwidth: rng.float(in: 0.3...0.5),
                              phase: rng.float(in: 0...(2 * .pi)), wobble: rng.float(in: 0.02...0.06),
                              seed: rng.float(in: 0...1)))
    }

    /// A click on the water: a ripple, and nearby animals react according to the behavior mode.
    public func touch(at p: SIMD2<Float>, ripple: Bool = true) {
        if ripple { addRipple(at: p, strength: 1, life: 3.2) }
        let scare: Float = switch behavior {
        case .shy: 1
        case .schooling: 0.8
        case .calm: 0.55
        case .curious: 0.35
        }
        for i in koi.indices {
            let away = koi[i].pos - p
            let d = simd_length(away)
            if d < 150 {
                koi[i].startle = max(koi[i].startle, (1 - d / 150) * scare)
                koi[i].fleeDir = safeNormalize(away)
            }
        }
        for i in smallFish.indices {
            let away = smallFish[i].pos - p
            if simd_length(away) < 130 {
                smallFish[i].startle = 1
                smallFish[i].fleeDir = safeNormalize(away)
            }
        }
        for i in turtles.indices {
            let away = turtles[i].pos - p
            if simd_length(away) < 120 {
                turtles[i].startle = 1
                turtles[i].fleeDir = safeNormalize(away)
                turtles[i].targetDepth = 0.65
                turtles[i].resting = 0
            }
        }
    }

    /// Picks up the koi under `p` (the nearest, if several overlap). Returns whether one was caught.
    @discardableResult
    public func grab(at p: SIMD2<Float>) -> Bool {
        var best: (index: Int, distance: Float)?
        for (i, k) in koi.enumerated() where !k.away {
            let forward = SIMD2(cos(k.heading), sin(k.heading))
            let d = distance(from: p, toSegment: k.pos - forward * k.length * 0.5, k.pos + forward * k.length * 0.42)
            if d < max(14, k.length * 0.2), d < best?.distance ?? .infinity { best = (i, d) }
        }
        guard let best else { return false }
        held = (best.index, p, .zero)
        koi[best.index].startle = 0
        addRipple(at: p, strength: 0.5, life: 1.2)
        return true
    }

    /// Moves the held koi towards `p`.
    public func drag(to p: SIMD2<Float>) {
        held?.target = p
    }

    /// Lets go of the held koi, which swims off the way it was dragged.
    public func release() {
        defer { held = nil }
        guard let held, held.index < koi.count else { return }
        let i = held.index
        let speed = simd_length(held.velocity)
        if speed > 30 { koi[i].heading = atan2(held.velocity.y, held.velocity.x) }
        koi[i].speed = min(max(speed * 0.6, 40), 160)
        koi[i].startle = 0.5
        koi[i].fleeDir = SIMD2(cos(koi[i].heading), sin(koi[i].heading))
        koi[i].wanderTimer = 0
        addRipple(at: koi[i].pos, strength: 0.8, life: 1.6)
    }

    /// Takes the koi nearest `point` out of the pond with a splash: it's off charging the viewer, drawn
    /// elsewhere. Returns where it left the water and its variety, or nil when no koi is free.
    public func borrowKoi(near point: SIMD2<Float>) -> (position: SIMD2<Float>, variety: KoiVariety)? {
        let free = koi.indices.filter { held?.index != $0 }
        guard borrowed == nil, let i = free.min(by: { simd_distance(koi[$0].pos, point) < simd_distance(koi[$1].pos, point) })
        else { return nil }
        borrowed = i
        koi[i].away = true
        splash(at: koi[i].pos, strength: 1.4, drops: 5)
        return (koi[i].pos, koi[i].variety)
    }

    /// The borrowed koi falls back into the pond at `point` with a big splash and dives, a little dazed.
    public func returnKoi(at point: SIMD2<Float>) {
        guard let i = borrowed else { return }
        borrowed = nil
        guard i < koi.count else { return }
        let a = rng.float(in: 0...(2 * .pi))
        koi[i].away = false
        koi[i].pos = clampToPond(point, slack: 0)
        koi[i].heading = a
        koi[i].depth = 0.6
        koi[i].speed = 80
        koi[i].startle = 0.5
        koi[i].fleeDir = SIMD2(cos(a), sin(a))
        koi[i].wanderTimer = 0
        splash(at: koi[i].pos, strength: 1.7, drops: 7)
    }

    /// Scatters food around `p`. `ripple` adds the splash of it landing; leave it off when the click
    /// that dropped it has already made one.
    public func dropFood(at p: SIMD2<Float>, count: Int = 4, ripple: Bool = true) {
        for _ in 0..<count {
            let a = rng.float(in: 0...(2 * .pi))
            let r = rng.float(in: 0...16)
            if food.count >= Self.maxFood { food.removeFirst() }
            food.append(Food(pos: p + SIMD2(cos(a), sin(a)) * r, age: rng.float(in: 0...0.4)))
        }
        if ripple { addRipple(at: p, strength: 0.45, life: 1.4) }
    }

    // MARK: Simulation

    public func step(dt: Float) {
        var remaining = min(max(dt, 0), 0.25)
        while remaining > 0.0001 {
            let h = min(remaining, 1 / 30)
            substep(h)
            remaining -= h
        }
    }

    private func substep(_ dt: Float) {
        time += dt
        flowTime += dt * (0.25 + currentSpeed * 1.6)
        spawnRain(dt)
        updateMusic(dt)
        updateFood(dt)
        updateKoi(dt)
        updateSmallFish(dt)
        updateTurtles(dt)
        updateRipples(dt)
    }

    private func updateMusic(_ dt: Float) {
        sinceBeat += dt
        sinceSpin += dt
        if music.beats != lastBeats {
            let gap = sinceBeat
            lastBeats = music.beats
            beatSide = -beatSide
            sinceBeat = 0
            // Now and then the whole pond spins: on average once every 30 seconds of dancing, never two
            // within 12 seconds of each other.
            if discoSpins, spinAge == nil, groove > 0.25, sinceSpin > 12, rng.float(in: 0...1) < min(gap, 2) / 30 {
                spinAge = 0
                sinceSpin = 0
            }
        }
        if let age = spinAge { spinAge = age + dt > Self.spinLength + 0.3 ? nil : age + dt }
        // Headbang: the squash eases in over 80 ms (so nothing jumps, even on slow songs), springs back
        // into a stretch and settles within half a second.
        let attack = min(sinceBeat / 0.08, 1)
        bang = danceStrength * groove * attack * attack * (3 - 2 * attack) * exp(-sinceBeat / 0.25) * cos(2 * .pi * 1.5 * sinceBeat)
    }

    /// How far round a fish is in the current disco spin, in radians; each starts a little after the
    /// others, by its seed, so the pond turns in a ripple rather than in lockstep.
    public func spinAngle(seed: Float) -> Float {
        spinProgress(seed: seed) * 2 * .pi
    }

    /// 0…1 at the height of a fish's spin, for the flash on its scales.
    public func spinFlash(seed: Float) -> Float {
        sin(spinProgress(seed: seed) * .pi)
    }

    private func spinProgress(seed: Float) -> Float {
        guard let spinAge else { return 0 }
        let delay = (seed * 0.618).truncatingRemainder(dividingBy: 1) * 0.25
        let p = min(max((spinAge - delay) / Self.spinLength, 0), 1)
        return p * p * (3 - 2 * p)
    }

    /// How strongly the fish dance: not at all in silence, fully in the song's loud parts.
    private var groove: Float { min(1, music.level * 1.4) }

    private func updateKoi(_ dt: Float) {
        let groove = self.groove
        for i in koi.indices {
            var k = koi[i]
            if let held, held.index == i {
                updateHeld(&k, dt: dt)
                koi[i] = k
                continue
            }
            if k.away { continue }
            let forward = SIMD2(cos(k.heading), sin(k.heading))
            let head = k.pos + forward * k.length * 0.42
            let scale = k.length / 90
            var desired = SIMD2<Float>.zero
            var cruise: Float = (behavior == .calm ? 15 : 22) * scale

            k.wanderTimer -= dt
            if k.wanderTimer <= 0 || simd_distance(k.pos, k.wanderTarget) < 50 {
                k.wanderTarget = randomPoint(margin: 90)
                k.wanderTimer = rng.float(in: 6...14) * (behavior == .calm ? 1.5 : 1)
            }
            desired += safeNormalize(k.wanderTarget - k.pos)

            var feeding = false
            if let fi = nearestFood(to: head, within: 420) {
                let toFood = food[fi].pos - head
                let d = simd_length(toFood)
                desired = safeNormalize(toFood) * 3
                cruise = (d < 60 ? 20 : 48) * scale
                feeding = true
                if d < max(8, k.length * 0.1) {
                    addRipple(at: food[fi].pos, strength: 0.25, life: 0.9)
                    food.remove(at: fi)
                }
            }

            if !feeding, let c = cursor {
                let toCursor = c - head
                let d = simd_length(toCursor)
                switch behavior {
                case .curious where d < 320:
                    let slot = c + SIMD2(cos(k.seed * 2.4), sin(k.seed * 2.4)) * 36
                    desired = safeNormalize(slot - head) * 2
                    cruise = (d < 80 ? 10 : 30) * scale
                case .shy where d < 180:
                    desired = -safeNormalize(toCursor) * 3
                    cruise = 70 * scale
                default:
                    break
                }
            }

            if behavior == .schooling && !feeding {
                var center = SIMD2<Float>.zero
                var heading = SIMD2<Float>.zero
                var n: Float = 0
                for j in koi.indices where j != i && simd_distance(koi[j].pos, k.pos) < 260 {
                    center += koi[j].pos
                    heading += SIMD2(cos(koi[j].heading), sin(koi[j].heading))
                    n += 1
                }
                if n > 0 { desired += safeNormalize(center / n - k.pos) * 0.8 + safeNormalize(heading) * 1.2 }
            }

            for j in koi.indices where j != i {
                let away = k.pos - koi[j].pos
                let d = simd_length(away)
                let minD = (k.length + koi[j].length) * 0.34
                if d < minD && d > 0.01 { desired += away / d * (minD - d) / minD * 2.5 }
            }

            // How strongly this koi dances right now. The headbang is drawn on the body, not swum, so the
            // swimming (and with it the tail's beat) goes on undisturbed by the music.
            k.dance += (groove - k.dance) * min(1, dt * 6)
            k.lift = max(0, k.lift - dt * 2)

            if k.startle > 0 {
                desired += k.fleeDir * 4 * k.startle
                cruise = max(cruise, 85 * scale * k.startle)
                k.startle = max(0, k.startle - dt * 0.9)
            }

            desired += wallPush(k.pos, margin: 80) * 4
            steer(&k.heading, &k.turnRate, toward: desired, maxTurn: 1.5 / max(scale, 0.6), responsiveness: 2, dt: dt)
            k.speed += (cruise - k.speed) * min(1, dt * 1.4)
            k.pos += SIMD2(cos(k.heading), sin(k.heading)) * k.speed * dt + drift(at: k.pos) * 10 * dt
            k.pos = clampToPond(k.pos, slack: k.length * 0.25)
            k.phase += dt * 2 * .pi * (0.5 + k.speed / (34 * scale))

            k.depthTimer -= dt
            if k.depthTimer <= 0 {
                k.targetDepth = rng.float(in: 0.05...0.7)
                k.depthTimer = rng.float(in: 8...20)
            }
            k.depth += ((feeding ? 0 : k.targetDepth) - k.depth) * min(1, dt * 0.4)
            koi[i] = k
        }
    }

    /// A held koi: its body follows the cursor, turning the way it's pulled, and it wriggles to get free.
    private func updateHeld(_ k: inout Koi, dt: Float) {
        guard let held else { return }
        let before = k.pos
        k.pos += (held.target - k.pos) * min(1, dt * 14)
        k.pos = clampToPond(k.pos, slack: k.length * 0.25)
        let velocity = (k.pos - before) / max(dt, 0.0001)
        self.held?.velocity += (velocity - held.velocity) * min(1, dt * 10)
        if simd_length(velocity) > 15 {
            steer(&k.heading, &k.turnRate, toward: velocity, maxTurn: 6, responsiveness: 6, dt: dt)
        } else {
            k.turnRate *= 0.9
        }
        k.speed = max(simd_length(velocity), 30)
        k.phase += dt * 2 * .pi * 3.2
        k.depth += (0 - k.depth) * min(1, dt * 6)
        k.lift = min(1, k.lift + dt * 5)
        k.dance = 0
        k.startle = 0
    }

    /// A big splash: the main rings, and drops thrown up around it landing in rings of their own.
    public func splash(at p: SIMD2<Float>, strength: Float, drops: Int) {
        addRipple(at: p, strength: strength, life: 3.4 + strength * 0.4)
        for _ in 0..<drops {
            let a = rng.float(in: 0...(2 * .pi))
            addRipple(at: p + SIMD2(cos(a), sin(a)) * rng.float(in: 18...36 + 24 * strength),
                      strength: rng.float(in: 0.25...0.5), life: rng.float(in: 1.2...2))
        }
    }

    private func distance(from p: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let t = max(0, min(1, simd_dot(p - a, ab) / max(simd_dot(ab, ab), 0.0001)))
        return simd_distance(p, a + ab * t)
    }

    private func updateSmallFish(_ dt: Float) {
        for s in schoolTargets.indices {
            schoolTimers[s] -= dt
            if schoolTimers[s] <= 0 {
                schoolTargets[s] = randomPoint(margin: 110)
                schoolTimers[s] = rng.float(in: 5...12)
            }
        }
        for i in smallFish.indices {
            var f = smallFish[i]
            var acc = SIMD2<Float>.zero
            var center = SIMD2<Float>.zero
            var align = SIMD2<Float>.zero
            var n: Float = 0
            for j in smallFish.indices where j != i && smallFish[j].school == f.school {
                let toOther = smallFish[j].pos - f.pos
                let d = simd_length(toOther)
                guard d < 70 else { continue }
                center += smallFish[j].pos
                align += smallFish[j].vel
                n += 1
                if d < 12 && d > 0.01 { acc -= toOther / d * (12 - d) * 9 }
            }
            if n > 0 { acc += (center / n - f.pos) * 0.8 + (align / n - f.vel) * 1.2 }
            if f.school < schoolTargets.count { acc += safeNormalize(schoolTargets[f.school] - f.pos) * 22 }
            for k in koi where !k.away {
                let away = f.pos - k.pos
                let d = simd_length(away)
                let r = k.length * 0.75
                if d < r && d > 0.01 { acc += away / d * (r - d) / r * 260 }
            }
            if let c = cursor {
                let away = f.pos - c
                let d = simd_length(away)
                if d < 100 && d > 0.01 { acc += away / d * (100 - d) / 100 * 320 }
            }
            if f.startle > 0 {
                acc += f.fleeDir * 400 * f.startle
                f.startle = max(0, f.startle - dt * 1.5)
            }
            acc += wallPush(f.pos, margin: 50) * 260

            f.vel += acc * dt
            let speed = simd_length(f.vel)
            let maxSpeed: Float = f.startle > 0 ? 140 : 70
            if speed > maxSpeed {
                f.vel *= maxSpeed / speed
            } else if speed < 20 && speed > 0.001 {
                f.vel *= 20 / speed
            }
            f.pos += f.vel * dt + drift(at: f.pos) * 8 * dt
            f.pos = clampToPond(f.pos, slack: 10)
            let heading = atan2(f.vel.y, f.vel.x)
            let rate = wrapAngle(heading - f.heading) / max(dt, 0.0001)
            f.turnRate += (rate - f.turnRate) * min(1, dt * 6)
            f.heading = heading
            f.phase += dt * 2 * .pi * (1.5 + simd_length(f.vel) / 18)
            smallFish[i] = f
        }
    }

    private func updateTurtles(_ dt: Float) {
        for i in turtles.indices {
            var t = turtles[i]
            let scale = t.length / 72
            var cruise: Float = 10 * scale
            if t.resting > 0 {
                t.resting -= dt
                cruise = 0
            } else {
                t.timer -= dt
                if t.timer <= 0 || simd_distance(t.pos, t.target) < 40 {
                    t.target = randomPoint(margin: 110)
                    t.timer = rng.float(in: 14...28)
                    if rng.chance(0.4) {
                        t.resting = rng.float(in: 4...9)
                        t.targetDepth = 0
                    } else {
                        t.targetDepth = rng.float(in: 0.2...0.6)
                    }
                }
            }
            var desired = safeNormalize(t.target - t.pos) + wallPush(t.pos, margin: 90) * 3
            if t.startle > 0 {
                desired += t.fleeDir * 3
                cruise = 34 * scale
                t.startle = max(0, t.startle - dt * 0.5)
            }
            steer(&t.heading, &t.turnRate, toward: cruise > 0 ? desired : .zero, maxTurn: 0.6,
                  responsiveness: 1.2, dt: dt)
            t.speed += (cruise - t.speed) * min(1, dt * 0.8)
            t.pos += SIMD2(cos(t.heading), sin(t.heading)) * t.speed * dt + drift(at: t.pos) * 6 * dt
            t.pos = clampToPond(t.pos, slack: t.length * 0.2)
            t.phase += dt * 2 * .pi * (t.speed > 1 ? 0.25 + t.speed / 40 : 0.08)
            t.depth += (t.targetDepth - t.depth) * min(1, dt * 0.3)
            turtles[i] = t
        }
    }

    private func updateFood(_ dt: Float) {
        for i in food.indices.reversed() {
            food[i].age += dt
            if food[i].age > 14 { food[i].sink = min(1, (food[i].age - 14) / 8) }
            food[i].pos += drift(at: food[i].pos) * 5 * dt
            if food[i].age > 22 { food.remove(at: i) }
        }
    }

    private func updateRipples(_ dt: Float) {
        for i in ripples.indices.reversed() {
            ripples[i].age += dt
            // The rings ride on the current like everything else on the water.
            ripples[i].pos += drift(at: ripples[i].pos) * 5 * dt
            if ripples[i].age >= ripples[i].life { ripples.remove(at: i) }
        }
    }

    private func spawnRain(_ dt: Float) {
        guard rain > 0.01 else {
            rainBudget = 0
            return
        }
        rainBudget += dt * rain * (size.x * size.y / 1_000_000) * 26
        while rainBudget >= 1 {
            rainBudget -= 1
            addRipple(at: SIMD2(rng.float(in: 0...size.x), rng.float(in: 0...size.y)),
                      strength: rng.float(in: 0.15...0.4), life: rng.float(in: 0.7...1.2))
        }
    }

    // MARK: Helpers

    private func steer(_ heading: inout Float, _ turnRate: inout Float, toward desired: SIMD2<Float>,
                       maxTurn: Float, responsiveness: Float, dt: Float) {
        if simd_length_squared(desired) < 1e-6 {
            turnRate *= max(0, 1 - dt * 2)
        } else {
            let delta = wrapAngle(atan2(desired.y, desired.x) - heading)
            let want = max(-maxTurn, min(maxTurn, delta * responsiveness))
            turnRate += (want - turnRate) * min(1, dt * 3)
        }
        heading = wrapAngle(heading + turnRate * dt)
    }

    private func nearestFood(to p: SIMD2<Float>, within radius: Float) -> Int? {
        var best: Int?
        var bestDistance = radius * radius
        for (i, f) in food.enumerated() where f.sink < 0.9 {
            let d = simd_distance_squared(f.pos, p)
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    private func drift(at p: SIMD2<Float>) -> SIMD2<Float> {
        currentsEnabled ? Flow.velocity(at: p, time: flowTime) * currentStrength : .zero
    }

    private func wallPush(_ p: SIMD2<Float>, margin: Float) -> SIMD2<Float> {
        var v = SIMD2<Float>.zero
        if p.x < margin { v.x += (margin - p.x) / margin }
        if p.x > size.x - margin { v.x -= (p.x - (size.x - margin)) / margin }
        if p.y < margin { v.y += (margin - p.y) / margin }
        if p.y > size.y - margin { v.y -= (p.y - (size.y - margin)) / margin }
        return v
    }

    private func clampToPond(_ p: SIMD2<Float>, slack: Float) -> SIMD2<Float> {
        simd_clamp(p, SIMD2(repeating: -slack), size + slack)
    }

    private func randomPoint(margin: Float) -> SIMD2<Float> {
        let mx = min(margin, size.x / 3)
        let my = min(margin, size.y / 3)
        return SIMD2(rng.float(in: mx...(size.x - mx)), rng.float(in: my...(size.y - my)))
    }
}

func safeNormalize(_ v: SIMD2<Float>) -> SIMD2<Float> {
    let length = simd_length(v)
    return length > 1e-5 ? v / length : .zero
}

func wrapAngle(_ a: Float) -> Float {
    var x = a.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi } else if x < -.pi { x += 2 * .pi }
    return x
}

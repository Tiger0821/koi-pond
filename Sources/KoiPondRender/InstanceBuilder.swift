import KoiPondCore
import simd

/// Turns the pond's state into draw order: floor plants, shadows, animals (deepest first),
/// food, ripples, then the floating lily pads and flowers.
enum InstanceBuilder {
    /// Light comes from the upper left, so shadows fall down and to the right.
    static let shadowDirection = SIMD2<Float>(0.6, -0.8)

    static func build(pond: Pond) -> [GPUInstance] {
        var out: [GPUInstance] = []
        out.reserveCapacity(pond.plants.count + 2 * (pond.koi.count + pond.smallFish.count + pond.turtles.count)
            + 2 * pond.pads.count + pond.flowers.count + pond.food.count + pond.ripples.count)
        let t = pond.time

        for plant in pond.plants {
            out.append(GPUInstance(position: plant.pos, size: SIMD2(repeating: plant.size * 0.7), kind: ShapeKind.plant.rawValue,
                                   seed: plant.seed, color0: [0.18, 0.42, 0.2, 1], color1: [0.5, 0.72, 0.32, 1],
                                   params: [plant.size, 0, 0, 0], params2: [0, 0, 0, 0.4]))
        }

        var bodies: [(depth: Float, instance: GPUInstance)] = []
        func addWithShadow(_ instance: GPUInstance, depth: Float, shadowKind: ShapeKind) {
            bodies.append((depth, instance))
            var shadow = instance
            shadow.kind = shadowKind.rawValue
            shadow.position += shadowDirection * (5 + (1 - depth) * 16)
            shadow.color0.w = 0.24 * (1 - depth * 0.5)
            out.append(shadow)
        }
        for k in pond.koi where !k.away { addWithShadow(koi(k), depth: k.depth, shadowKind: .fishShadow) }
        for f in pond.smallFish { addWithShadow(smallFish(f), depth: 0.25, shadowKind: .fishShadow) }
        for turtle in pond.turtles { addWithShadow(self.turtle(turtle), depth: turtle.depth, shadowKind: .turtleShadow) }

        let pads = pond.pads.map { pad($0, time: t) }
        for var shadow in pads {
            shadow.kind = ShapeKind.padShadow.rawValue
            shadow.position += shadowDirection * 14
            shadow.color0.w = 0.22
            out.append(shadow)
        }

        out.append(contentsOf: bodies.sorted { $0.depth > $1.depth }.map(\.instance))

        for food in pond.food {
            out.append(GPUInstance(position: food.pos, size: SIMD2(repeating: 4.5), kind: ShapeKind.food.rawValue,
                                   color0: [0.78, 0.47, 0.2, 1 - food.sink], params: [3 * (1 - food.sink * 0.35), 0, 0, 0],
                                   params2: [0, 0, 0, food.sink * 0.6]))
        }

        for ripple in pond.ripples {
            // The spreading in the shader does most of the weakening; this only rounds off the end.
            let fade = min(1, max(0, 1 - ripple.age / ripple.life) * 3)
            let reach = ripple.radius * (1 + 2 * ripple.wobble) + 10 + 8 * ripple.strength
            out.append(GPUInstance(position: ripple.pos, size: SIMD2(repeating: reach), kind: ShapeKind.ripple.rawValue,
                                   seed: ripple.seed, phase: ripple.age,
                                   params: [ripple.wavenumber, ripple.bandwidth, ripple.strength * fade * 1.3, Ripple.gravity],
                                   params2: [ripple.phase, ripple.strength, 0, ripple.wobble]))
        }

        out.append(contentsOf: pads)

        for flower in pond.flowers where flower.pad < pads.count {
            let pad = pads[flower.pad]
            let c = cos(pad.rotation), s = sin(pad.rotation)
            let offset = SIMD2(flower.offset.x * c - flower.offset.y * s, flower.offset.x * s + flower.offset.y * c)
            let colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = flower.isWaterLily
                ? ([0.97, 0.96, 0.92, 1], [1.0, 0.99, 0.94, 1], [0.98, 0.78, 0.22, 1])
                : ([0.95, 0.52, 0.64, 1], [0.99, 0.76, 0.82, 1], [0.98, 0.82, 0.32, 1])
            out.append(GPUInstance(position: pad.position + offset, size: SIMD2(repeating: flower.radius + 1),
                                   rotation: flower.seed + t * 0.02, kind: ShapeKind.flower.rawValue, seed: flower.seed,
                                   color0: colors.0, color1: colors.1, color2: colors.2,
                                   params: [flower.radius, flower.petals, flower.isWaterLily ? 1 : 0, 0]))
        }
        return out
    }

    static func koi(_ k: Koi) -> GPUInstance {
        let look = k.variety.look
        let curvature = max(-0.25, min(0.25, k.length * k.turnRate / (2 * max(k.speed, 12))))
        let amplitude = 0.05 + min(k.speed, 70) / 70 * 0.06 + k.dance * 0.06
        // Swells a little on the beat, and more when lifted by the cursor.
        let length = k.length * (1 + k.dance * 0.05 + k.lift * 0.12)
        return GPUInstance(position: k.pos, size: [length * 0.62, length * 0.6], rotation: k.heading,
                           kind: ShapeKind.fish.rawValue, seed: k.seed, phase: k.phase,
                           color0: SIMD4(look.base, 1), color1: SIMD4(look.patch, 0), color2: SIMD4(look.accent, 0),
                           params: [length, 0.135, amplitude, curvature],
                           params2: [look.patchThreshold, look.accentThreshold, look.special, k.depth])
    }

    static func smallFish(_ f: SmallFish) -> GPUInstance {
        let speed = simd_length(f.vel)
        let curvature = max(-0.3, min(0.3, f.length * f.turnRate / (2 * max(speed, 20))))
        let base: SIMD3<Float> = f.golden ? [0.98, 0.6, 0.22] : [0.74, 0.82, 0.88]
        let stripe: SIMD3<Float> = f.golden ? [0.12, 0.1, 0.1] : [0.22, 0.34, 0.5]
        return GPUInstance(position: f.pos, size: [f.length * 0.62, f.length * 0.6], rotation: f.heading,
                           kind: ShapeKind.fish.rawValue, seed: f.seed, phase: f.phase,
                           color0: SIMD4(base, 1), color1: SIMD4(base, 0), color2: SIMD4(stripe, 0),
                           params: [f.length, 0.11, 0.08, curvature], params2: [2, 2, 4, 0.25])
    }

    static func turtle(_ t: Turtle) -> GPUInstance {
        GPUInstance(position: t.pos, size: SIMD2(repeating: t.length * 0.5), rotation: t.heading,
                    kind: ShapeKind.turtle.rawValue, seed: t.seed, phase: t.phase,
                    color0: [0.34, 0.4, 0.22, 1], color1: [0.4, 0.47, 0.28, 1], color2: [0.78, 0.72, 0.36, 1],
                    params: [t.length, 0, 0, 0], params2: [0, 0, 0, t.depth])
    }

    static func pad(_ pad: LilyPad, time t: Float) -> GPUInstance {
        let bob = SIMD2(sin(t * 0.31 + pad.bobPhase), cos(t * 0.27 + pad.bobPhase)) * 1.5
        let shade = 0.88 + 0.22 * (pad.seed * 0.37).truncatingRemainder(dividingBy: 1)
        return GPUInstance(position: pad.pos + bob, size: SIMD2(repeating: pad.radius + 2),
                           rotation: pad.rotation + sin(t * 0.2 + pad.bobPhase) * 0.05, kind: ShapeKind.pad.rawValue,
                           seed: pad.seed, color0: SIMD4(SIMD3<Float>(0.27, 0.52, 0.27) * shade, 1),
                           params: [pad.radius, pad.notch, pad.yellowing, 0])
    }
}

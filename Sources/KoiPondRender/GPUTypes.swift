import simd

/// One quad drawn by `instance_vertex`. Layout must match `Instance` in the shader.
struct GPUInstance {
    var position: SIMD2<Float>
    /// Half extents of the quad, in points.
    var size: SIMD2<Float>
    var rotation: Float = 0
    var kind: Float
    var seed: Float = 0
    var phase: Float = 0
    var color0 = SIMD4<Float>(1, 1, 1, 1)
    var color1 = SIMD4<Float>.zero
    var color2 = SIMD4<Float>.zero
    var params = SIMD4<Float>.zero
    /// For animals, w is depth below the surface (0...1).
    var params2 = SIMD4<Float>.zero
    /// For koi: metallic shine (0...1), fin markings (`KoiVariety.Fins`), red eyes (0 or 1), unused.
    var params3 = SIMD4<Float>.zero
    /// For koi: pattern (`KoiVariety.Pattern`), scales (`KoiVariety.Scales`), red lips (0 or 1), ink-wash edges (0 or 1).
    var params4 = SIMD4<Float>.zero
}

/// Layout must match `Uniforms` in the shader.
struct GPUUniforms {
    /// width, height, time, pixel mode
    var world: SIMD4<Float>
    /// rgb, clarity
    var water: SIMD4<Float>
    /// rgb multiply, ambient add
    var tint: SIMD4<Float>
    /// rgb, strength
    var glow: SIMD4<Float>
    /// caustics, current strength, flow time, rain
    var fx: SIMD4<Float>
    /// lightning, saturation, points per texel, fish colour kept at night
    var fx2: SIMD4<Float>
}

enum ShapeKind: Float {
    case fish = 0, fishShadow, turtle, turtleShadow, pad, padShadow, flower, food, plant, ripple
}

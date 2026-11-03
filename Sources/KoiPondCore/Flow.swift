import Foundation

/// The pond's water current, defined by a stream function so the shader can draw streaks
/// along the same lines the animals drift along. Keep in sync with `streamFn` in the shader.
public enum Flow {
    static let a1: Float = 190, k1: Float = 0.0031, w1: Float = 0.21
    static let a2: Float = 170, k2: Float = 0.0037, w2: Float = 0.17
    static let a3: Float = 230, k3: Float = 0.0021, w3: Float = 0.13
    static let drift: Float = 0.18

    public static func streamFunction(at p: SIMD2<Float>, time t: Float) -> Float {
        a1 * sin(k1 * p.x + w1 * t)
            + a2 * cos(k2 * p.y - w2 * t)
            + a3 * sin(k3 * (p.x - p.y) + w3 * t)
            + drift * p.y
    }

    /// Velocity is the stream function's gradient turned 90°, so it runs along its level lines.
    public static func velocity(at p: SIMD2<Float>, time t: Float) -> SIMD2<Float> {
        let diagonal = a3 * k3 * cos(k3 * (p.x - p.y) + w3 * t)
        let dx = a1 * k1 * cos(k1 * p.x + w1 * t) + diagonal
        let dy = -a2 * k2 * sin(k2 * p.y - w2 * t) - diagonal + drift
        return SIMD2(dy, -dx)
    }
}

import KoiPondCore
import simd

/// A koi placed by hand, for sample pictures.
public struct LineupKoi: Sendable {
    public var variety: KoiVariety
    /// Which of the variety's designs it wears.
    public var design = 0
    public var pos: SIMD2<Float>
    public var heading: Float
    public var length: Float
    public var depth: Float
    public var phase: Float
    public var seed: Float
    public var curvature: Float

    public init(variety: KoiVariety, pos: SIMD2<Float>, heading: Float, length: Float, depth: Float = 0.2,
                phase: Float = 0, seed: Float = 1, curvature: Float = 0) {
        self.variety = variety
        self.pos = pos
        self.heading = heading
        self.length = length
        self.depth = depth
        self.phase = phase
        self.seed = seed
        self.curvature = curvature
    }

    var look: KoiVariety.Look {
        let designs = variety.designs
        return designs[design % designs.count]
    }

    /// `kohaku@700,500,1.2,96`, `kohaku:2@700,500,1.2,96` for its third design, or with more numbers
    /// `kohaku@700,500,1.2,96,0.3,2.1,17` (variety[:design]@x,y,heading,length[,depth,phase,seed]).
    public static func parse(_ text: String) -> [LineupKoi] {
        text.split(separator: ";").compactMap { item in
            let parts = item.split(separator: "@")
            guard parts.count == 2 else { return nil }
            let name = parts[0].split(separator: ":")
            guard let first = name.first,
                  let variety = KoiVariety.allCases.first(where: { "\($0)".lowercased() == first.lowercased() })
            else { return nil }
            let n = parts[1].split(separator: ",").compactMap { Float($0) }
            guard n.count >= 4 else { return nil }
            var koi = LineupKoi(variety: variety, pos: [n[0], n[1]], heading: n[2], length: n[3],
                                depth: n.count > 4 ? n[4] : 0.2, phase: n.count > 5 ? n[5] : n[0] * 0.01,
                                seed: n.count > 6 ? n[6] : n[1] * 0.37, curvature: n.count > 7 ? n[7] : 0)
            koi.design = name.count > 1 ? max(0, Int(name[1]) ?? 0) : 0
            return koi
        }
    }
}

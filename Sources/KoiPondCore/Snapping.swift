import CoreGraphics

public enum Snapping {
    /// Pulls a dragged widget onto the area's edges and center lines when it comes near them, and onto a
    /// 24-point grid everywhere else, so it always lands neatly. `point` is the widget's origin.
    public static func snap(_ point: CGPoint, size: CGSize, area: CGRect) -> CGPoint {
        func axis(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            guard high > low else { return low }
            let value = min(max(value, low), high)
            if let line = [low, (low + high) / 2, high].first(where: { abs(value - $0) < 36 }) { return line.rounded() }
            return (low + ((value - low) / 24).rounded() * 24).rounded()
        }
        return CGPoint(x: axis(point.x, area.minX, area.maxX - size.width),
                       y: axis(point.y, area.minY, area.maxY - size.height))
    }
}

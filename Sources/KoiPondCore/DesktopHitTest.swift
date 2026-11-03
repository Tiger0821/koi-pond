import CoreGraphics

/// The parts of a window-list entry the hit test needs. Bounds use Quartz global coordinates:
/// origin at the top left of the primary display, y pointing down.
public struct WindowSnapshot: Sendable {
    public var layer: Int
    public var bounds: CGRect
    public var ownerPID: Int32
    public var ownerName: String
    public var alpha: Double

    public init(layer: Int, bounds: CGRect, ownerPID: Int32, ownerName: String, alpha: Double = 1) {
        self.layer = layer
        self.bounds = bounds
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.alpha = alpha
    }
}

/// Decides whether a point on screen is bare desktop, using only window bounds, layers and owners,
/// which macOS hands out without Screen Recording permission.
public enum DesktopHitTest {
    /// Whether a window sits above the desktop icons and would take a click at its bounds.
    public static func blocks(_ w: WindowSnapshot, ownPID: Int32, iconLevel: Int, screens: [CGRect]) -> Bool {
        if w.ownerPID == ownPID || w.alpha < 0.05 || w.bounds.isEmpty { return false }
        if w.layer <= iconLevel { return false }
        let fullScreen = screens.contains { areaFraction(of: $0, coveredBy: w.bounds) > 0.9 }
        if w.layer < 0 {
            // Between the icons and normal windows live desktop widgets (which do take clicks),
            // Window Server backing layers, and full-screen overlays from other desktop apps.
            if w.ownerName == "Window Server" || fullScreen { return false }
        } else if w.layer > 0, fullScreen {
            // Above normal windows, a full-screen window is an overlay that lets clicks through: the one the
            // Screenshot tool leaves behind after a capture, or the Dock's while Show Desktop pushes windows
            // aside. (In Mission Control, clicks still land on the windows underneath and are ignored.)
            return false
        }
        return true
    }

    /// The window that takes a click at `point`, or nil when it lands on bare desktop.
    public static func blocker(at point: CGPoint, windows: [WindowSnapshot], ownPID: Int32, iconLevel: Int,
                               screens: [CGRect]) -> WindowSnapshot? {
        windows.first {
            $0.bounds.contains(point) && blocks($0, ownPID: ownPID, iconLevel: iconLevel, screens: screens)
        }
    }

    public static func isDesktop(at point: CGPoint, windows: [WindowSnapshot], ownPID: Int32, iconLevel: Int,
                                 screens: [CGRect]) -> Bool {
        blocker(at: point, windows: windows, ownPID: ownPID, iconLevel: iconLevel, screens: screens) == nil
    }

    /// Fraction of `screen` hidden behind ordinary app windows, sampled on a grid so overlaps count once.
    public static func coveredFraction(of screen: CGRect, windows: [WindowSnapshot], ownPID: Int32) -> Double {
        let covering = windows.filter {
            $0.ownerPID != ownPID && $0.alpha > 0.05 && $0.layer >= 0 && $0.layer < 20 && $0.bounds.intersects(screen)
        }
        guard !covering.isEmpty, screen.width > 0, screen.height > 0 else { return 0 }
        let columns = 32, rows = 20
        var hits = 0
        for row in 0..<rows {
            for column in 0..<columns {
                let p = CGPoint(x: screen.minX + (CGFloat(column) + 0.5) * screen.width / CGFloat(columns),
                                y: screen.minY + (CGFloat(row) + 0.5) * screen.height / CGFloat(rows))
                if covering.contains(where: { $0.bounds.contains(p) }) { hits += 1 }
            }
        }
        return Double(hits) / Double(columns * rows)
    }

    static func areaFraction(of screen: CGRect, coveredBy rect: CGRect) -> Double {
        let overlap = screen.intersection(rect)
        guard !overlap.isNull, screen.width > 0, screen.height > 0 else { return 0 }
        return Double(overlap.width * overlap.height / (screen.width * screen.height))
    }
}

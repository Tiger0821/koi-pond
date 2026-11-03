import AppKit
import KoiPondCore

/// Reads the on-screen window list and converts between AppKit and Quartz coordinates.
/// Only bounds, layers and owners are used; window titles (which need Screen Recording) are not.
enum WindowList {
    static func snapshot() -> [WindowSnapshot] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else { return nil }
            return WindowSnapshot(layer: layer, bounds: bounds,
                                  ownerPID: Int32(info[kCGWindowOwnerPID as String] as? Int ?? 0),
                                  ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                                  alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    /// AppKit's origin is the primary display's bottom left; Quartz's is its top left.
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func quartzPoint(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func quartzRect(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

import CoreGraphics

public enum ScreenCoordinates {
    /// Converts an AppKit screen point (origin at the bottom-left of the primary display)
    /// to a Quartz point (origin at the top-left). Accessibility hit-testing uses Quartz points.
    public static func quartzPoint(fromCocoa point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

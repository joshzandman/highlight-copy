import CoreGraphics

public enum ScreenCoordinates {
    /// Converts an AppKit screen point (origin at the bottom-left of the primary display)
    /// to a Quartz point (origin at the top-left). Accessibility hit-testing uses Quartz points.
    public static func quartzPoint(fromCocoa point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

public enum TooltipPlacement {
    /// Puts the label just past the end of the highlight, and on the other side if that would leave the screen.
    public static func origin(anchor: CGPoint, size: CGSize, visibleRect: CGRect, gap: CGFloat = 6) -> CGPoint {
        var origin = CGPoint(x: anchor.x + gap, y: anchor.y - size.height / 2)
        if origin.x + size.width > visibleRect.maxX {
            origin.x = anchor.x - size.width - gap
        }
        let maxX = max(visibleRect.minX, visibleRect.maxX - size.width)
        let maxY = max(visibleRect.minY, visibleRect.maxY - size.height)
        origin.x = min(max(origin.x, visibleRect.minX), maxX)
        origin.y = min(max(origin.y, visibleRect.minY), maxY)
        return origin
    }
}

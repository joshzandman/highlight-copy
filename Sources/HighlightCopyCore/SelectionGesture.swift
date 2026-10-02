import CoreGraphics
import Foundation

/// Tracks one pointer gesture and decides whether releasing the button finished a highlight.
///
/// A multi-click keeps the snapshot from the first mouse-down. Word selection is applied on the
/// second mouse-down, so replacing the snapshot there would hide the highlight.
public struct SelectionGesture {
    public private(set) var snapshot: String = ""
    public private(set) var anchor: CGPoint?
    public private(set) var dragged = false
    public private(set) var clickCount: Int = 0
    public var threshold: CGFloat = 3

    public init() {}

    public mutating func mouseDown(at point: CGPoint, clickCount: Int, selectedText: String) {
        if clickCount <= 1 {
            snapshot = selectedText
            anchor = point
            dragged = false
            self.clickCount = max(clickCount, 0)
        } else {
            self.clickCount = max(self.clickCount, clickCount)
        }
    }

    public mutating func mouseDragged(to point: CGPoint) {
        guard let anchor else { return }
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        if (dx * dx + dy * dy) >= threshold * threshold {
            dragged = true
        }
    }

    public mutating func mouseUp(at point: CGPoint, clickCount: Int) {
        mouseDragged(to: point)
        self.clickCount = max(self.clickCount, clickCount)
    }

    /// Click-drag, tap-drag, and three-finger drag all set `dragged`. Multi-clicks select a word or line.
    public var isHighlight: Bool {
        dragged || clickCount >= 2
    }
}

public enum CopyDecision {
    public static func shouldCopy(gesture: SelectionGesture, selectedText: String) -> Bool {
        guard gesture.isHighlight else { return false }
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if gesture.clickCount >= 2 { return true }
        return selectedText != gesture.snapshot
    }
}

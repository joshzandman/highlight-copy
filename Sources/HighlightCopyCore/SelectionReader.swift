import ApplicationServices
import CoreGraphics
import Foundation

public enum CopyTarget: Equatable {
    case secure
    case text(selected: String?)
    case other

    public var isSecure: Bool {
        if case .secure = self { return true }
        return false
    }

    public var selectedText: String? {
        if case .text(let selected) = self { return selected }
        return nil
    }
}

public enum SelectionReader {
    /// Selected text for a pointer-up. The element under the pointer wins when it has a selection.
    /// A secure field anywhere in that chain suppresses the copy, including a fallback to focus.
    public static func target(atQuartzPoint point: CGPoint) -> CopyTarget {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)

        if let hit = element(at: point, in: system) {
            if let target = target(from: hit) { return target }
        }
        if let focused = focusedElement(in: system) {
            if let target = target(from: focused) { return target }
        }
        return .other
    }

    public static func selectedText(atQuartzPoint point: CGPoint) -> String? {
        target(atQuartzPoint: point).selectedText
    }

    /// Trailing edge of the last selected glyph, in Quartz screen coordinates.
    /// The point is the right-center of that glyph so a label can sit just past the highlight.
    public static func selectionTail(atQuartzPoint point: CGPoint) -> CGPoint? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        if let hit = element(at: point, in: system), let tail = tail(from: hit) {
            return tail
        }
        if let focused = focusedElement(in: system), let tail = tail(from: focused) {
            return tail
        }
        return nil
    }

    private static func target(from element: AXUIElement) -> CopyTarget? {
        if isSecureChain(element) { return .secure }
        if let text = firstSelectedText(startingAt: element) {
            return .text(selected: text)
        }
        // Some apps expose a selected range but not the string. Command-C can still read it.
        if hasSelectedRange(element) || isTextualChain(element) {
            return .text(selected: nil)
        }
        return nil
    }

    private static func isTextualChain(_ element: AXUIElement, hops: Int = 12) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<hops {
            guard let node = current else { return false }
            if isTextRole(stringAttribute(kAXRoleAttribute, of: node)) { return true }
            current = parent(of: node)
        }
        return false
    }

    private static func isTextRole(_ role: String?) -> Bool {
        switch role {
        case kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole, "AXWebArea", "AXComboBox":
            return true
        default:
            return false
        }
    }

    private static func element(at point: CGPoint, in system: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found)
        guard error == .success else { return nil }
        return found
    }

    private static func focusedElement(in system: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXFocusedUIElementAttribute, of: system)
    }

    private static func firstSelectedText(startingAt element: AXUIElement, hops: Int = 12) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<hops {
            guard let node = current else { return nil }
            AXUIElementSetMessagingTimeout(node, 0.25)
            if let text = stringAttribute(kAXSelectedTextAttribute, of: node), !text.isEmpty {
                return text
            }
            current = parent(of: node)
        }
        return nil
    }

    private static func hasSelectedRange(_ element: AXUIElement, hops: Int = 12) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<hops {
            guard let node = current else { return false }
            if selectedRangeLength(of: node) > 0 { return true }
            current = parent(of: node)
        }
        return false
    }

    private static func tail(from element: AXUIElement) -> CGPoint? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let node = current else { return nil }
            if let range = selectedRange(of: node), range.length > 0,
               let rect = bounds(of: CFRange(location: range.location + range.length - 1, length: 1), on: node) {
                return CGPoint(x: rect.maxX, y: rect.midY)
            }
            current = parent(of: node)
        }
        return nil
    }

    private static func bounds(of range: CFRange, on element: AXUIElement) -> CGRect? {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            value,
            &result
        )
        guard error == .success, let result else { return nil }
        guard CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let axValue = result as! AXValue
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        guard rect.width > 0 || rect.height > 0 else { return nil }
        return rect
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let value = copiedValue(kAXSelectedTextRangeAttribute, of: element) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func selectedRangeLength(of element: AXUIElement) -> Int {
        selectedRange(of: element)?.length ?? 0
    }

    private static func isSecureChain(_ element: AXUIElement, hops: Int = 5) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<hops {
            guard let node = current else { return false }
            if isSecure(node) { return true }
            current = parent(of: node)
        }
        return false
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        if stringAttribute(kAXSubroleAttribute, of: element) == kAXSecureTextFieldSubrole {
            return true
        }
        if stringAttribute(kAXRoleAttribute, of: element) == kAXSecureTextFieldSubrole {
            return true
        }
        return false
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXParentAttribute, of: element)
    }

    private static func elementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = copiedValue(attribute, of: element) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        guard let value = copiedValue(attribute, of: element) else { return nil }
        let type = CFGetTypeID(value)
        if type == CFStringGetTypeID() {
            return value as? String
        }
        if type == CFAttributedStringGetTypeID() {
            let attributed = value as! CFAttributedString
            return CFAttributedStringGetString(attributed) as String
        }
        return nil
    }

    private static func copiedValue(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }
}

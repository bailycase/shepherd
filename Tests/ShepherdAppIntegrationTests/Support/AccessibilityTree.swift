import AppKit

/// One element of a window's accessibility tree as VoiceOver reads it (SwiftUI's nodes under a
/// hosting view). Tests find a control by what it says and press it the way VoiceOver does, so
/// nothing is posted to the window and the user's pointer and keyboard are never involved.
///
/// SwiftUI draws its accessibility tree only while an assistive client is attached to the
/// process. `enable()` is that client's switch, and it is process-wide (every hosting view then
/// builds its tree on each update), so only a test run in its own process, as an exit test, may
/// call it.
@MainActor
struct AccessibilityNode {
    let object: NSObject

    /// Attaches this process to SwiftUI's accessibility tree, as VoiceOver or the Accessibility
    /// Inspector does from outside.
    static func enable() {
        for name in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: name))
        }
    }

    /// Every element under the hosting view, root first, depth first.
    static func all(under host: NSView) -> [AccessibilityNode] {
        _ = host.accessibilityChildren()
        var found: [AccessibilityNode] = []
        func walk(_ node: AccessibilityNode, depth: Int) {
            guard depth < 40 else { return }
            found.append(node)
            for child in node.children { walk(child, depth: depth + 1) }
        }
        walk(AccessibilityNode(object: host), depth: 0)
        return found
    }

    var children: [AccessibilityNode] {
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector), let list = object.perform(selector)?.takeUnretainedValue() as? [Any] else { return [] }
        return list.compactMap { ($0 as? NSObject).map(AccessibilityNode.init) }
    }

    private func string(_ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func flag(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        typealias Call = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Call.self)(object, selector)
    }

    var label: String? { string("accessibilityLabel") }
    var role: String? { string("accessibilityRole") }
    var value: String? { string("accessibilityValue") }
    var isSelected: Bool { flag("isAccessibilitySelected") }

    /// VoiceOver's press. False when the element does not take it.
    @discardableResult func press() -> Bool { flag("accessibilityPerformPress") }

    /// The element's frame in screen coordinates.
    var frame: NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { return .zero }
        typealias Call = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Call.self)(object, selector)
    }
}

extension OffscreenWindow {
    /// Every accessibility element in the window, after layout.
    func elements() -> [AccessibilityNode] {
        layout()
        return AccessibilityNode.all(under: host)
    }

    /// The element that says `label`.
    func element(_ label: String) -> AccessibilityNode? {
        elements().first { $0.label == label }
    }

    /// The buttons of the group that says `label` (a segmented control), left to right, top to bottom.
    func buttons(in label: String) -> [AccessibilityNode] {
        guard let group = elements().first(where: { $0.role == "AXGroup" && $0.label == label }) else { return [] }
        return group.children.filter { $0.role == "AXButton" }
    }
}

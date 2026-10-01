import AppKit

/// One element of a window's accessibility tree as VoiceOver reads it (SwiftUI's nodes under a
/// hosting view). Tests find a control by what it says and press it the way VoiceOver does, so
/// nothing is posted to the window and the user's pointer and keyboard are never involved.
///
/// SwiftUI draws its accessibility tree only while an assistive client is attached to the
/// process. `enable()` is that client's switch, and it is process-wide (every hosting view then
/// builds its tree on each update), so only a test run in its own process, as an exit test, may
/// call it. See `ControlPress`.
@MainActor
public struct AccessibilityNode {
    public let object: NSObject

    public init(object: NSObject) { self.object = object }

    /// Attaches this process to SwiftUI's accessibility tree, as VoiceOver or the Accessibility
    /// Inspector does from outside.
    public static func enable() {
        for name in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: name))
        }
    }

    /// Every element under the hosting view, root first, depth first.
    public static func all(under host: NSView) -> [AccessibilityNode] {
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

    public var children: [AccessibilityNode] {
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector), let list = object.perform(selector)?.takeUnretainedValue() as? [Any] else { return [] }
        return list.compactMap { ($0 as? NSObject).map(AccessibilityNode.init) }
    }

    private func string(_ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func flag(_ name: String, default fallback: Bool = false) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return fallback }
        typealias Call = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Call.self)(object, selector)
    }

    public var label: String? { string("accessibilityLabel") }
    public var role: String? { string("accessibilityRole") }
    public var value: String? { string("accessibilityValue") }
    public var isSelected: Bool { flag("isAccessibilitySelected") }
    /// False for a control the app draws disabled.
    public var isEnabled: Bool { flag("isAccessibilityEnabled", default: true) }

    /// VoiceOver's press. False when the element does not take it.
    @discardableResult public func press() -> Bool { flag("accessibilityPerformPress") }

    private var customActions: [NSAccessibilityCustomAction] {
        let selector = NSSelectorFromString("accessibilityCustomActions")
        guard object.responds(to: selector),
              let list = object.perform(selector)?.takeUnretainedValue() as? [NSAccessibilityCustomAction] else { return [] }
        return list
    }

    /// The custom actions VoiceOver's action menu offers on this element (`accessibilityAction(named:)`
    /// and `accessibilityActions`), by name.
    public var actionNames: [String] { customActions.map(\.name) }

    /// Runs the custom action `name`, as VoiceOver's action menu does. False when the element offers
    /// none by that name.
    @discardableResult public func perform(action name: String) -> Bool {
        guard let action = customActions.first(where: { $0.name == name }) else { return false }
        if let handler = action.handler { return handler() }
        if let target = action.target, let selector = action.selector {
            _ = (target as AnyObject).perform(selector)
            return true
        }
        return false
    }

    /// The element's frame in screen coordinates.
    public var frame: NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { return .zero }
        typealias Call = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Call.self)(object, selector)
    }
}

/// Accessibility roles (`AXRole`) a test names when it presses.
public enum ControlRole {
    public static let button = "AXButton"
    public static let checkBox = "AXCheckBox"
    public static let radioButton = "AXRadioButton"
    public static let popUpButton = "AXPopUpButton"
    public static let menuButton = "AXMenuButton"
    public static let menuItem = "AXMenuItem"
    public static let link = "AXLink"
    public static let group = "AXGroup"

    /// The roles `ControlPress.controls(in:)` lists: what a person can press, toggle or open.
    public static let actionable: Set<String> = [button, checkBox, radioButton, popUpButton, menuButton, menuItem, link,
                                                 "AXDisclosureTriangle", "AXSwitch"]
}

/// The smallest hit area a control may have, per platform: the Mac's pointer (24pt) and a finger (44pt).
public enum HitArea: Sendable {
    case desktop, touch

    public var minimum: CGFloat {
        switch self {
        case .desktop: 24
        case .touch: 44
        }
    }
}

/// An actionable control found in a window: what it says, what it is, whether it takes a press,
/// and the frame the accessibility tree gives it in screen coordinates.
public struct Control: CustomStringConvertible {
    public let node: AccessibilityNode
    public let role: String
    public let label: String?
    public let value: String?
    public let frame: CGRect
    public let isEnabled: Bool
    public let isSelected: Bool

    @MainActor init(_ node: AccessibilityNode, role: String) {
        self.node = node
        self.role = role
        label = node.label
        value = node.value
        frame = node.frame
        isEnabled = node.isEnabled
        isSelected = node.isSelected
    }

    public var description: String {
        let size = "\(Int(frame.width.rounded()))×\(Int(frame.height.rounded()))"
        return "\(role) \(label.map { "\"\($0)\"" } ?? "(no label)") \(size)\(isEnabled ? "" : " disabled")"
    }
}

/// Why a press did not happen. `description` names the control asked for and lists what the
/// window does offer, so a test that fails says which label to use.
public struct ControlPressError: Error, CustomStringConvertible {
    public enum Reason: Sendable { case notFound, ambiguous, disabled, refused }

    public let reason: Reason
    public let description: String
}

/// Presses and measures the controls a view draws, the way VoiceOver does: by finding the control
/// in the accessibility tree and running its press action. Nothing is posted to the window, and
/// no mouse or key event is ever synthesized. This is how a test proves that a control the
/// design draws is a control, is enabled in the state the design says, reaches what it should,
/// and has a hit area a person can hit.
///
/// **A test opts in by running in its own process.** SwiftUI draws the accessibility tree only
/// while an assistive client is attached to the process, and attaching is process-wide
/// (`AccessibilityNode.enable()`: every hosting view then builds its tree on each update), so
/// the scenario is an exit test and calls `enable()` first:
///
/// ```swift
/// @Test func pauseSendsPause() async {
///     await #expect(processExitsWith: .success) {
///         await recordingErrors { try await Self.pausing() }
///     }
/// }
///
/// @MainActor static func pausing() async throws {
///     AccessibilityNode.enable()
///     let window = OffscreenWindow(size: …, dark: true, MyView(model: model))
///     defer { window.close() }
///     let pressed = try ControlPress.press("Pause", in: window.host)
///     #expect(pressed.isEnabled)
///     try await eventuallyOnMain("the host to be asked to pause") { model.requests == [.pause] }
/// }
/// ```
///
/// Assert what the press did (the request it sent, the state it left), not only that it pressed.
/// `ModelSettingsPopoverTests` is the worked example.
@MainActor
public enum ControlPress {
    /// Every actionable control under `host`, in tree order, with its frame in screen coordinates.
    /// A control the view hides (`.hidden()`, `.accessibilityHidden(true)`, not drawn in this
    /// state) is not in the tree, so it is not listed.
    public static func controls(in host: NSView) -> [Control] {
        AccessibilityNode.all(under: host).compactMap { node in
            guard let role = node.role, ControlRole.actionable.contains(role) else { return nil }
            return Control(node, role: role)
        }
    }

    /// The controls of the group that says `group` (a segmented control, a card), in tree order.
    public static func controls(in group: String, under host: NSView) -> [Control] {
        guard let node = AccessibilityNode.all(under: host).first(where: { $0.role == ControlRole.group && $0.label == group }) else { return [] }
        return descendants(of: node).compactMap { node in
            guard let role = node.role, ControlRole.actionable.contains(role) else { return nil }
            return Control(node, role: role)
        }
    }

    /// Presses the one control whose accessibility label is `label` (a `Button`'s title or
    /// `.accessibilityLabel`), and returns it, as it was before the press.
    ///
    /// Throws a `ControlPressError` that lists every control the window offers when none matches,
    /// or when the control is disabled, takes no press, or is one of several with that label
    /// (pass `nth` to choose among those, in tree order). `group` limits the search to the
    /// group that says it: `press("Fast", in: "Speed", under: window.host)`.
    @discardableResult
    public static func press(_ label: String, role: String = ControlRole.button, in group: String? = nil, nth: Int? = nil,
                             under host: NSView) throws -> Control {
        let offered = group.map { controls(in: $0, under: host) } ?? controls(in: host)
        let scope = group.map { " in the group \"\($0)\"" } ?? ""
        let matches = offered.filter { $0.role == role && $0.label == label }
        let list = offered.isEmpty ? "none" : offered.map(\.description).joined(separator: "; ")
        guard !matches.isEmpty else {
            throw ControlPressError(reason: .notFound, description: "No \(role) labelled \"\(label)\"\(scope). The window offers: \(list)")
        }
        if matches.count > 1, nth == nil {
            throw ControlPressError(reason: .ambiguous, description: "\(matches.count) \(role)s are labelled \"\(label)\"\(scope) (\(matches.map(\.description).joined(separator: "; "))); pass nth: to choose")
        }
        if let nth, nth >= matches.count {
            throw ControlPressError(reason: .notFound, description: "Only \(matches.count) \(role)s are labelled \"\(label)\"\(scope); nth \(nth) is past them")
        }
        let control = matches[nth ?? 0]
        guard control.isEnabled else {
            throw ControlPressError(reason: .disabled, description: "\(control) is disabled in this state, so it takes no press. The window offers: \(list)")
        }
        guard control.node.press() else {
            throw ControlPressError(reason: .refused, description: "\(control) does not take a press: it is drawn as a control but has no action. The window offers: \(list)")
        }
        return control
    }

    /// The custom actions VoiceOver's action menu offers on the one element whose label contains `text`,
    /// by name: where a row's controls are not separate controls (a row that combines its children, whose
    /// hover buttons are reached through its actions).
    public static func actions(onLabelContaining text: String, under host: NSView) -> [String] {
        AccessibilityNode.all(under: host).first { $0.label?.contains(text) == true && !$0.actionNames.isEmpty }?.actionNames ?? []
    }

    /// Runs the custom action `name` of the one element whose label contains `text`, as VoiceOver's
    /// action menu does, and nothing is posted to the window. Throws a `ControlPressError` listing the
    /// elements that offer actions when none matches, or when none has that action.
    public static func perform(_ name: String, onLabelContaining text: String, under host: NSView) throws {
        let nodes = AccessibilityNode.all(under: host).filter { !$0.actionNames.isEmpty }
        let list = nodes.isEmpty ? "none" : nodes.map { "\"\($0.label ?? "(no label)")\": \($0.actionNames.joined(separator: ", "))" }.joined(separator: "; ")
        let matches = nodes.filter { $0.label?.contains(text) == true }
        guard !matches.isEmpty else {
            throw ControlPressError(reason: .notFound, description: "No element labelled with \"\(text)\" offers actions. The window offers: \(list)")
        }
        guard matches.count == 1 else {
            throw ControlPressError(reason: .ambiguous, description: "\(matches.count) elements labelled with \"\(text)\" offer actions (\(list))")
        }
        guard matches[0].actionNames.contains(name) else {
            throw ControlPressError(reason: .notFound, description: "\"\(text)\" has no action \"\(name)\". The window offers: \(list)")
        }
        guard matches[0].perform(action: name) else {
            throw ControlPressError(reason: .refused, description: "The action \"\(name)\" of \"\(text)\" ran nothing")
        }
    }

    /// The controls whose hit area is smaller than `minimum` in either direction, from the frame the
    /// accessibility tree gives them. Whole-control checks: a control whose background is clear and
    /// has no content shape answers a click only over its label, and its frame says so.
    public static func undersized(_ controls: [Control], minimum: HitArea) -> [Control] {
        controls.filter { $0.frame.width < minimum.minimum - 0.5 || $0.frame.height < minimum.minimum - 0.5 }
    }

    private static func descendants(of node: AccessibilityNode) -> [AccessibilityNode] {
        var found: [AccessibilityNode] = []
        func walk(_ node: AccessibilityNode, depth: Int) {
            guard depth < 40 else { return }
            for child in node.children {
                found.append(child)
                walk(child, depth: depth + 1)
            }
        }
        walk(node, depth: 0)
        return found
    }
}

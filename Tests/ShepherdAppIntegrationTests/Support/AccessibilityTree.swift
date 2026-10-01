import AppKit
import ShepherdTestSupport

/// `AccessibilityNode` and `ControlPress` (Tests/ShepherdTestSupport) over an `OffscreenWindow`:
/// find an element or press a control by what it says, after layout. A test that uses them runs
/// in its own process and calls `AccessibilityNode.enable()` first (see `ControlPress`).
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

    /// Every actionable control in the window with its frame, after layout.
    func controls() -> [Control] {
        layout()
        return ControlPress.controls(in: host)
    }

    /// Presses the control that says `label`, as VoiceOver does, and returns it. Throws, listing
    /// the controls the window offers, when none matches or it takes no press (`ControlPress.press`).
    @discardableResult
    func press(_ label: String, role: String = ControlRole.button, in group: String? = nil, nth: Int? = nil) throws -> Control {
        layout()
        return try ControlPress.press(label, role: role, in: group, nth: nth, under: host)
    }
}

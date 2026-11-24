import Foundation

/// How an agent's computer use tools (Settings ▸ Experiments ▸ Computer use, `shepherd-computer-use.ts`) read as activity lines:
/// "Clicked “More options”", "Read the window", "Opened Safari", and a run of them as "5 actions in Safari". A line names what was
/// acted on when the result says it (`Performed AXPress on [137] AXPopUpButton "More options".`); what was typed is never in a
/// line. Shared with the iOS client, which draws the same lines.
public enum NativeComputerActivity {
    public static let tools: Set<String> = [
        "list_apps", "list_windows", "launch_app", "bring_to_front", "get_window_state", "get_desktop_state", "zoom",
        "click", "double_click", "right_click", "drag", "scroll", "type_text", "press_key", "hotkey", "set_value",
        "invoke_menu", "run_steps", "verify_state", "check_permissions",
    ]

    public static func isTool(_ name: String) -> Bool { tools.contains(name) }

    /// The quoted name a result's first line ends on: `… AXPopUpButton "More options".` is "More options". Nil when it names none.
    public static func subject(fromResult output: String) -> String? {
        guard let line = output.split(separator: "\n", omittingEmptySubsequences: true).first,
              let close = line.lastIndex(of: "\""), let open = line[..<close].lastIndex(of: "\"") else { return nil }
        let name = line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : String(name.prefix(60))
    }

    /// The app a call names in its arguments (`app`, or what `launch_app` opened), when it names one.
    static func app(_ name: String, _ args: [String: Any]?) -> String? {
        func string(_ key: String) -> String? { (args?[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if name == "launch_app", let named = string("name") { return (named as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
        return string("app")
    }

    /// What a call is about, from its arguments: a key chord, a menu path, the number of steps. The result's subject wins.
    static func detail(_ name: String, _ args: [String: Any]?, subject: String?) -> String {
        switch name {
        case "hotkey": return (args?["keys"] as? [String])?.joined(separator: "+") ?? ""
        case "press_key": return (args?["key"] as? String) ?? ""
        case "invoke_menu": return (args?["path"] as? [String])?.joined(separator: " › ") ?? ""
        case "run_steps": return (args?["steps"] as? [Any]).map { "\($0.count) step\($0.count == 1 ? "" : "s")" } ?? ""
        case "scroll": return (args?["direction"] as? String) ?? ""
        case "launch_app": return app(name, args) ?? (args?["bundle_id"] as? String) ?? ""
        default: return subject.map { "“\($0)”" } ?? app(name, args) ?? ""
        }
    }

    /// The line while the call runs: "Clicking “More options”", "Reading the window".
    static func running(_ call: NativeActivityCall) -> String {
        let named = call.detail.isEmpty ? "" : " " + call.detail
        switch call.name {
        case "list_apps": return "Listing apps"
        case "list_windows": return "Listing windows"
        case "launch_app": return "Opening" + (named.isEmpty ? " an app" : named)
        case "bring_to_front": return "Bringing an app to the front"
        case "get_window_state": return "Reading the window"
        case "get_desktop_state": return "Looking at the screen"
        case "zoom": return "Looking closer"
        case "click": return "Clicking" + named
        case "double_click": return "Double-clicking" + named
        case "right_click": return "Right-clicking" + named
        case "drag": return "Dragging"
        case "scroll": return "Scrolling" + named
        case "type_text": return "Typing"
        case "press_key", "hotkey": return "Pressing" + (named.isEmpty ? " a key" : named)
        case "set_value": return "Setting a value"
        case "invoke_menu": return "Choosing" + (named.isEmpty ? " a menu item" : named)
        case "run_steps": return "Running" + (named.isEmpty ? " steps" : named)
        case "verify_state": return "Checking the window"
        case "check_permissions": return "Checking permissions"
        default: return "Using this Mac"
        }
    }

    /// One finished call: "Clicked “More options”", "Read the window".
    static func done(_ call: NativeActivityCall) -> String {
        let named = call.detail.isEmpty ? "" : " " + call.detail
        switch call.name {
        case "list_apps": return "Listed apps"
        case "list_windows": return "Listed windows"
        case "launch_app": return "Opened" + (named.isEmpty ? " an app" : named)
        case "bring_to_front": return "Brought an app to the front"
        case "get_window_state": return "Read the window"
        case "get_desktop_state": return "Looked at the screen"
        case "zoom": return "Looked closer"
        case "click": return "Clicked" + (named.isEmpty ? " an element" : named)
        case "double_click": return "Double-clicked" + (named.isEmpty ? " an element" : named)
        case "right_click": return "Right-clicked" + (named.isEmpty ? " an element" : named)
        case "drag": return "Dragged"
        case "scroll": return "Scrolled" + named
        case "type_text": return "Typed in a field"
        case "press_key", "hotkey": return "Pressed" + (named.isEmpty ? " a key" : named)
        case "set_value": return "Set a value"
        case "invoke_menu": return "Chose" + (named.isEmpty ? " a menu item" : named)
        case "run_steps": return "Ran" + (named.isEmpty ? " steps" : named)
        case "verify_state": return "Checked the window"
        case "check_permissions": return "Checked permissions"
        default: return "Used this Mac"
        }
    }

    /// A call that failed: "Couldn’t click “Delete user”".
    static func failed(_ call: NativeActivityCall) -> String {
        let named = call.detail.isEmpty ? "" : " " + call.detail
        let words: String = switch call.name {
        case "list_apps": "list apps"
        case "list_windows": "list windows"
        case "launch_app": "open" + (named.isEmpty ? " the app" : named)
        case "bring_to_front": "bring the app to the front"
        case "get_window_state", "verify_state": "read the window"
        case "get_desktop_state", "zoom": "see the screen"
        case "click": "click" + named
        case "double_click": "double-click" + named
        case "right_click": "right-click" + named
        case "drag": "drag"
        case "scroll": "scroll"
        case "type_text": "type in the field"
        case "press_key", "hotkey": "press" + (named.isEmpty ? " the key" : named)
        case "set_value": "set the value"
        case "invoke_menu": "choose" + (named.isEmpty ? " the menu item" : named)
        case "run_steps": "run the steps"
        case "check_permissions": "check permissions"
        default: "use this Mac"
        }
        return "Couldn’t " + words
    }

    /// The finished line of a run of calls: one call is its own words; more read "5 actions in Safari" with what came last.
    static func done(_ calls: [NativeActivityCall], duration: String?) -> (String, [String]) {
        guard calls.count > 1 else { return (done(calls[0]), [duration].compactMap { $0 }) }
        let app = calls.compactMap(\.app).last
        let label = nativeCount(calls.count, "action") + (app.map { " in \($0)" } ?? " on this Mac")
        let last = calls.last { $0.name != "get_window_state" && $0.name != "zoom" && !$0.detail.isEmpty }
        return (label, [last.map { "last \($0.detail)" }, duration].compactMap { $0 })
    }
}

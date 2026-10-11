import AppKit
import ShepherdTestSupport

/// Chooses an item of a native SwiftUI `Menu` or popup the way a person does, without posting an event: VoiceOver's "show menu" on the
/// control opens AppKit's own menu window, and the item is performed through its `NSMenu` (the same call a click ends in), which runs
/// the SwiftUI action behind it. `ControlPress` alone presses the button but cannot reach the items, because SwiftUI's accessibility
/// element for a menu button has no children.
@MainActor
enum NativeMenuChoice {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The titles the menu offers, then performs `title`. Throws with every title it found when `title` is not among them.
    @discardableResult
    static func choose(_ title: String, from control: AccessibilityNode) async throws -> [String] {
        typealias Call = @convention(c) (AnyObject, Selector) -> Bool
        let show = NSSelectorFromString("accessibilityPerformShowMenu")
        guard control.object.responds(to: show),
              unsafeBitCast(control.object.method(for: show), to: Call.self)(control.object, show) else {
            throw Failure(description: "The control does not open a menu.")
        }
        defer { for window in menuWindows() where window.isVisible { window.orderOut(nil) } }
        var items: [NSMenuItem] = []
        try await eventuallyOnMain("the menu to show items before choosing \(title)", timeout: .seconds(5)) {
            items = menuItems(in: menuWindows().filter(\.isVisible))
            return !items.isEmpty
        }
        let titles = items.map(\.title)
        guard let item = items.first(where: { $0.title == title }), let menu = item.menu else {
            throw Failure(description: "No menu item \"\(title)\". The menu offers: \(titles).")
        }
        guard item.isEnabled else { throw Failure(description: "\"\(title)\" is disabled. The menu offers: \(titles).") }
        menu.performActionForItem(at: menu.index(of: item))
        return titles
    }

    private static func menuWindows() -> [NSWindow] {
        NSApp.windows.filter { String(describing: type(of: $0)) == "NSPopupMenuWindow" }
    }

    private static func menuItems(in windows: [NSWindow]) -> [NSMenuItem] {
        func rows(_ view: NSView) -> [NSView] {
            (String(describing: type(of: view)) == "NSContextMenuItemView" ? [view] : []) + view.subviews.flatMap(rows)
        }
        return windows.compactMap(\.contentView).flatMap(rows)
            .compactMap { $0.value(forKey: "menuItem") as? NSMenuItem }.filter { !$0.isSeparatorItem }
    }
}

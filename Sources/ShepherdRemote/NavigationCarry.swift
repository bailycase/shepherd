import Foundation

/// Navigation decisions for the compact and regular shells. The caller applies them to the
/// window, including presenting the pane and logging the palette's dismissal.
public enum NavigationCarry {
    /// Carry the active compact stack to regular width, before taking any pane screens.
    public static func widen(tab: MobileTab, path: [MobileRoute]) -> (selection: AgentRef?, path: [MobileRoute]) {
        if let root = tab.padRoot { return (nil, [root] + path) }
        if case .thread(let ref)? = path.first { return (ref, Array(path.dropFirst())) }
        return (nil, path)
    }

    /// Move only the top run of pane screens belonging to the thread beneath them. The top
    /// route carries details such as the file or run to reveal in the side pane.
    public static func takePaneScreens(selection: AgentRef?, path: [MobileRoute])
        -> (path: [MobileRoute], route: MobileRoute, tab: PadSidePaneTab)? {
        let pushed = path.lastIndex { if case .thread = $0 { true } else { false } }
        let thread: AgentRef? = if let pushed, case .thread(let ref) = path[pushed] { ref } else { selection }
        guard let thread else { return nil }
        let tabs = path.indices.map { index in
            index > (pushed ?? -1) && path[index].thread == thread ? path[index].sidePaneTab : nil
        }
        guard let (keep, tab) = PadSplitLayout.unfold(tabs), let top = path.last else { return nil }
        return (Array(path.prefix(keep)), top, tab)
    }

    /// The last screen owned by a tab picks the compact stack. Home keeps the screens under
    /// it; other tabs start at their last owned screen, omitting any tab root.
    public static func narrow(selection: AgentRef?, path: [MobileRoute], presented: MobileRoute?)
        -> (tab: MobileTab, path: [MobileRoute], search: MobileRoute?) {
        let stack = (selection.map { [MobileRoute.thread($0)] } ?? []) + path
        let search: MobileRoute? = if case .search(.palette(let query))? = presented {
            .search(.search(query: query))
        } else {
            nil
        }
        if let start = stack.lastIndex(where: { MobileTab.owner(of: $0) != nil }), let owner = MobileTab.owner(of: stack[start]) {
            return (owner, owner == .home ? stack : Array(stack[start...].drop(while: \.isTabRoot)), search)
        }
        return (.home, stack, search)
    }

    public static func removing(host: UUID, from path: [MobileRoute]) -> [MobileRoute] {
        path.filter { $0.host != host }
    }
}

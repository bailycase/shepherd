import SwiftUI
import ShepherdCore
import ShepherdUI

/// Each thread's side pane (docs/design/side-pane-changes.md › Side pane): whether it is open, its tab, what pi opened
/// in it that you have not looked at, which subagent it inspects, and the pane's width.
/// Device-local view state: the width persists, the rest does not.
@MainActor @Observable
final class RightPaneState {
    nonisolated static let widthKey = "shepherd.rightPaneWidth"
    var runByAgent: [AgentID: String] = [:]
    var remoteRuns: [RemoteAgentRef: String] = [:]
    /// Threads whose pane shows its tabs (an inspected run may cover them).
    var open: Set<SidePaneOwner> = []
    /// Each pane's tab, while it is not the first.
    var tabs: [SidePaneOwner: SidePaneTab] = [:]
    /// Tabs the agent opened something in since you last showed them.
    var news: [SidePaneOwner: Set<SidePaneTab>] = [:]
    /// Panes over their whole layout (ChangesWide), the thread hidden under them.
    var maximized: Set<SidePaneOwner> = []
    /// A run whose Steer field takes focus when its inspector shows it (the tray's Steer),
    /// until it does.
    var steerRun: String?
    /// Zero until the user resizes: the pane then takes `defaultWidth`.
    var width: CGFloat {
        didSet { defaults.set(Double(width), forKey: widthKey) }
    }
    /// The width before the user resizes (a thread's 600; a Project page's 480 box less its divider).
    let defaultWidth: CGFloat
    @ObservationIgnored private let widthKey: String
    @ObservationIgnored private let defaults: UserDefaults

    init(widthKey: String = RightPaneState.widthKey, defaultWidth: CGFloat = AppLayout.paneDefaultWidth,
         defaults: UserDefaults = .standard) {
        self.widthKey = widthKey
        self.defaultWidth = defaultWidth
        self.defaults = defaults
        let saved = defaults.double(forKey: widthKey)
        width = saved >= AppLayout.paneMinWidth ? CGFloat(saved) : 0
    }

    func toggle(agentID: AgentID, runID: String) {
        if runByAgent[agentID] == runID { runByAgent.removeValue(forKey: agentID) } else { runByAgent[agentID] = runID }
    }

    func tab(for owner: SidePaneOwner) -> SidePaneTab { tabs[owner] ?? SidePaneTab.allCases[0] }

    func run(for owner: SidePaneOwner) -> String? {
        switch owner {
        case .local(let id): runByAgent[id]
        case .remote(let ref): remoteRuns[ref]
        }
    }

    /// pi opened something in `tab`.
    func addNews(_ owner: SidePaneOwner, _ tab: SidePaneTab) {
        if news[owner]?.contains(tab) != true { news[owner, default: []].insert(tab) }
    }

    func clearNews(_ owner: SidePaneOwner, _ tab: SidePaneTab) {
        guard news[owner]?.contains(tab) == true else { return }
        news[owner]?.remove(tab)
        if news[owner]?.isEmpty == true { news.removeValue(forKey: owner) }
    }

    /// The thread is gone: its pane with it.
    func forget(_ owner: SidePaneOwner) {
        if open.contains(owner) { open.remove(owner) }
        if tabs[owner] != nil { tabs.removeValue(forKey: owner) }
        if news[owner] != nil { news.removeValue(forKey: owner) }
        if maximized.contains(owner) { maximized.remove(owner) }
    }
}

/// The agent's layout (its thread and any terminal panes) on the left, the side pane (its tabs, or
/// an inspected subagent) beside it (PaneStates: 380pt at least, 600 default, at most half the
/// column, the drag handle on its left edge). In a column too narrow to keep the layout at 400pt, the pane overlays it from the
/// trailing edge instead of squeezing it (`ShellLayout`).
///
/// The pane slides in from the trailing edge and back out (`.pane`; a cross-fade under Reduce
/// Motion) whichever path opens it: ⇧⌘B, ⌃1, ⌘I, the header's button, a thread link. Beside a docked pane the thread takes its new width at
/// once, as the slide starts: a long thread relaid out on every frame of the slide drops frames.
/// Docked or overlaid, nothing in the thread rides the slide.
/// Resizing (the handle, a window resize, a docked ⇄ overlaid flip) never animates.
struct RightPaneSplit<Content: View, Pane: View>: View {
    @Bindable var state: RightPaneState
    let showPane: Bool
    /// The pane over the whole layout (ChangesWide): the thread stays mounted under it, hidden.
    var maximized = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let pane: () -> Pane
    /// The drag under way at the handle: only this split previews it, so hidden layouts never follow it frame by frame.
    @State private var drag: RightPaneDrag?

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let layout = RightPaneDrag.layout(drag, state: state, containerWidth: total)
            let docked = layout.mode == .docked
            let covers = showPane && maximized
            let paneWidth = covers ? total : layout.width
            let contentWidth = showPane && docked && !covers ? layout.contentWidth : total
            // The thread stays the first child in both modes, so opening a pane never remounts it.
            ZStack(alignment: .topLeading) {
                content()
                    .frame(width: contentWidth, height: geo.size.height)
                    // Maximized, the thread is hidden, never unmounted: restoring is a flip.
                    .opacity(covers ? 0 : 1)
                    .allowsHitTesting(!covers)
                    .accessibilityHidden(covers)
                    .animation(nil, value: contentWidth)
                    // Under an overlaid pane the width holds, but what the thread changes in the
                    // same update (a streamed row, the inspected card) must not ride the slide.
                    .animation(nil, value: showPane)
                if showPane {
                    HStack(spacing: 0) {
                        if !covers { handle(total: total, width: layout.width) }
                        pane()
                            .frame(width: paneWidth, height: geo.size.height)
                            .clipped()
                    }
                    .shFloatBackground(Color.sh.bgWindow, floating: !docked && !covers)
                    .offset(x: covers ? 0 : max(0, total - layout.width - AppLayout.dividerWidth))
                    .shTransition(.pane, edge: .trailing)
                }
            }
            .shAnimation(.pane, value: showPane)
            .shAnimation(.pane, value: covers)
        }
        .coordinateSpace(.named("right-pane"))
    }

    /// The pane's leading edge and drag handle (adjustable with VoiceOver); a double-click takes
    /// the pane to half the column.
    private func handle(total: CGFloat, width: CGFloat) -> some View {
        Color.sh.lineSubtle
            .frame(width: AppLayout.dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: AppLayout.resizeHandleWidth)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("right-pane"))
                        .onChanged { drag = RightPaneDrag(pointerX: $0.location.x, containerWidth: total) }
                        .onEnded { _ in
                            drag?.end(in: state, containerWidth: total)
                            drag = nil
                        })
                    // Double-click: as wide as the pane goes, half the column (PaneStates).
                    .simultaneousGesture(TapGesture(count: 2).onEnded { state.width = ShellLayout.widestRightPane(containerWidth: total) })
            }
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel("Pane width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? AppLayout.paneAdjustStep : direction == .decrement ? -AppLayout.paneAdjustStep : 0
                state.width = ShellLayout.rightPane(containerWidth: total, preferredWidth: width + step,
                                                    defaultWidth: state.defaultWidth).width
            }
    }
}

/// One drag of a side pane's divider, as the handle's gesture reports it, in the split's own coordinates: the pointer's x previews
/// the pane as wide as what lies right of it (unbounded; the layout bounds what is drawn), and letting go saves that width
/// within the split's bounds. The pointer's position, not a sum of moves, decides, so a drag's steps never accumulate error.
struct RightPaneDrag: Equatable {
    let width: CGFloat

    init(pointerX: CGFloat, containerWidth: CGFloat) {
        width = containerWidth - pointerX
    }

    /// The split's layout: the drag's width while one is under way, else the saved one, within the split's bounds.
    @MainActor static func layout(_ drag: RightPaneDrag?, state: RightPaneState, containerWidth: CGFloat) -> ShellLayout.Pane {
        ShellLayout.rightPane(containerWidth: containerWidth, preferredWidth: drag?.width ?? state.width, defaultWidth: state.defaultWidth)
    }

    /// Letting go: the width the layout drew for the drag, saved (and persisted) as the pane's.
    @MainActor func end(in state: RightPaneState, containerWidth: CGFloat) {
        state.width = Self.layout(self, state: state, containerWidth: containerWidth).width
    }
}

/// What the side pane shows: a run of the subagent inspector, or a tab (Changes with its review
/// session).
enum RightPaneShowing: Hashable {
    case inspector(runID: String)
    /// A tab, keyed by what it shows (the Changes tab's review).
    case tab(SidePaneTab, UUID?)
}

/// The side pane's content. The inspector and the tabs share the slot: when one replaces the
/// other, the inspector steps to another run, or a new review replaces one, the content
/// cross-fades (`.content`) while the pane itself stays put. Give each child
/// `.shTransition(.content)` and an identity that follows `showing`.
struct RightPaneSlot<Content: View>: View {
    let showing: RightPaneShowing?
    @ViewBuilder let content: () -> Content

    var body: some View {
        // A ZStack, so the outgoing and incoming content overlap while they cross-fade.
        ZStack { content() }
            .shAnimation(.content, value: showing)
    }
}

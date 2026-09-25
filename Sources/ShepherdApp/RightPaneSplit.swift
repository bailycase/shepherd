import SwiftUI
import ShepherdCore
import ShepherdUI

/// Each thread's side pane (DESIGN.md › Side pane): whether it is open, its tab, what pi opened
/// in it that you have not looked at, which subagent it inspects, and the pane's width.
/// Device-local view state: the width persists, the rest does not.
@MainActor @Observable
final class RightPaneState {
    static let widthKey = "shepherd.rightPaneWidth"
    var runByAgent: [AgentID: String] = [:]
    var remoteRuns: [RemoteAgentRef: String] = [:]
    /// Threads whose pane shows its tabs (an inspected run may cover them).
    var open: Set<SidePaneOwner> = []
    /// Each pane's tab, while it is not the first.
    var tabs: [SidePaneOwner: SidePaneTab] = [:]
    /// Tabs pi opened something in since you last showed them.
    var news: [SidePaneOwner: Set<SidePaneTab>] = [:]
    /// Zero until the user resizes: the pane then takes the 600pt default.
    var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: Self.widthKey) }
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.widthKey)
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
    @ViewBuilder let content: () -> Content
    @ViewBuilder let pane: () -> Pane
    @State private var liveWidth: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let layout = ShellLayout.rightPane(containerWidth: total, preferredWidth: liveWidth ?? state.width)
            let docked = layout.mode == .docked
            let contentWidth = showPane && docked ? layout.contentWidth : total
            // The thread stays the first child in both modes, so opening a pane never remounts it.
            ZStack(alignment: .topLeading) {
                content()
                    .frame(width: contentWidth, height: geo.size.height)
                    .animation(nil, value: contentWidth)
                    // Under an overlaid pane the width holds, but what the thread changes in the
                    // same update (a streamed row, the inspected card) must not ride the slide.
                    .animation(nil, value: showPane)
                if showPane {
                    HStack(spacing: 0) {
                        handle(total: total, width: layout.width)
                        pane()
                            .frame(width: layout.width, height: geo.size.height)
                            .clipped()
                    }
                    .background(Color.nw.bgWindow)
                    .nwFloatShadow(!docked)
                    .offset(x: max(0, total - layout.width - AppLayout.dividerWidth))
                    .nwTransition(.pane, edge: .trailing)
                }
            }
            .nwAnimation(.pane, value: showPane)
        }
        .coordinateSpace(.named("right-pane"))
    }

    /// The pane's leading edge and drag handle (adjustable with VoiceOver).
    private func handle(total: CGFloat, width: CGFloat) -> some View {
        Color.nw.lineSubtle
            .frame(width: AppLayout.dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: AppLayout.resizeHandleWidth)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("right-pane"))
                        .onChanged { liveWidth = total - $0.location.x }
                        .onEnded { _ in
                            if let liveWidth {
                                state.width = ShellLayout.rightPane(containerWidth: total, preferredWidth: liveWidth).width
                            }
                            liveWidth = nil
                        })
            }
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel("Pane width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? AppLayout.paneAdjustStep : direction == .decrement ? -AppLayout.paneAdjustStep : 0
                state.width = ShellLayout.rightPane(containerWidth: total, preferredWidth: width + step).width
            }
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
/// `.nwTransition(.content)` and an identity that follows `showing`.
struct RightPaneSlot<Content: View>: View {
    let showing: RightPaneShowing?
    @ViewBuilder let content: () -> Content

    var body: some View {
        // A ZStack, so the outgoing and incoming content overlap while they cross-fade.
        ZStack { content() }
            .nwAnimation(.content, value: showing)
    }
}

import SwiftUI
import ShepherdCore
import ShepherdUI
import ShepherdRemote

/// Each thread's side pane: whether it is open, its tab, what pi opened
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
    /// The board each pane's Design tab shows (ThreadBoardPane): the last one opened from a card.
    var boards: [SidePaneOwner: DesignReferenceChips.Board] = [:]
    /// Panes over their whole layout (ChangesWide), the thread hidden under them.
    var maximized: Set<SidePaneOwner> = []
    /// A run whose Steer field takes focus when its inspector shows it (the tray's Steer),
    /// until it does.
    var steerRun: String?
    /// Zero until the user resizes: the pane then takes `defaultWidth`.
    var width: CGFloat {
        didSet { defaults.set(Double(width), forKey: widthKey) }
    }
    /// What a thread's pane card takes from the column beside the thread (its width and edge), published by the
    /// layout on screen; 0 while none shows. The toolbar ends where it begins (GXSidePane).
    var reserved: CGFloat = 0
    /// The width before the user resizes (a thread's 720; a Project page's 480 box less its divider).
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
/// an inspected subagent, a card of its own under the toolbar: `inspector`) beside it (PaneStates: 380pt at least, 600 default, at most half the
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
    /// The pane is a card beside the thread, 8pt in from the window's top, bottom and trailing edges and from the thread
    /// (a thread's, GXSidePane); else a full-height column behind a 1pt divider (a Project page's).
    var card = false
    /// The pane shows a subagent: its card floats beside the thread from just under the toolbar to the bottom, in from the
    /// window's edge (GXSubagents' `.insp`), the toolbar keeping the column's whole width. Taken only with `card`.
    var inspector = false
    /// The layout is on screen: only it tells the toolbar how much of the column the card takes.
    var publishesReserve = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let pane: () -> Pane
    /// The toolbar's height, over the top of the column (a thread's card runs up beside it): the thread starts under it.
    @Environment(\.workspaceTopInset) private var topInset
    /// The drag under way at the handle: only this split previews it, so hidden layouts never follow it frame by frame.
    @State private var drag: RightPaneDrag?

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let floating = card && inspector
            let edge = floating ? AppLayout.inspectorCardEdge : card ? AppLayout.paneCardEdge : AppLayout.dividerWidth
            // The inspector is a fixed-size card (the board's 404pt); a tab's pane is the width the user dragged it to.
            let layout = floating ? ShellLayout.rightPane(containerWidth: total, preferredWidth: AppLayout.inspectorCardWidth, edge: edge)
                : RightPaneDrag.layout(drag, state: state, containerWidth: total, edge: edge)
            let docked = layout.mode == .docked
            let covers = showPane && maximized
            let paneWidth = covers ? total - (card ? AppLayout.paneCardEdge : 0) : layout.width
            let contentWidth = showPane && docked && !covers ? layout.contentWidth : total
            // The toolbar gives way to a tab's card, which runs up beside it; the inspector's card sits under it.
            let reserve = card && showPane && !covers && !floating ? layout.width + edge : 0
            let cardTop = floating ? topInset + SHSidePaneMetrics.cardInset : SHSidePaneMetrics.cardInset
            let cardBottom = floating ? AppLayout.inspectorCardBottom : SHSidePaneMetrics.cardInset
            // The thread stays the first child in both modes, so opening a pane never remounts it.
            ZStack(alignment: .topLeading) {
                content()
                    .padding(.top, card ? topInset : 0)
                    // The boards' window padding: the thread keeps 8pt from the window's bottom, and from its right edge while no pane is beside it.
                    .padding(.bottom, card && !floating ? SHSidePaneMetrics.cardInset : 0)
                    .frame(width: contentWidth - (card && !(showPane && docked && !covers) ? SHSidePaneMetrics.cardInset : 0),
                           height: geo.size.height, alignment: .topLeading)
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
                        if !covers && !floating { handle(total: total, width: layout.width, edge: edge) }
                        if floating { Color.clear.frame(width: SHSidePaneMetrics.cardGap) }
                        if card {
                            // The card: raised, rounded and lifted (the boards' `.pane`), the toolbar's row inside it.
                            pane()
                                .frame(width: paneWidth, height: max(0, geo.size.height - cardTop - cardBottom))
                                // The inspector's content stops short of the corners and scrolls: no rounded clip over it.
                                .shCard(lift: true, roundsContent: !floating)
                                .padding(.top, cardTop)
                                .padding(.bottom, cardBottom)
                                .padding(.leading, covers ? SHSidePaneMetrics.cardGap : 0)
                                .padding(.trailing, floating ? AppLayout.inspectorCardTrailing : SHSidePaneMetrics.cardInset)
                        } else {
                            pane()
                                .frame(width: paneWidth, height: geo.size.height)
                                .clipped()
                        }
                    }
                    .shFloatBackground(card ? Color.clear : Color.sh.bgWindow, floating: !card && !docked && !covers)
                    .offset(x: covers ? 0 : max(0, total - layout.width - edge))
                    .shTransition(.pane, edge: .trailing)
                }
            }
            .onChange(of: reserve, initial: true) { _, new in
                if publishesReserve, state.reserved != new { state.reserved = new }
            }
            .onChange(of: publishesReserve) { _, now in
                if now { state.reserved = reserve }
            }
            .shAnimation(.pane, value: showPane)
            .shAnimation(.pane, value: covers)
        }
        .coordinateSpace(.named("right-pane"))
    }

    /// The pane's leading edge and drag handle (adjustable with VoiceOver); a double-click takes
    /// the pane to half the column.
    private func handle(total: CGFloat, width: CGFloat, edge: CGFloat) -> some View {
        // A card's handle is the clear gap before it (the boards draw no divider).
        (card ? Color.clear : Color.sh.lineSubtle)
            .frame(width: card ? SHSidePaneMetrics.cardGap : AppLayout.dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: AppLayout.resizeHandleWidth)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("right-pane"))
                        .onChanged { drag = RightPaneDrag(pointerX: $0.location.x, containerWidth: total,
                                                                pointerOffset: card ? RightPaneDrag.cardPointerOffset : 0) }
                        .onEnded { _ in
                            drag?.end(in: state, containerWidth: total, edge: edge)
                            drag = nil
                        })
                    // Double-click: as wide as the pane goes, half the column (PaneStates).
                    .simultaneousGesture(TapGesture(count: 2).onEnded { state.width = ShellLayout.widestRightPane(containerWidth: total, edge: edge) })
            }
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel("Pane width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? AppLayout.paneAdjustStep : direction == .decrement ? -AppLayout.paneAdjustStep : 0
                state.width = ShellLayout.rightPane(containerWidth: total, preferredWidth: width + step,
                                                    defaultWidth: state.defaultWidth, edge: edge).width
            }
    }
}

/// One drag of a side pane's divider, as the handle's gesture reports it, in the split's own coordinates: the pointer's x previews
/// the pane as wide as what lies right of it (unbounded; the layout bounds what is drawn), and letting go saves that width
/// within the split's bounds. The pointer's position, not a sum of moves, decides, so a drag's steps never accumulate error.
struct RightPaneDrag: Equatable {
    let width: CGFloat

    /// What lies right of the pointer and is not the pane: a card's inset and half its gap (the handle is the gap's middle).
    static let cardPointerOffset = SHSidePaneMetrics.cardInset + SHSidePaneMetrics.cardGap / 2

    init(pointerX: CGFloat, containerWidth: CGFloat, pointerOffset: CGFloat = 0) {
        width = containerWidth - pointerX - pointerOffset
    }

    /// The split's layout: the drag's width while one is under way, else the saved one, within the split's bounds.
    @MainActor static func layout(_ drag: RightPaneDrag?, state: RightPaneState, containerWidth: CGFloat,
                                  edge: CGFloat = AppLayout.dividerWidth) -> ShellLayout.Pane {
        ShellLayout.rightPane(containerWidth: containerWidth, preferredWidth: drag?.width ?? state.width, defaultWidth: state.defaultWidth, edge: edge)
    }

    /// Letting go: the width the layout drew for the drag, saved (and persisted) as the pane's.
    @MainActor func end(in state: RightPaneState, containerWidth: CGFloat, edge: CGFloat = AppLayout.dividerWidth) {
        state.width = Self.layout(self, state: state, containerWidth: containerWidth, edge: edge).width
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

extension EnvironmentValues {
    /// The toolbar's height over the top of the workspace, where a thread's pane card runs up beside the toolbar and the thread
    /// starts under it (`RightPaneSplit`); 0 where the column starts under the toolbar.
    @Entry var workspaceTopInset: CGFloat = 0
}

extension View {
    /// Starts under the toolbar, as a layout without a pane card does (`workspaceTopInset`).
    func underWorkspaceToolbar() -> some View { modifier(UnderWorkspaceToolbar()) }
}

private struct UnderWorkspaceToolbar: ViewModifier {
    @Environment(\.workspaceTopInset) private var inset

    func body(content: Content) -> some View { content.padding(.top, inset) }
}

import SwiftUI
import ShepherdCore
import ShepherdUI

/// Which subagent each agent's right pane is inspecting, and the pane's width. Device-local
/// view state: the width persists, the selection does not.
@MainActor @Observable
final class RightPaneState {
    static let widthKey = "shepherd.rightPaneWidth"
    var runByAgent: [AgentID: String] = [:]
    var remoteRuns: [RemoteAgentRef: String] = [:]
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
}

/// The thread on the left, the right pane (inspector or review) beside it (Navigation board:
/// 480–50%, 600 default, the drag handle on its left edge). In a column too narrow to keep the
/// thread at 400pt, the pane overlays the thread instead of squeezing it (`ShellLayout`).
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
            // The thread stays the first child in both modes, so opening a pane never remounts it.
            ZStack(alignment: .topLeading) {
                content()
                    .frame(width: showPane && docked ? layout.contentWidth : total, height: geo.size.height)
                if showPane {
                    HStack(spacing: 0) {
                        handle(total: total)
                        pane()
                            .frame(width: layout.width, height: geo.size.height)
                            .clipped()
                    }
                    .background(Color.nw.bgWindow)
                    .shadow(color: docked ? .clear : Color.nw.popoverShadow, radius: 16)
                    .offset(x: max(0, total - layout.width - 1))
                }
            }
        }
        .coordinateSpace(.named("right-pane"))
    }

    private func handle(total: CGFloat) -> some View {
        Color.nw.lineSubtle
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
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
            .accessibilityLabel("Resize pane")
    }
}

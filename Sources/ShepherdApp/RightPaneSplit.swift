import SwiftUI
import AppKit
import ShepherdCore
import ShepherdDesign

/// Which subagent each agent's right pane is inspecting, and the pane's width. Device-local
/// view state: the width persists, the selection does not.
@MainActor @Observable
final class RightPaneState {
    static let widthKey = "shepherd.rightPaneWidth"
    var runByAgent: [AgentID: String] = [:]
    var remoteRuns: [RemoteAgentRef: String] = [:]
    /// Zero until the user resizes: the pane then takes the spec's 600pt default.
    var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: Self.widthKey) }
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.widthKey)
        width = saved >= Metrics.paneMinWidth ? CGFloat(saved) : 0
    }

    func toggle(agentID: AgentID, runID: String) {
        if runByAgent[agentID] == runID { runByAgent.removeValue(forKey: agentID) } else { runByAgent[agentID] = runID }
    }

    /// The pane width for a window of `total`: 600 by default, at least 480, at most half.
    func resolvedWidth(total: CGFloat, live: CGFloat? = nil) -> CGFloat {
        let preferred = live ?? (width > 0 ? width : Metrics.paneDefaultWidth)
        return min(max(preferred, Metrics.paneMinWidth), max(Metrics.paneMinWidth, total * Metrics.paneMaxFraction))
    }
}

/// The thread on the left, the right pane (inspector or review) docked beside it. The pane's
/// left edge is the drag handle.
struct RightPaneSplit<Content: View, Pane: View>: View {
    @Bindable var state: RightPaneState
    let showPane: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let pane: () -> Pane
    @State private var liveWidth: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let width = state.resolvedWidth(total: total, live: liveWidth)
            HStack(spacing: 0) {
                content().frame(width: showPane ? total - width - 1 : total)
                if showPane {
                    Tokens.border.frame(width: 1)
                        .overlay {
                            Color.clear.frame(width: 9).contentShape(Rectangle())
                                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("right-pane"))
                                    .onChanged { liveWidth = total - $0.location.x }
                                    .onEnded { _ in
                                        if let liveWidth { state.width = state.resolvedWidth(total: total, live: liveWidth) }
                                        liveWidth = nil
                                    })
                        }
                        .zIndex(1)
                        .accessibilityLabel("Resize pane")
                    pane().frame(width: width)
                }
            }
        }
        .coordinateSpace(name: "right-pane")
    }
}

import SwiftUI

/// The subagent glyph (`arrow.triangle.branch`), in its run's state color.
public struct NWBranchGlyph: View {
    let state: AgentState
    let size: CGFloat
    let color: Color?

    /// `color` overrides the state's color.
    public init(_ state: AgentState, size: CGFloat = 14, color: Color? = nil) {
        self.state = state
        self.size = size
        self.color = color
    }

    public var body: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: size - 3, weight: .medium))
            .foregroundStyle(color ?? state.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

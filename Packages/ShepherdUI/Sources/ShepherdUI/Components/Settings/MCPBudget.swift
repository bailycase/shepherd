import SwiftUI

/// "In every prompt ~200 tokens": what the MCP servers cost the agent's prompt, a bar, and a
/// line saying why.
public struct MCPBudget: View {
    let tokens: String
    let fraction: Double
    let note: String

    /// `fraction` is how full the bar is, 0…1.
    public init(tokens: String, fraction: Double, note: String) {
        self.tokens = tokens
        self.fraction = fraction
        self.note = note
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.m) {
            HStack {
                Text("In every prompt")
                    .font(.nwSans(NWSkillMetrics.optionTitleSize, .medium))
                    .foregroundStyle(nw.textPrimary)
                Spacer(minLength: NW.Space.m)
                Text(tokens)
                    .font(.nwMono(NWSkillMetrics.optionNoteSize))
                    .foregroundStyle(nw.textSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(nw.lineSubtle)
                    Capsule().fill(nw.running)
                        .frame(width: max(NWMCPMetrics.budgetHeight * 3, proxy.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: NWMCPMetrics.budgetHeight)
            .accessibilityHidden(true)
            Text(note)
                .nwText(size: NWSkillMetrics.optionNoteSize, lineHeight: NWSkillMetrics.optionNoteLineHeight)
                .foregroundStyle(nw.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, NW.Space.l)
        .padding(.horizontal, NW.Space.l + NW.Space.xxs)
        .background(nw.bgWindow, in: RoundedRectangle(cornerRadius: NWMCPMetrics.cardRadius))
        .nwBorder(nw.lineSubtle, radius: NWMCPMetrics.cardRadius)
        .accessibilityElement(children: .combine)
    }
}

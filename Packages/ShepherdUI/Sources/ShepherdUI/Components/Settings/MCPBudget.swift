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
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack {
                Text("In every prompt")
                    .font(.shSans(SHSkillMetrics.optionTitleSize, .medium))
                    .foregroundStyle(sh.textPrimary)
                Spacer(minLength: SH.Space.m)
                Text(tokens)
                    .font(.shMono(SHSkillMetrics.optionNoteSize))
                    .foregroundStyle(sh.textSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(sh.lineSubtle)
                    Capsule().fill(sh.running)
                        .frame(width: max(SHMCPMetrics.budgetHeight * 3, proxy.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: SHMCPMetrics.budgetHeight)
            .accessibilityHidden(true)
            Text(note)
                .shText(size: SHSkillMetrics.optionNoteSize, lineHeight: SHSkillMetrics.optionNoteLineHeight)
                .foregroundStyle(sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.l + SH.Space.xxs)
        .background(sh.bgWindow, in: RoundedRectangle(cornerRadius: SHMCPMetrics.cardRadius))
        .shBorder(sh.lineSubtle, radius: SHMCPMetrics.cardRadius)
        .accessibilityElement(children: .combine)
    }
}

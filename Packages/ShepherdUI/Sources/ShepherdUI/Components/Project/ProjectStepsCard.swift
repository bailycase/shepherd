import SwiftUI

/// A worker's own plan as the boards draw it (ProjectLead-ThreadRunning, -Resolved): a bordered list named "Steps", one row per step.
/// It takes plain values from the typed native plan and parses nothing.
public struct SHLeadStepsCard: View {
    public enum State: Sendable, Equatable { case pending, current, done, failed }

    public struct Step: Sendable, Equatable {
        public let text: String
        public let state: State
        public init(text: String, state: State) { self.text = text; self.state = state }
    }

    let steps: [Step]

    public init(steps: [Step]) { self.steps = steps }

    public var body: some View {
        VStack(alignment: .leading, spacing: SHLeadMetrics.stepsGap) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: SH.Space.m) {
                    glyph(step.state).frame(width: SHLeadMetrics.stepsGlyphBox, height: SHLeadMetrics.stepsGlyphBox).accessibilityHidden(true)
                    Text(step.text).font(.sh(.ui, weight: .regular)).foregroundStyle(step.state == .pending ? Color.sh.textSecondary : Color.sh.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(Self.word(step.state))
            }
        }
        .padding(SHLeadMetrics.stepsPadding + SHLeadMetrics.stepsBorder)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shBorder(Color.sh.lineStrong, radius: SHLeadMetrics.stepsRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Steps")
    }

    static func word(_ state: State) -> String {
        switch state {
        case .pending: "pending"
        case .current: "in progress"
        case .done: "done"
        case .failed: "failed"
        }
    }

    @ViewBuilder private func glyph(_ state: State) -> some View {
        switch state {
        case .current:
            // `border-right-color: transparent` on a circle leaves a 90 degree gap centred on 3 o'clock.
            Circle().trim(from: 0.125, to: 0.875)
                .stroke(Color.sh.textSecondary, style: StrokeStyle(lineWidth: SHLeadMetrics.stepsCurrentStroke, lineCap: .butt))
                .frame(width: SHLeadMetrics.stepsRing, height: SHLeadMetrics.stepsRing)
        case .pending:
            Circle().stroke(Color.sh.textTertiary, style: StrokeStyle(lineWidth: SHLeadMetrics.stepsPendingStroke, dash: SHLeadMetrics.stepsPendingDash))
                .frame(width: SHLeadMetrics.stepsRing, height: SHLeadMetrics.stepsRing)
        case .done:
            Image(systemName: SHGlyph.resolved.symbolName).font(.system(size: SHLeadMetrics.stepsGlyphBox)).foregroundStyle(Color.sh.textSecondary)
        case .failed:
            // The boards draw no failed step; a plan the worker marked failed gets the same outline circle with a cross, in `failed`.
            Image(systemName: SHGlyph.failedStep.symbolName).font(.system(size: SHLeadMetrics.stepsGlyphBox)).foregroundStyle(Color.sh.failed)
        }
    }
}

/// The live line a Project's thread ends in while its turn works (ProjectLead-Started "Starting threads", -ThreadRunning
/// "Working · 52s"): a 14pt ellipsis glyph and the words in `caption` on `textTertiary`, 8pt apart. The words come from the
/// owner's typed state (`ProjectRunStatus`), never from the text of a reply.
public struct SHLeadStatusLine: View {
    let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: SH.Space.m) {
            Image(systemName: "ellipsis").font(.system(size: SHLeadMetrics.footerGlyph))
                .frame(width: SHLeadMetrics.footerGlyph, height: SHLeadMetrics.footerGlyph).accessibilityHidden(true)
            Text(text).font(.sh(.caption))
        }
        .foregroundStyle(Color.sh.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

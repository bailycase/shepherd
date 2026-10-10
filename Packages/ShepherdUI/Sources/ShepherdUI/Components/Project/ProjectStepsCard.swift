import SwiftUI

/// A worker's own plan as the boards draw it (ProjectLead-ThreadRunning, -Resolved): a bordered list named "Steps", one row per step.
/// It takes plain values from the typed native plan and parses nothing.
public struct NWLeadStepsCard: View {
    public enum State: Sendable, Equatable { case pending, current, done, failed }

    public struct Step: Sendable, Equatable {
        public let text: String
        public let state: State
        public init(text: String, state: State) { self.text = text; self.state = state }
    }

    let steps: [Step]

    public init(steps: [Step]) { self.steps = steps }

    public var body: some View {
        VStack(alignment: .leading, spacing: NWLeadMetrics.stepsGap) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: NW.Space.m) {
                    glyph(step.state).frame(width: NWLeadMetrics.stepsGlyphBox, height: NWLeadMetrics.stepsGlyphBox).accessibilityHidden(true)
                    Text(step.text).font(.nw(.ui, weight: .regular)).foregroundStyle(step.state == .pending ? Color.nw.textSecondary : Color.nw.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(Self.word(step.state))
            }
        }
        .padding(NWLeadMetrics.stepsPadding + NWLeadMetrics.stepsBorder)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nwBorder(Color.nw.lineStrong, radius: NWLeadMetrics.stepsRadius)
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
                .stroke(Color.nw.textSecondary, style: StrokeStyle(lineWidth: NWLeadMetrics.stepsCurrentStroke, lineCap: .butt))
                .frame(width: NWLeadMetrics.stepsRing, height: NWLeadMetrics.stepsRing)
        case .pending:
            Circle().stroke(Color.nw.textTertiary, style: StrokeStyle(lineWidth: NWLeadMetrics.stepsPendingStroke, dash: NWLeadMetrics.stepsPendingDash))
                .frame(width: NWLeadMetrics.stepsRing, height: NWLeadMetrics.stepsRing)
        case .done:
            Image(systemName: NWGlyph.resolved.symbolName).font(.system(size: NWLeadMetrics.stepsGlyphBox)).foregroundStyle(Color.nw.textSecondary)
        case .failed:
            // The boards draw no failed step; a plan the worker marked failed gets the same outline circle with a cross, in `failed`.
            Image(systemName: NWGlyph.failedStep.symbolName).font(.system(size: NWLeadMetrics.stepsGlyphBox)).foregroundStyle(Color.nw.failed)
        }
    }
}

/// The live line a Project's thread ends in while its turn works (ProjectLead-Started "Starting threads", -ThreadRunning
/// "Working · 52s"): a 14pt ellipsis glyph and the words in `caption` on `textTertiary`, 8pt apart. The words come from the
/// owner's typed state (`ProjectRunStatus`), never from the text of a reply.
public struct NWLeadStatusLine: View {
    let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: NW.Space.m) {
            Image(systemName: "ellipsis").font(.system(size: NWLeadMetrics.footerGlyph))
                .frame(width: NWLeadMetrics.footerGlyph, height: NWLeadMetrics.footerGlyph).accessibilityHidden(true)
            Text(text).font(.nw(.caption))
        }
        .foregroundStyle(Color.nw.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

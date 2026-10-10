import SwiftUI

/// A task's question in the Project conversation (ProjectLead-Question): a raised card (radius 12, 1pt `lineStrong`)
/// holding the question (13.5/500, 12 above, 8 below), the options as lettered rows (a 22pt key, a 12.5/500 title, an
/// optional `Recommended` tag in `running`, a 11.5 detail on 1.45 lines; 1pt `lineSubtle` between), and a footer
/// line (11.5 `textTertiary`). The words are the asker's own; this draws them and reports a pick.
public struct NWLeadQuestionCard: View {
    public struct Option: Equatable, Identifiable, Sendable {
        public var id: Int
        public var title: String
        public var detail: String?
        public var recommended: Bool

        public init(id: Int, title: String, detail: String? = nil, recommended: Bool = false) {
            self.id = id
            self.title = title
            self.detail = detail
            self.recommended = recommended
        }
    }

    let question: String
    let options: [Option]
    let footer: String?
    let enabled: Bool
    let pick: (Option) -> Void

    public init(question: String, options: [Option], footer: String? = nil, enabled: Bool = true, pick: @escaping (Option) -> Void) {
        self.question = question
        self.options = options
        self.footer = footer
        self.enabled = enabled
        self.pick = pick
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(question)
                .font(.nw(.body, weight: .medium))
                .foregroundStyle(Color.nw.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: NWLeadMetrics.questionPadding + NWLeadMetrics.questionBorder, leading: NWLeadMetrics.questionPadding,
                                    bottom: NWLeadMetrics.questionBottom, trailing: NWLeadMetrics.questionPadding))
                .frame(height: NWLeadMetrics.questionHeight + NWLeadMetrics.questionBorder, alignment: .topLeading)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { NWHairline() }
                    row(index, option)
                }
            }
            .overlay(alignment: .top) { NWHairline() }
            if let footer {
                Text(footer)
                    .font(.nw(.caption))
                    .foregroundStyle(Color.nw.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: NW.Space.m, leading: NWLeadMetrics.questionPadding, bottom: NW.Space.m, trailing: NWLeadMetrics.questionPadding))
                    .frame(minHeight: NWLeadMetrics.questionFooterHeight, alignment: .leading)
                    .overlay(alignment: .top) { NWHairline() }
            }
        }
        .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.l))
        .nwBorder(Color.nw.lineStrong, radius: NW.Radius.l)
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.l))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question)
    }

    private func row(_ index: Int, _ option: Option) -> some View {
        Button { pick(option) } label: {
            HStack(alignment: .top, spacing: NWLeadMetrics.optionGap) {
                Text(String(UnicodeScalar(UInt8(65 + min(index, 25)))))
                    .font(.nwMono(NWLeadMetrics.optionKeySize))
                    .foregroundStyle(Color.nw.textSecondary)
                    .frame(width: NWLeadMetrics.optionKey, height: NWLeadMetrics.optionKey)
                    .overlay(RoundedRectangle(cornerRadius: NWLeadMetrics.optionKeyRadius).stroke(Color.nw.lineStrong, lineWidth: 1))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NWLeadMetrics.optionTitleGap) {
                    HStack(spacing: NW.Space.s) {
                        Text(option.title).font(.nw(.ui, weight: .medium)).foregroundStyle(Color.nw.textPrimary)
                        if option.recommended {
                            Text("Recommended")
                                .font(.nw(.micro))
                                .foregroundStyle(Color.nw.running)
                                .padding(.horizontal, NW.Space.xs)
                                .background(Color.nw.runningTint, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
                        }
                    }
                    // The board's title line is a 17pt box, and its detail a 16.67pt one per line.
                    .frame(height: NWLeadMetrics.optionTitleLine, alignment: .leading)
                    if let detail = option.detail {
                        // 11.5 on a 1.45 line height (16.67pt), the way the board sets it: the leading is the difference between the
                        // line height and the font's own.
                        Text(detail).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                            .lineSpacing(NWLeadMetrics.optionDetailLeading)
                            .frame(minHeight: NWLeadMetrics.optionDetailLine, alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NWLeadMetrics.optionPaddingH)
            .padding(.vertical, NWLeadMetrics.optionPaddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NWLeadRowPress())
        .disabled(!enabled)
        .accessibilityLabel([option.title, option.recommended ? "recommended" : nil, option.detail].compactMap { $0 }.joined(separator: ", "))
    }
}

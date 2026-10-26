import SwiftUI

/// A task's question in the Project conversation (ProjectLead-Question): a raised card (radius 12, 1pt `lineStrong`)
/// holding the question (13.5/500, 12 above, 8 below), the options as lettered rows (a 22pt key, a 12.5/500 title, an
/// optional `Recommended` tag in `running`, a 11.5 detail on 1.45 lines; 1pt `lineSubtle` between), and a footer
/// line (11.5 `textTertiary`). The words are the asker's own; this draws them and reports a pick.
public struct SHLeadQuestionCard: View {
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
    /// The field's placeholder (its label too) when the asker also takes the person's own words.
    let textPlaceholder: String?
    let pick: (Option) -> Void
    let submit: ((String) -> Void)?
    @State private var text = ""

    /// `textPlaceholder`: draws a last row whose field sends its words (Send or Return); a pick still answers at once.
    public init(question: String, options: [Option], footer: String? = nil, enabled: Bool = true, textPlaceholder: String? = nil,
                submit: ((String) -> Void)? = nil, pick: @escaping (Option) -> Void) {
        self.question = question
        self.options = options
        self.footer = footer
        self.enabled = enabled
        self.textPlaceholder = textPlaceholder
        self.pick = pick
        self.submit = submit
    }

    private var words: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        VStack(spacing: 0) {
            Text(question)
                .font(.sh(.body, weight: .medium))
                .foregroundStyle(Color.sh.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: SHLeadMetrics.questionPadding + SHLeadMetrics.questionBorder, leading: SHLeadMetrics.questionPadding,
                                    bottom: SHLeadMetrics.questionBottom, trailing: SHLeadMetrics.questionPadding))
                .frame(height: SHLeadMetrics.questionHeight + SHLeadMetrics.questionBorder, alignment: .topLeading)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { SHHairline() }
                    row(index, option)
                }
                if let textPlaceholder, submit != nil {
                    if !options.isEmpty { SHHairline() }
                    textRow(options.count, placeholder: textPlaceholder)
                }
            }
            .overlay(alignment: .top) { SHHairline() }
            if let footer {
                Text(footer)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: SH.Space.m, leading: SHLeadMetrics.questionPadding, bottom: SH.Space.m, trailing: SHLeadMetrics.questionPadding))
                    .frame(minHeight: SHLeadMetrics.questionFooterHeight, alignment: .leading)
                    .overlay(alignment: .top) { SHHairline() }
            }
        }
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.l))
        .shBorder(Color.sh.lineStrong, radius: SH.Radius.l)
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.l))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question)
    }

    /// A row's letter key: A, B, C…
    private func key(_ index: Int) -> some View {
        Text(String(UnicodeScalar(UInt8(65 + min(index, 25)))))
            .font(.shMono(SHLeadMetrics.optionKeySize))
            .foregroundStyle(Color.sh.textSecondary)
            .frame(width: SHLeadMetrics.optionKey, height: SHLeadMetrics.optionKey)
            .overlay(RoundedRectangle(cornerRadius: SHLeadMetrics.optionKeyRadius).stroke(Color.sh.lineStrong, lineWidth: 1))
            .accessibilityHidden(true)
    }

    /// The last row: the person's own words, sent as the answer (whitespace alone sends nothing).
    private func textRow(_ index: Int, placeholder: String) -> some View {
        HStack(alignment: .center, spacing: SHLeadMetrics.optionGap) {
            key(index)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.sh(.ui))
                .foregroundStyle(Color.sh.textPrimary)
                .onSubmit(send)
                .accessibilityLabel(placeholder)
            Button(action: send) { Text("Send", bundle: .module) }
                .buttonStyle(.sh(.primary, size: .s))
                .disabled(!enabled || words.isEmpty)
        }
        .padding(.horizontal, SHLeadMetrics.optionPaddingH)
        .padding(.vertical, SHLeadMetrics.optionPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!enabled)
    }

    private func send() {
        guard enabled, !words.isEmpty else { return }
        // The words stay until the question leaves, so a refused answer can be sent again.
        submit?(words)
    }

    private func row(_ index: Int, _ option: Option) -> some View {
        Button { text = ""; pick(option) } label: {
            HStack(alignment: .top, spacing: SHLeadMetrics.optionGap) {
                key(index)
                VStack(alignment: .leading, spacing: SHLeadMetrics.optionTitleGap) {
                    HStack(spacing: SH.Space.s) {
                        Text(option.title).font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
                        if option.recommended {
                            Text("Recommended")
                                .font(.sh(.micro))
                                .foregroundStyle(Color.sh.running)
                                .padding(.horizontal, SH.Space.xs)
                                .background(Color.sh.runningTint, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
                        }
                    }
                    // The board's title line is a 17pt box, and its detail a 16.67pt one per line.
                    .frame(height: SHLeadMetrics.optionTitleLine, alignment: .leading)
                    if let detail = option.detail {
                        // 11.5 on a 1.45 line height (16.67pt), the way the board sets it: the leading is the difference between the
                        // line height and the font's own.
                        Text(detail).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                            .lineSpacing(SHLeadMetrics.optionDetailLeading)
                            .frame(minHeight: SHLeadMetrics.optionDetailLine, alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SHLeadMetrics.optionPaddingH)
            .padding(.vertical, SHLeadMetrics.optionPaddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SHLeadRowPress())
        .disabled(!enabled)
        .accessibilityLabel([option.title, option.recommended ? "recommended" : nil, option.detail].compactMap { $0 }.joined(separator: ", "))
    }
}

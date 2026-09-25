import SwiftUI

// A subagent's question, answered from the tray (SubagentTray › Answer → question dock): it
// takes over the composer area the way pi's own questions do, labelled with the subagent. The
// run's answers are numbered cards, the first it recommends marked; Answer sends the one
// chosen, and a question with no answers takes a reply.

public enum NWQuestionDockMetrics {
    public static let padding = EdgeInsets(top: 10, leading: NW.Space.l, bottom: 10, trailing: NW.Space.l)
    public static let questionSize: CGFloat = 13.5
    public static let optionPadding = EdgeInsets(top: NW.Space.m, leading: 10, bottom: NW.Space.m, trailing: 10)
    public static let optionSpacing: CGFloat = 11
    public static let numberSize: CGFloat = 20
    public static let numberRadius: CGFloat = 5
    public static let recommendedHeight: CGFloat = 20
    public static let recommendedPadding: CGFloat = 7
    /// Between an option's title and its description, and the question's extra leading.
    public static let optionLineSpacing: CGFloat = 3
    public static let questionLineSpacing: CGFloat = 3
    /// The lantern ring outside the card.
    public static let ring: CGFloat = 3
}

/// One answer the run offered.
public struct NWQuestionDockOption: Equatable, Identifiable, Sendable {
    public var id: Int { number }
    public var number: Int
    public var title: String
    public var detail: String?
    public var recommended: Bool
    /// The answer sent back: the option exactly as offered.
    public var value: String

    public init(number: Int, title: String, detail: String? = nil, recommended: Bool = false, value: String? = nil) {
        self.value = value ?? title
        self.number = number
        self.title = title
        self.detail = detail
        self.recommended = recommended
    }
}

/// The dock: "reviewer is asking" with Hide, the question, its answers, then Answer (↩).
public struct NWSubagentQuestionDock: View {
    let name: String
    let question: String
    let options: [NWQuestionDockOption]
    let enabled: Bool
    let answer: (String) -> Void
    let hide: () -> Void
    @State private var chosen: Int?
    @State private var reply = ""

    /// `answer` gets the chosen option's value, or the reply typed for a question with none.
    public init(name: String, question: String, options: [NWQuestionDockOption], enabled: Bool = true, chosen: Int? = nil,
                answer: @escaping (String) -> Void, hide: @escaping () -> Void) {
        self.name = name
        self.question = question
        self.options = options
        self.enabled = enabled
        self.answer = answer
        self.hide = hide
        _chosen = State(initialValue: chosen)
    }

    private var value: String? {
        if options.isEmpty {
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return chosen.flatMap { number in options.first { $0.number == number }?.value }
    }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.l)
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWQuestionHead(.subagent(name), hide: hide)
            Text(NWInlineMarkup.attributed(question, codeSize: 12))
                .font(.nwSans(NWQuestionDockMetrics.questionSize, .semibold))
                .foregroundStyle(nw.textPrimary)
                .lineSpacing(NWQuestionDockMetrics.questionLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if options.isEmpty {
                TextField("Reply to \(name)…", text: $reply, axis: .vertical)
                    .lineLimit(1...5)
                    .nwField()
                    .onSubmit(send)
                    .accessibilityLabel("Reply to \(name)")
            } else {
                VStack(spacing: NW.Space.s) {
                    ForEach(options) { option in
                        Button { chosen = option.number } label: { card(option) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.title)
                            .accessibilityAddTraits(chosen == option.number ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
            HStack(spacing: NW.Space.m) {
                Spacer(minLength: 0)
                Button("Answer", action: send)
                    .buttonStyle(.nw(.primary, size: .m))
                    .disabled(!enabled || value == nil)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, NW.Space.m)
            .overlay(alignment: .top) { NWHairline() }
        }
        .disabled(!enabled)
        .padding(NWQuestionDockMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nw.bgRaised, in: shape)
        .nwBorder(nw.lantern, radius: NW.Radius.l)
        .background {
            RoundedRectangle(cornerRadius: NW.Radius.l + NWQuestionDockMetrics.ring)
                .inset(by: -NWQuestionDockMetrics.ring).fill(nw.lanternTint)
        }
        .nwAnimation(.hover, value: chosen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(NWQuestionAsker.subagent(name).title): \(question)")
    }

    private func send() {
        guard enabled, let value else { return }
        answer(value)
    }

    private func card(_ option: NWQuestionDockOption) -> some View {
        let nw = Color.nw
        let picked = chosen == option.number
        let shape = RoundedRectangle(cornerRadius: NW.Radius.m)
        return HStack(alignment: .top, spacing: NWQuestionDockMetrics.optionSpacing) {
            Text("\(option.number)").font(.nwMono(11, .medium)).monospacedDigit()
                .foregroundStyle(picked ? nw.textOnLantern : nw.textSecondary)
                .frame(width: NWQuestionDockMetrics.numberSize, height: NWQuestionDockMetrics.numberSize)
                .background(picked ? nw.lantern : .clear, in: RoundedRectangle(cornerRadius: NWQuestionDockMetrics.numberRadius))
                .nwBorder(picked ? nw.lantern : nw.lineStrong, radius: NWQuestionDockMetrics.numberRadius)
            VStack(alignment: .leading, spacing: NWQuestionDockMetrics.optionLineSpacing) {
                Text(option.title).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = option.detail {
                    Text(detail).font(.nw(.caption)).foregroundStyle(nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if option.recommended {
                Text("Recommended").font(.nwSans(11, .semibold)).foregroundStyle(nw.lanternText)
                    .padding(.horizontal, NWQuestionDockMetrics.recommendedPadding)
                    .frame(height: NWQuestionDockMetrics.recommendedHeight)
                    .background(nw.lanternTint, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
            }
        }
        .padding(NWQuestionDockMetrics.optionPadding)
        .background(picked ? nw.lanternTint : nw.bgWindow, in: shape)
        .nwBorder(picked ? nw.lantern : nw.lineSubtle, radius: NW.Radius.m)
        .contentShape(shape)
    }
}

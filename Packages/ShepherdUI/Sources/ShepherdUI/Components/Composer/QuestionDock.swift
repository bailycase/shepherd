import SwiftUI

// The question dock (QuestionAsk, QuestionPick, QuestionStates): pi's own question takes the
// composer's place in a lantern card. The head says it is the agent asking and hides it; then the
// question, its numbered options (Recommended marked, never preselected), and one Answer. A yes or
// a no answers on click; an open question is a field. Hidden, the dock folds to one line that
// still holds the place. A subagent never asks the user, so the dock has no variant for one.

public enum SHQuestionDockMetrics {
    /// 12pt above and below, 14pt at the sides; 12pt between the parts.
    public static let padding = EdgeInsets(top: SH.Space.l, leading: 14, bottom: SH.Space.l, trailing: 14)
    /// The lantern ring outside the card.
    public static let ring: CGFloat = 3
    /// The question: 16 for a choice, 15 for a yes or a no and an open question
    /// (QuestionStates › Kinds); 1.35 and tracked -0.5%.
    public static let questionSize: CGFloat = 16
    public static let kindQuestionSize: CGFloat = 15
    public static let questionLineSpacing: CGFloat = 3
    public static let questionTracking: CGFloat = -0.005
    /// The asker's longer message scrolls past this.
    public static let messageMaxHeight: CGFloat = 140
    /// An option card: 10pt above and below, 12pt at the sides, its parts 11pt apart; the title
    /// 3pt over its description.
    public static let optionPadding = EdgeInsets(top: 10, leading: SH.Space.l, bottom: 10, trailing: SH.Space.l)
    public static let optionSpacing: CGFloat = 11
    public static let optionLineSpacing: CGFloat = 3
    /// A description's extra leading, to 1.45.
    public static let detailLineSpacing: CGFloat = 3
    public static let numberSize: CGFloat = 20
    public static let recommendedHeight: CGFloat = 20
    public static let recommendedPadding: CGFloat = 7
    public static let recommendedSize: CGFloat = 11
    /// A yes or a no: 44pt cards, their parts 10pt apart.
    public static let yesNoHeight: CGFloat = 44
    public static let yesNoSpacing: CGFloat = 10
    /// An open question's field: at least 64pt, 10×12 inset, 13.5 at 1.5.
    public static let fieldMinHeight: CGFloat = 64
    public static let fieldPadding = EdgeInsets(top: 10, leading: SH.Space.l, bottom: 10, trailing: SH.Space.l)
    public static let fieldSize: CGFloat = 13.5
    public static let fieldLineSpacing: CGFloat = 4
    /// More options than this scroll inside a stack this tall.
    public static let scrollingOptions = 6
    public static let optionsMaxHeight: CGFloat = 360
    /// Hidden: one 46pt line, 14pt leading and 8pt trailing.
    public static let hiddenHeight: CGFloat = 46
    public static let hiddenLeading: CGFloat = 14
    public static let hiddenTrailing: CGFloat = SH.Space.m
}

/// The dock's shape (QuestionStates › Kinds of question).
public enum SHQuestionDockKind: Equatable, Sendable {
    case choice
    case yesNo
    case open
}

/// One answer the asker offered.
public struct SHQuestionDockOption: Equatable, Identifiable, Sendable {
    public var id: Int { number }
    public var number: Int
    public var title: String
    public var detail: String?
    public var recommended: Bool

    public init(number: Int, title: String, detail: String? = nil, recommended: Bool = false) {
        self.number = number
        self.title = title
        self.detail = detail
        self.recommended = recommended
    }
}

/// Everything the dock draws but the person's picks.
public struct SHQuestionDockContent: Equatable, Sendable {
    /// Questions waiting; the head shows "1 / N" past one.
    public var count: Int
    public var question: String
    public var message: String?
    public var kind: SHQuestionDockKind
    public var options: [SHQuestionDockOption]
    /// An open question's field.
    public var placeholder: String
    public var multiline: Bool
    /// A line in the footer: the question may time out, or why it cannot be answered here.
    public var notice: String?
    /// Answer is drawn (not for a yes or a no).
    public var showsAnswer: Bool
    /// A choice whose last numbered option is editable: typing drops the pick, and picking
    /// empties the field.
    public var allowsText: Bool

    public init(count: Int = 1, question: String, message: String? = nil, kind: SHQuestionDockKind,
                options: [SHQuestionDockOption] = [], placeholder: String = "Type your answer…", multiline: Bool = false,
                notice: String? = nil, showsAnswer: Bool = true, allowsText: Bool = false) {
        self.count = count
        self.question = question
        self.message = message
        self.kind = kind
        self.options = options
        self.placeholder = placeholder
        self.multiline = multiline
        self.notice = notice
        self.showsAnswer = showsAnswer
        self.allowsText = allowsText
    }
}

/// What the person has picked and typed.
public struct SHQuestionDockSelection: Equatable, Sendable {
    public var picked: Int?
    public var text: String

    public init(picked: Int? = nil, text: String = "") {
        self.picked = picked
        self.text = text
    }
}

/// The dock's fields.
public enum SHQuestionDockField: Hashable, Sendable {
    case text
}

/// The keys as tooltips spell them (the app reads them from its key list).
public struct SHQuestionDockKeys: Equatable, Sendable {
    public var answer: String
    public var hide: String

    public init(answer: String, hide: String) {
        self.answer = answer
        self.hide = hide
    }
}

/// The lantern card a question sits in, open or hidden: `bgRaised`, radius 12, a 1px `lantern`
/// line inside a 3pt `lanternTint` ring.
struct SHQuestionCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        let sh = Color.sh
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.l))
            .shBorder(sh.lantern, radius: SH.Radius.l)
            .background {
                RoundedRectangle(cornerRadius: SH.Radius.l + SHQuestionDockMetrics.ring)
                    .inset(by: -SHQuestionDockMetrics.ring).fill(sh.lanternTint)
            }
    }
}

extension View {
    /// The question dock's lantern card.
    public func shQuestionCard() -> some View { modifier(SHQuestionCardChrome()) }
}

/// The open dock.
public struct SHQuestionDock: View {
    let content: SHQuestionDockContent
    @Binding var selection: SHQuestionDockSelection
    let focus: FocusState<SHQuestionDockField?>.Binding
    let enabled: Bool
    let answerEnabled: Bool
    let keys: SHQuestionDockKeys
    let answer: (SHQuestionDockSelection) -> Void
    let hide: () -> Void

    /// `answerEnabled`: the picks make an answer the asker takes. `answer` gets the picks: on
    /// Answer, or at once for a yes or a no.
    public init(_ content: SHQuestionDockContent, selection: Binding<SHQuestionDockSelection>,
                focus: FocusState<SHQuestionDockField?>.Binding, enabled: Bool = true, answerEnabled: Bool,
                keys: SHQuestionDockKeys = SHQuestionDockKeys(answer: "↩", hide: "Esc"),
                answer: @escaping (SHQuestionDockSelection) -> Void, hide: @escaping () -> Void) {
        self.content = content
        _selection = selection
        self.focus = focus
        self.enabled = enabled
        self.answerEnabled = answerEnabled
        self.keys = keys
        self.answer = answer
        self.hide = hide
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHQuestionHead(count: content.count, hideHelp: "Hide the question (\(keys.hide))", hide: hide)
            question
            if let message = content.message { messageBlock(message) }
            Group {
                switch content.kind {
                case .choice: options
                case .yesNo: yesNo
                case .open: openField
                }
            }
            .disabled(!enabled)
            if content.showsAnswer || content.notice != nil { footer }
        }
        .padding(SHQuestionDockMetrics.padding)
        .shQuestionCard()
        .shAnimation(.hover, value: selection.picked)
        // Options and words are one answer: the newer one replaces the other, from a click, a key or typing.
        .onChange(of: selection) { old, new in
            guard content.allowsText else { return }
            if new.picked != nil, new.picked != old.picked, !new.text.isEmpty { selection.text = "" }
            else if new.text != old.text, new.picked != nil, !new.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { selection.picked = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(SHQuestionHead.title): \(content.question)")
    }

    private var question: some View {
        let size = content.kind == .choice ? SHQuestionDockMetrics.questionSize : SHQuestionDockMetrics.kindQuestionSize
        return Text(SHProseInline.attributed(content.question))
            .font(.shSans(size, .semibold))
            .tracking(size * SHQuestionDockMetrics.questionTracking)
            .lineSpacing(SHQuestionDockMetrics.questionLineSpacing)
            .foregroundStyle(Color.sh.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityAddTraits(.isHeader)
    }

    private func messageBlock(_ message: String) -> some View {
        ScrollView {
            Text(message).font(.sh(.mono)).foregroundStyle(Color.sh.textPrimary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: SHQuestionDockMetrics.messageMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.m)
        .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
    }

    // MARK: Choice

    @ViewBuilder private var options: some View {
        if content.options.count > SHQuestionDockMetrics.scrollingOptions {
            ScrollView {
                LazyVStack(spacing: SH.Space.s) { optionRows }
            }
            .frame(height: SHQuestionDockMetrics.optionsMaxHeight)
        } else {
            VStack(spacing: SH.Space.s) { optionRows }
        }
    }

    @ViewBuilder private var optionRows: some View {
        ForEach(content.options) { option in
            SHQuestionDockOptionCard(option: option, picked: selection.picked == option.number) {
                pick(option.number)
            }
        }
        // An asker that also takes words: its last numbered option is where they are typed.
        if content.allowsText { textOption }
    }

    /// The last option, N+1, as an editable row: the same card and number, lit while it holds words.
    private var textOption: some View {
        let sh = Color.sh
        let typed = !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .top, spacing: SHQuestionDockMetrics.optionSpacing) {
            SHQuestionDockNumber(number: content.options.count + 1, picked: typed)
            TextField(text: $selection.text, prompt: Text(content.placeholder).foregroundStyle(sh.textTertiary), axis: .vertical) {
                Text(content.placeholder)
            }
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .font(.sh(.headline))
            .foregroundStyle(sh.textPrimary)
            .tint(sh.lantern)
            .focused(focus, equals: .text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(content.placeholder)
        }
        .padding(SHQuestionDockMetrics.optionPadding)
        .shQuestionOptionChrome(picked: typed)
        .onTapGesture { focus.wrappedValue = .text }
    }

    private func pick(_ number: Int) {
        guard enabled else { return }
        selection.picked = number
    }

    // MARK: Yes or no

    private var yesNo: some View {
        HStack(spacing: SH.Space.s) {
            ForEach(content.options) { option in
                let picked = selection.picked == option.number
                Button {
                    guard enabled else { return }
                    var next = selection
                    next.picked = option.number
                    selection = next
                    answer(next)
                } label: {
                    HStack(spacing: SHQuestionDockMetrics.yesNoSpacing) {
                        SHQuestionDockNumber(number: option.number, picked: picked)
                        Text(option.title).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if option.recommended { SHQuestionRecommendedTag() }
                    }
                    .padding(.horizontal, SH.Space.l)
                    .frame(height: SHQuestionDockMetrics.yesNoHeight)
                    .shQuestionOptionChrome(picked: picked)
                }
                .buttonStyle(.plain)
                .help("\(option.title) (\(option.number))")
                .accessibilityLabel(option.title)
                .accessibilityHint(option.recommended ? "Recommended" : "")
            }
        }
    }

    // MARK: Open question

    private var openField: some View {
        let sh = Color.sh
        return TextField(text: $selection.text, prompt: Text(content.placeholder).foregroundStyle(sh.textTertiary), axis: .vertical) {
            Text("Answer")
        }
        .lineLimit(content.multiline ? 3...12 : 2...6)
        .textFieldStyle(.plain)
        .font(.shSans(SHQuestionDockMetrics.fieldSize))
        .lineSpacing(SHQuestionDockMetrics.fieldLineSpacing)
        .foregroundStyle(sh.textPrimary)
        .tint(sh.lantern)
        .autocorrectionDisabled()
        .focused(focus, equals: .text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SHQuestionDockMetrics.fieldPadding)
        .frame(minHeight: SHQuestionDockMetrics.fieldMinHeight, alignment: .topLeading)
        .background(sh.bgWindow, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(sh.lineStrong, radius: SH.Radius.m)
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = .text }
        .accessibilityLabel("Answer")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: SH.Space.m) {
            if let notice = content.notice {
                Text(notice).font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary).lineLimit(2)
                    .shTransition(.content)
            }
            Spacer(minLength: 0)
            if content.showsAnswer {
                Button("Answer") { if enabled && answerEnabled { answer(selection) } }
                    .buttonStyle(.sh(.primary, size: .m))
                    .disabled(!enabled || !answerEnabled)
                    .help("Answer (\(keys.answer))")
            }
        }
        .padding(.top, SH.Space.l)
        .overlay(alignment: .top) { SHHairline() }
    }
}

/// An option's number: a 20pt rounded square, outlined at rest and filled once picked.
struct SHQuestionDockNumber: View {
    let number: Int
    let picked: Bool

    var body: some View {
        let sh = Color.sh
        let side = SHQuestionDockMetrics.numberSize
        Text("\(number)").font(.shMono(11, picked ? .semibold : .regular)).monospacedDigit()
            .foregroundStyle(picked ? sh.textOnLantern : sh.textSecondary)
            .frame(width: side, height: side)
            .background(picked ? sh.lantern : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .shBorder(picked ? sh.lantern : sh.lineStrong, radius: SH.Radius.xs)
            .accessibilityHidden(true)
    }
}

/// "Recommended", where the asker marked an option so.
struct SHQuestionRecommendedTag: View {
    var body: some View {
        Text("Recommended").font(.shSans(SHQuestionDockMetrics.recommendedSize, .semibold)).foregroundStyle(Color.sh.lanternText)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, SHQuestionDockMetrics.recommendedPadding)
            .frame(height: SHQuestionDockMetrics.recommendedHeight)
            .background(Color.sh.lanternTint, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
    }
}

extension View {
    /// An option's card: `bgWindow` with a `lineSubtle` line at rest, `lanternTint` with a
    /// `lantern` line once picked.
    func shQuestionOptionChrome(picked: Bool) -> some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
        return background(picked ? sh.lanternTint : sh.bgWindow, in: shape)
            .shBorder(picked ? sh.lantern : sh.lineSubtle, radius: SH.Radius.m)
            .contentShape(shape)
    }
}

/// A numbered option: its number, the title over its description, Recommended at the top trailing.
struct SHQuestionDockOptionCard: View {
    let option: SHQuestionDockOption
    let picked: Bool
    let pick: () -> Void

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SHQuestionDockMetrics.optionSpacing) {
            SHQuestionDockNumber(number: option.number, picked: picked)
            VStack(alignment: .leading, spacing: SHQuestionDockMetrics.optionLineSpacing) {
                Text(option.title)
                    .font(.sh(.headline))
                    .foregroundStyle(sh.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = option.detail {
                    Text(detail)
                        .font(.sh(.ui, weight: .regular))
                        .lineSpacing(SHQuestionDockMetrics.detailLineSpacing)
                        .foregroundStyle(sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if option.recommended { SHQuestionRecommendedTag() }
        }
        .padding(SHQuestionDockMetrics.optionPadding)
        .shQuestionOptionChrome(picked: picked)
        .onTapGesture(perform: pick)
        .help("\(option.title) (\(option.number))")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(option.title)
        .accessibilityValue(option.detail ?? "")
        .accessibilityHint(option.recommended ? "Recommended" : "")
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick() }
    }
}

/// A hidden question (QuestionStates › hidden): the same lantern card, one 46pt line.
public struct SHQuestionDockHidden: View {
    let question: String
    let keys: SHQuestionDockKeys
    let show: () -> Void

    public init(question: String, keys: SHQuestionDockKeys = SHQuestionDockKeys(answer: "↩", hide: "Esc"),
                show: @escaping () -> Void) {
        self.question = question
        self.keys = keys
        self.show = show
    }

    public var body: some View {
        SHQuestionHiddenLine(question: question, showHelp: "Show the question (\(keys.hide))", show: show)
            .padding(.leading, SHQuestionDockMetrics.hiddenLeading)
            .padding(.trailing, SHQuestionDockMetrics.hiddenTrailing)
            .frame(height: SHQuestionDockMetrics.hiddenHeight)
            .shQuestionCard()
    }
}

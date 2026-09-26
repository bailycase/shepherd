import SwiftUI

// The question dock (QuestionAsk, QuestionPick, QuestionStates; SubagentTray › Answer →
// question dock): a question takes the composer's place in a lantern card, for the agent's own
// question and a subagent's alike. The head says who asks and hides it; then the question, its
// numbered options (Recommended marked, never preselected), a note inside the picked one and
// Something else… when the asker takes them, and one Answer. A yes or a no answers on click; an
// open question is a field. Hidden, the dock folds to one line that still holds the place.

public enum NWQuestionDockMetrics {
    /// 12pt above and below, 14pt at the sides; 12pt between the parts.
    public static let padding = EdgeInsets(top: NW.Space.l, leading: 14, bottom: NW.Space.l, trailing: 14)
    /// The lantern ring outside the card.
    public static let ring: CGFloat = 3
    /// The question: 16 for the agent's own, 14.5 for a subagent's; 1.35 and tracked -0.5%.
    public static let questionSize: CGFloat = 16
    public static let subagentQuestionSize: CGFloat = 14.5
    public static let questionLineSpacing: CGFloat = 3
    public static let questionTracking: CGFloat = -0.005
    /// The asker's longer message scrolls past this.
    public static let messageMaxHeight: CGFloat = 140
    /// An option card: 10pt above and below, 12pt at the sides, its parts 11pt apart; the title
    /// 3pt over its description.
    public static let optionPadding = EdgeInsets(top: 10, leading: NW.Space.l, bottom: 10, trailing: NW.Space.l)
    public static let optionSpacing: CGFloat = 11
    public static let optionLineSpacing: CGFloat = 3
    /// A description's extra leading, to 1.45.
    public static let detailLineSpacing: CGFloat = 3
    /// A subagent's option titles and descriptions.
    public static let subagentTitleSize: CGFloat = 13
    public static let subagentDetailSize: CGFloat = 12
    public static let numberSize: CGFloat = 20
    public static let recommendedHeight: CGFloat = 20
    public static let recommendedPadding: CGFloat = 7
    public static let recommendedSize: CGFloat = 11
    /// The note inside a picked option: 8pt under its description, 7×10 inset, Geist 13 at 1.45.
    public static let noteGap: CGFloat = NW.Space.m
    public static let notePadding = EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)
    public static let noteSize: CGFloat = 13
    public static let noteLineSpacing: CGFloat = 3
    /// Something else…: at least 38pt.
    public static let otherHeight: CGFloat = 38
    /// A yes or a no: 44pt cards, their parts 10pt apart.
    public static let yesNoHeight: CGFloat = 44
    public static let yesNoSpacing: CGFloat = 10
    /// An open question's field: at least 64pt, 10×12 inset, 13.5 at 1.5.
    public static let fieldMinHeight: CGFloat = 64
    public static let fieldPadding = EdgeInsets(top: 10, leading: NW.Space.l, bottom: 10, trailing: NW.Space.l)
    public static let fieldSize: CGFloat = 13.5
    public static let fieldLineSpacing: CGFloat = 4
    /// More options than this scroll inside a stack this tall.
    public static let scrollingOptions = 6
    public static let optionsMaxHeight: CGFloat = 360
    /// Hidden: one 46pt line, 14pt leading and 8pt trailing.
    public static let hiddenHeight: CGFloat = 46
    public static let hiddenLeading: CGFloat = 14
    public static let hiddenTrailing: CGFloat = NW.Space.m
}

/// The dock's shape (QuestionStates › Kinds of question).
public enum NWQuestionDockKind: Equatable, Sendable {
    case choice
    case yesNo
    case open
}

/// One answer the asker offered.
public struct NWQuestionDockOption: Equatable, Identifiable, Sendable {
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
public struct NWQuestionDockContent: Equatable, Sendable {
    public var asker: NWQuestionAsker
    /// Questions waiting; the head shows "1 / N" past one.
    public var count: Int
    public var question: String
    public var message: String?
    public var kind: NWQuestionDockKind
    public var options: [NWQuestionDockOption]
    /// Only for an asker that takes them (Honest affordances).
    public var takesNote: Bool
    public var takesOther: Bool
    /// An open question's field.
    public var placeholder: String
    public var multiline: Bool
    /// A line in the footer: the question may time out, or why it cannot be answered here.
    public var notice: String?
    /// Answer is drawn (not for a yes or a no without Something else).
    public var showsAnswer: Bool

    public init(asker: NWQuestionAsker, count: Int = 1, question: String, message: String? = nil, kind: NWQuestionDockKind,
                options: [NWQuestionDockOption] = [], takesNote: Bool = false, takesOther: Bool = false,
                placeholder: String = "Type your answer…", multiline: Bool = false, notice: String? = nil, showsAnswer: Bool = true) {
        self.asker = asker
        self.count = count
        self.question = question
        self.message = message
        self.kind = kind
        self.options = options
        self.takesNote = takesNote
        self.takesOther = takesOther
        self.placeholder = placeholder
        self.multiline = multiline
        self.notice = notice
        self.showsAnswer = showsAnswer
    }

    /// Something else's number: after the options.
    public var otherNumber: Int? { takesOther && !options.isEmpty ? options.count + 1 : nil }

    var isSubagent: Bool {
        if case .subagent = asker { return true }
        return false
    }
}

/// What the person has picked and typed.
public struct NWQuestionDockSelection: Equatable, Sendable {
    public var picked: Int?
    public var note: String
    public var other: String
    public var text: String

    public init(picked: Int? = nil, note: String = "", other: String = "", text: String = "") {
        self.picked = picked
        self.note = note
        self.other = other
        self.text = text
    }
}

/// The dock's fields.
public enum NWQuestionDockField: Hashable, Sendable {
    case note, other, text
}

/// The keys as tooltips spell them (the app reads them from its key list).
public struct NWQuestionDockKeys: Equatable, Sendable {
    public var answer: String
    public var hide: String

    public init(answer: String, hide: String) {
        self.answer = answer
        self.hide = hide
    }
}

/// The lantern card a question sits in, open or hidden: `bgRaised`, radius 12, a 1px `lantern`
/// line inside a 3pt `lanternTint` ring.
struct NWQuestionCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        let nw = Color.nw
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.l))
            .nwBorder(nw.lantern, radius: NW.Radius.l)
            .background {
                RoundedRectangle(cornerRadius: NW.Radius.l + NWQuestionDockMetrics.ring)
                    .inset(by: -NWQuestionDockMetrics.ring).fill(nw.lanternTint)
            }
    }
}

extension View {
    /// The question dock's lantern card.
    public func nwQuestionCard() -> some View { modifier(NWQuestionCardChrome()) }
}

/// The open dock.
public struct NWQuestionDock: View {
    let content: NWQuestionDockContent
    @Binding var selection: NWQuestionDockSelection
    let focus: FocusState<NWQuestionDockField?>.Binding
    let enabled: Bool
    let answerEnabled: Bool
    let keys: NWQuestionDockKeys
    let answer: (NWQuestionDockSelection) -> Void
    let hide: () -> Void

    /// `answerEnabled`: the picks make an answer the asker takes. `answer` gets the picks: on
    /// Answer, or at once for a yes or a no.
    public init(_ content: NWQuestionDockContent, selection: Binding<NWQuestionDockSelection>,
                focus: FocusState<NWQuestionDockField?>.Binding, enabled: Bool = true, answerEnabled: Bool,
                keys: NWQuestionDockKeys = NWQuestionDockKeys(answer: "↩", hide: "Esc"),
                answer: @escaping (NWQuestionDockSelection) -> Void, hide: @escaping () -> Void) {
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
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWQuestionHead(content.asker, count: content.count, hideHelp: "Hide the question (\(keys.hide))", hide: hide)
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
        .padding(NWQuestionDockMetrics.padding)
        .nwQuestionCard()
        .nwAnimation(.hover, value: selection.picked)
        .nwAnimation(.disclosure, value: pickedWithNote)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(content.asker.title): \(content.question)")
    }

    private var pickedWithNote: Int? { content.takesNote ? selection.picked : nil }

    private var question: some View {
        let size = content.isSubagent ? NWQuestionDockMetrics.subagentQuestionSize : NWQuestionDockMetrics.questionSize
        return Text(NWProseInline.attributed(content.question))
            .font(.nwSans(size, .semibold))
            .tracking(size * NWQuestionDockMetrics.questionTracking)
            .lineSpacing(NWQuestionDockMetrics.questionLineSpacing)
            .foregroundStyle(Color.nw.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityAddTraits(.isHeader)
    }

    private func messageBlock(_ message: String) -> some View {
        ScrollView {
            Text(message).font(.nw(.mono)).foregroundStyle(Color.nw.textPrimary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: NWQuestionDockMetrics.messageMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, NW.Space.l).padding(.vertical, NW.Space.m)
        .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
    }

    // MARK: Choice

    @ViewBuilder private var options: some View {
        if content.options.count > NWQuestionDockMetrics.scrollingOptions {
            ScrollView {
                LazyVStack(spacing: NW.Space.s) { optionRows }
            }
            .frame(height: NWQuestionDockMetrics.optionsMaxHeight)
        } else {
            VStack(spacing: NW.Space.s) { optionRows }
        }
    }

    @ViewBuilder private var optionRows: some View {
        ForEach(content.options) { option in
            NWQuestionDockOptionCard(option: option, picked: selection.picked == option.number, subagent: content.isSubagent,
                                 takesNote: content.takesNote, note: $selection.note, focus: focus) {
                pick(option.number)
            }
        }
        if let other = content.otherNumber { otherRow(other) }
    }

    private func pick(_ number: Int) {
        guard enabled else { return }
        selection.picked = number
        if focus.wrappedValue == .other { focus.wrappedValue = nil }
    }

    private func otherRow(_ number: Int) -> some View {
        let nw = Color.nw
        let picked = selection.picked == number
        let size = content.isSubagent ? NWQuestionDockMetrics.subagentTitleSize : NWTextStyle.headline.size
        return HStack(alignment: .center, spacing: NWQuestionDockMetrics.optionSpacing) {
            NWQuestionDockNumber(number: number, picked: picked)
            TextField(text: $selection.other, prompt: Text("Something else…").foregroundStyle(nw.textTertiary), axis: .vertical) {
                Text("Something else")
            }
            .lineLimit(1...5)
            .textFieldStyle(.plain)
            .font(.nwSans(size))
            .foregroundStyle(nw.textPrimary)
            .tint(nw.lantern)
            .focused(focus, equals: .other)
            .onChange(of: selection.other) { _, words in if !words.isEmpty { selection.picked = number } }
        }
        .padding(.horizontal, NW.Space.l).padding(.vertical, NW.Space.m)
        .frame(minHeight: NWQuestionDockMetrics.otherHeight)
        .nwQuestionOptionChrome(picked: picked)
        .onTapGesture { selection.picked = number; focus.wrappedValue = .other }
        .onChange(of: focus.wrappedValue == .other) { _, writing in if writing { selection.picked = number } }
        .help("Something else (\(number))")
    }

    // MARK: Yes or no

    private var yesNo: some View {
        VStack(spacing: NW.Space.s) {
            HStack(spacing: NW.Space.s) {
                ForEach(content.options) { option in
                    let picked = selection.picked == option.number
                    Button {
                        guard enabled else { return }
                        var next = selection
                        next.picked = option.number
                        selection = next
                        answer(next)
                    } label: {
                        HStack(spacing: NWQuestionDockMetrics.yesNoSpacing) {
                            NWQuestionDockNumber(number: option.number, picked: picked)
                            Text(option.title).font(.nw(.headline)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if option.recommended { NWQuestionRecommendedTag() }
                        }
                        .padding(.horizontal, NW.Space.l)
                        .frame(height: NWQuestionDockMetrics.yesNoHeight)
                        .nwQuestionOptionChrome(picked: picked)
                    }
                    .buttonStyle(.plain)
                    .help("\(option.title) (\(option.number))")
                    .accessibilityLabel(option.title)
                    .accessibilityHint(option.recommended ? "Recommended" : "")
                }
            }
            if let other = content.otherNumber { otherRow(other) }
        }
    }

    // MARK: Open question

    private var openField: some View {
        let nw = Color.nw
        return TextField(text: $selection.text, prompt: Text(content.placeholder).foregroundStyle(nw.textTertiary), axis: .vertical) {
            Text("Answer")
        }
        .lineLimit(content.multiline ? 3...12 : 2...6)
        .textFieldStyle(.plain)
        .font(.nwSans(NWQuestionDockMetrics.fieldSize))
        .lineSpacing(NWQuestionDockMetrics.fieldLineSpacing)
        .foregroundStyle(nw.textPrimary)
        .tint(nw.lantern)
        .autocorrectionDisabled()
        .focused(focus, equals: .text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NWQuestionDockMetrics.fieldPadding)
        .frame(minHeight: NWQuestionDockMetrics.fieldMinHeight, alignment: .topLeading)
        .background(nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(nw.lineStrong, radius: NW.Radius.m)
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = .text }
        .accessibilityLabel("Answer")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: NW.Space.m) {
            if let notice = content.notice {
                Text(notice).font(.nw(.micro)).foregroundStyle(Color.nw.textTertiary).lineLimit(2)
                    .nwTransition(.content)
            }
            Spacer(minLength: 0)
            if content.showsAnswer {
                Button("Answer") { if enabled && answerEnabled { answer(selection) } }
                    .buttonStyle(.nw(.primary, size: .m))
                    .disabled(!enabled || !answerEnabled)
                    .help("Answer (\(keys.answer))")
            }
        }
        .padding(.top, NW.Space.l)
        .overlay(alignment: .top) { NWHairline() }
    }
}

/// An option's number: a 20pt rounded square, outlined at rest and filled once picked.
struct NWQuestionDockNumber: View {
    let number: Int
    let picked: Bool

    var body: some View {
        let nw = Color.nw
        let side = NWQuestionDockMetrics.numberSize
        Text("\(number)").font(.nwMono(11, picked ? .semibold : .regular)).monospacedDigit()
            .foregroundStyle(picked ? nw.textOnLantern : nw.textSecondary)
            .frame(width: side, height: side)
            .background(picked ? nw.lantern : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
            .nwBorder(picked ? nw.lantern : nw.lineStrong, radius: NW.Radius.xs)
            .accessibilityHidden(true)
    }
}

/// "Recommended", where the asker marked an option so.
struct NWQuestionRecommendedTag: View {
    var body: some View {
        Text("Recommended").font(.nwSans(NWQuestionDockMetrics.recommendedSize, .semibold)).foregroundStyle(Color.nw.lanternText)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, NWQuestionDockMetrics.recommendedPadding)
            .frame(height: NWQuestionDockMetrics.recommendedHeight)
            .background(Color.nw.lanternTint, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
    }
}

extension View {
    /// An option's card: `bgWindow` with a `lineSubtle` line at rest, `lanternTint` with a
    /// `lantern` line once picked.
    func nwQuestionOptionChrome(picked: Bool) -> some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.m)
        return background(picked ? nw.lanternTint : nw.bgWindow, in: shape)
            .nwBorder(picked ? nw.lantern : nw.lineSubtle, radius: NW.Radius.m)
            .contentShape(shape)
    }
}

/// A numbered option: its number, the title over its description, Recommended at the top
/// trailing; picked, the note field opens under its description when the asker takes one.
struct NWQuestionDockOptionCard: View {
    let option: NWQuestionDockOption
    let picked: Bool
    let subagent: Bool
    let takesNote: Bool
    @Binding var note: String
    let focus: FocusState<NWQuestionDockField?>.Binding
    let pick: () -> Void

    var body: some View {
        let nw = Color.nw
        HStack(alignment: .top, spacing: NWQuestionDockMetrics.optionSpacing) {
            NWQuestionDockNumber(number: option.number, picked: picked)
            VStack(alignment: .leading, spacing: NWQuestionDockMetrics.optionLineSpacing) {
                Text(option.title)
                    .font(subagent ? .nwSans(NWQuestionDockMetrics.subagentTitleSize, .semibold) : .nw(.headline))
                    .foregroundStyle(nw.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = option.detail {
                    Text(detail)
                        .font(subagent ? .nwSans(NWQuestionDockMetrics.subagentDetailSize) : .nw(.ui, weight: .regular))
                        .lineSpacing(NWQuestionDockMetrics.detailLineSpacing)
                        .foregroundStyle(nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if picked && takesNote { noteField.padding(.top, NWQuestionDockMetrics.noteGap - NWQuestionDockMetrics.optionLineSpacing) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if option.recommended { NWQuestionRecommendedTag() }
        }
        .padding(NWQuestionDockMetrics.optionPadding)
        .nwQuestionOptionChrome(picked: picked)
        .onTapGesture(perform: pick)
        .help("\(option.title) (\(option.number))")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(option.title)
        .accessibilityValue(option.detail ?? "")
        .accessibilityHint(option.recommended ? "Recommended" : "")
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick() }
    }

    private var noteField: some View {
        let nw = Color.nw
        return TextField(text: $note, prompt: Text("Add a note…").foregroundStyle(nw.textTertiary), axis: .vertical) {
            Text("Note")
        }
        .lineLimit(1...5)
        .textFieldStyle(.plain)
        .font(.nwSans(NWQuestionDockMetrics.noteSize))
        .lineSpacing(NWQuestionDockMetrics.noteLineSpacing)
        .foregroundStyle(nw.textPrimary)
        .tint(nw.lantern)
        .focused(focus, equals: .note)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NWQuestionDockMetrics.notePadding)
        .background(nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .nwBorder(nw.lineStrong, radius: NW.Radius.s)
        .nwTransition(.disclosure, edge: .top)
        .accessibilityLabel("Note with \(option.title)")
    }
}

/// A hidden question (QuestionStates › hidden): the same lantern card, one 46pt line.
public struct NWQuestionDockHidden: View {
    let asker: NWQuestionAsker
    let question: String
    let keys: NWQuestionDockKeys
    let show: () -> Void

    public init(_ asker: NWQuestionAsker, question: String, keys: NWQuestionDockKeys = NWQuestionDockKeys(answer: "↩", hide: "Esc"),
                show: @escaping () -> Void) {
        self.asker = asker
        self.question = question
        self.keys = keys
        self.show = show
    }

    public var body: some View {
        NWQuestionHiddenLine(asker, question: question, showHelp: "Show the question (\(keys.hide))", show: show)
            .padding(.leading, NWQuestionDockMetrics.hiddenLeading)
            .padding(.trailing, NWQuestionDockMetrics.hiddenTrailing)
            .frame(height: NWQuestionDockMetrics.hiddenHeight)
            .nwQuestionCard()
    }
}

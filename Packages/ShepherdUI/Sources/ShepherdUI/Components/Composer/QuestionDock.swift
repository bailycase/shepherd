import SwiftUI

// The question dock (QuestionDockRadio board): pi's own question takes the composer's place in a
// neutral card with a lantern edge. An eyebrow says the agent is asking, over the question; the
// asker's background folds under Details; options are radio rows (Recommended marked, never
// preselected), a last row takes your own words where the asker allows them; then Skip and
// Answer. A yes or a no answers on click; an open question is a field. Hidden, the dock folds
// to one line that still holds the place. A subagent never asks the user, so the dock has no
// variant for one.

public enum SHQuestionDockMetrics {
    /// The card: radius 10, a 1px `lineStrong` line and a 3pt `lantern` edge on the leading side.
    public static let radius: CGFloat = 10
    public static let edge: CGFloat = 3
    /// 14pt above and below, 16pt at the sides (inside the edge); 12pt between the parts.
    public static let padding = EdgeInsets(top: 14, leading: SH.Space.xl + edge, bottom: 14, trailing: SH.Space.xl)
    /// The eyebrow: 11 semibold, uppercase, tracked 6%, 4pt over the question.
    public static let eyebrowSize: CGFloat = 11
    public static let eyebrowTracking: CGFloat = 0.06
    /// The question, 15 semibold (`title`) at 1.35.
    public static let questionLineSpacing: CGFloat = 1.5
    /// Details: its toggle in 12, the chevron 5pt before it; open, 13 at 1.5, paragraphs 8pt
    /// apart, scrolling past 220pt.
    public static let detailsToggleSize: CGFloat = 12
    public static let detailsToggleSpacing: CGFloat = 5
    /// The toggle's row: the board's line (13 at 1.5, its 14pt "›").
    public static let detailsToggleHeight: CGFloat = 21
    public static let detailsSize: CGFloat = 13
    public static let detailsLineSpacing: CGFloat = 3
    public static let detailsMaxHeight: CGFloat = 220
    /// The asker's longer message (a confirm's) scrolls past this.
    public static let messageMaxHeight: CGFloat = 140
    /// A radio row: 7pt above and below, 8pt at the sides (hanging into the card's padding so
    /// the radios line up with the question), its parts 10pt apart, rows 2pt apart.
    public static let rowPadding = EdgeInsets(top: 7, leading: SH.Space.m, bottom: 7, trailing: SH.Space.m)
    public static let rowSpacing: CGFloat = 10
    /// Something else…'s field sits 1pt in, as the board's input does.
    public static let textRowInset: CGFloat = 1
    /// Rows and the footer's buttons: radius 7.
    public static let controlRadius: CGFloat = 7
    /// The radio: a 16pt circle with a 1.5pt line; picked, an 8pt dot.
    public static let radio: CGFloat = 16
    public static let radioDot: CGFloat = 8
    public static let radioLine: CGFloat = 1.5
    /// "Recommended" after the title, 12 medium; the trailing number, mono 11.
    public static let recommendedSize: CGFloat = 12
    public static let numberSize: CGFloat = 11
    /// The footer's keycaps: mono 10.5 in `textSecondary`, a 1px `lineStrong` line at radius 3,
    /// 4pt at the sides.
    public static let keycapSize: CGFloat = 10.5
    public static let keycapRadius: CGFloat = 3
    public static let keycapPadding: CGFloat = 4
    public static let keycapLine: CGFloat = 1
    /// Skip and Answer: 28pt, Geist 13, 10pt and 12pt at the sides.
    public static let buttonSize: CGFloat = 13
    public static let skipPadding: CGFloat = 10
    public static let answerPadding: CGFloat = SH.Space.l
    /// More options than this scroll inside a stack this tall.
    public static let scrollingOptions = 6
    public static let optionsMaxHeight: CGFloat = 360
    /// A yes or a no: 44pt cards, their parts 10pt apart, a 20pt number and Recommended tag.
    public static let yesNoHeight: CGFloat = 44
    public static let yesNoSpacing: CGFloat = 10
    public static let yesNoNumber: CGFloat = 20
    public static let tagHeight: CGFloat = 20
    public static let tagPadding: CGFloat = 7
    public static let tagSize: CGFloat = 11
    /// An open question's field: at least 64pt, 10×12 inset, 13.5 at 1.5.
    public static let fieldMinHeight: CGFloat = 64
    public static let fieldPadding = EdgeInsets(top: 10, leading: SH.Space.l, bottom: 10, trailing: SH.Space.l)
    public static let fieldSize: CGFloat = 13.5
    public static let fieldLineSpacing: CGFloat = 4
    /// Hidden: one 46pt line, 14pt leading (inside the edge) and 8pt trailing.
    public static let hiddenHeight: CGFloat = 46
    public static let hiddenLeading: CGFloat = 14 + edge
    public static let hiddenTrailing: CGFloat = SH.Space.m
}

#if os(macOS)
/// The Mac dock as the redesign's GXQuestion draws it: a raised card (radius 14, `lift`) with a
/// lantern dot and the question in 14 semibold, rows 9pt at radius 9 with a 20pt key chip, and
/// Skip and Answer as 30pt pills.
public enum SHQuestionBoardMetrics {
    public static let padding = EdgeInsets(top: 14, leading: SH.Space.m, bottom: 10, trailing: SH.Space.m)
    /// The head: 10pt between its parts, 10pt trailing and 12pt leading inside the card's padding.
    public static let headSpacing: CGFloat = 10
    public static let headInset = EdgeInsets(top: 0, leading: SH.Space.l, bottom: 0, trailing: 10)
    public static let dot: CGFloat = 7
    public static let dotTop: CGFloat = 7
    public static let headChevron: CGFloat = 10
    /// Rows: 9pt over 10pt, parts 12pt apart, 2pt between rows, radius 9.
    public static let rowPadding = EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10)
    public static let rowSpacing: CGFloat = SH.Space.l
    public static let rowRadius: CGFloat = 9
    public static let optionsTop: CGFloat = SH.Space.m
    /// The key chip: 20pt, radius 6, mono 11.
    public static let chip: CGFloat = 20
    public static let chipRadius: CGFloat = SH.Radius.s - 1
    public static let chipSize: CGFloat = 11
    /// The title's 1pt drop and the "Recommended" tag's 8pt lead.
    public static let bodyTop: CGFloat = 1
    public static let recommendedLead: CGFloat = SH.Space.m
    /// Skip and Answer: 30pt pills, 12pt and 14pt at the sides, 6pt apart; the footer 6pt under the rows.
    public static let buttonHeight: CGFloat = 30
    public static let skipPadding: CGFloat = SH.Space.l
    public static let answerPadding: CGFloat = 14
    public static let footerTop: CGFloat = SH.Space.s
    public static let footerInset: CGFloat = SH.Space.xs
    /// The hidden line's height.
    public static let hiddenHeight: CGFloat = 46
}
#endif

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
    /// Questions waiting; the eyebrow says "1 of N" past one.
    public var count: Int
    public var question: String
    /// The asker's background, folded under Details.
    public var details: String?
    public var message: String?
    public var kind: SHQuestionDockKind
    public var options: [SHQuestionDockOption]
    /// An open question's field.
    public var placeholder: String
    public var multiline: Bool
    /// A line in the footer: the question may time out, or why it cannot be answered here.
    public var notice: String?
    /// Answer (and Skip) are drawn (not for a yes or a no).
    public var showsAnswer: Bool
    /// A choice whose last row takes words: typing drops the pick, and picking empties the field.
    public var allowsText: Bool

    public init(count: Int = 1, question: String, details: String? = nil, message: String? = nil, kind: SHQuestionDockKind,
                options: [SHQuestionDockOption] = [], placeholder: String = "Type your answer…", multiline: Bool = false,
                notice: String? = nil, showsAnswer: Bool = true, allowsText: Bool = false) {
        self.count = count
        self.question = question
        self.details = details
        self.message = message
        self.kind = kind
        self.options = options
        self.placeholder = placeholder
        self.multiline = multiline
        self.notice = notice
        self.showsAnswer = showsAnswer
        self.allowsText = allowsText
    }

    /// The last row's number on a choice that takes words; else the last option's.
    public var lastNumber: Int { options.count + (allowsText ? 1 : 0) }
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

/// The keys as tooltips and hints spell them (the app reads them from its key list).
public struct SHQuestionDockKeys: Equatable, Sendable {
    public var answer: String
    public var hide: String

    public init(answer: String, hide: String) {
        self.answer = answer
        self.hide = hide
    }
}

/// The card a question sits in, open or hidden: `bgRaised`, radius 10, a 1px `lineStrong` line
/// and a 3pt `lantern` edge along the leading side.
struct SHQuestionCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { SHQuestionCardFill() }
    }
}

/// The card's fill, line and lantern edge.
struct SHQuestionCardFill: View {
    var body: some View {
        let sh = Color.sh
        #if os(macOS)
        let board = RoundedRectangle(cornerRadius: SH.Radius.xl)
        Color.clear.shLift(board).shBorder(sh.lineSubtle, in: board).allowsHitTesting(false)
        #else
        let shape = RoundedRectangle(cornerRadius: SHQuestionDockMetrics.radius)
        shape.fill(sh.bgRaised)
            .shBorder(sh.lineStrong, in: shape)
            .overlay(alignment: .leading) { sh.lantern.frame(width: SHQuestionDockMetrics.edge) }
            .clipShape(shape)
            .allowsHitTesting(false)
        #endif
    }
}

extension View {
    /// The question dock's card.
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
    let skip: (() -> Void)?
    let hide: () -> Void

    /// `answerEnabled`: the picks make an answer the asker takes. `answer` gets the picks: on
    /// Answer, or at once for a yes or a no. `skip`, beside Answer, answers nothing.
    public init(_ content: SHQuestionDockContent, selection: Binding<SHQuestionDockSelection>,
                focus: FocusState<SHQuestionDockField?>.Binding, enabled: Bool = true, answerEnabled: Bool,
                keys: SHQuestionDockKeys = SHQuestionDockKeys(answer: "↩", hide: "Esc"),
                answer: @escaping (SHQuestionDockSelection) -> Void, skip: (() -> Void)? = nil, hide: @escaping () -> Void) {
        self.content = content
        _selection = selection
        self.focus = focus
        self.enabled = enabled
        self.answerEnabled = answerEnabled
        self.keys = keys
        self.answer = answer
        self.skip = skip
        self.hide = hide
    }

    @ViewBuilder private var dockContent: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            SHQuestionHead(count: content.count, question: content.question, hideHelp: "Hide the question (\(keys.hide))", hide: hide)
            if let details = content.details {
                SHQuestionDetails(details).padding(SHQuestionBoardMetrics.headInset).padding(.top, SH.Space.s)
            }
            if let message = content.message { messageBlock(message).padding(.horizontal, SHQuestionBoardMetrics.headInset.leading).padding(.top, SH.Space.m) }
            Group {
                switch content.kind {
                case .choice: options
                case .yesNo: yesNo
                case .open: openField
                }
            }
            .padding(.top, SHQuestionBoardMetrics.optionsTop)
            .disabled(!enabled)
            if content.showsAnswer || content.notice != nil { footer }
        }
        .padding(SHQuestionBoardMetrics.padding)
        #else
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHQuestionHead(count: content.count, question: content.question, hideHelp: "Hide the question (\(keys.hide))", hide: hide)
            if let details = content.details { SHQuestionDetails(details) }
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
        #endif
    }

    public var body: some View {
        dockContent
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

    /// The rows hang into the card's padding on touch and the old Mac card; the redesign's card pads for them.
    private static var optionsHang: CGFloat {
        #if os(macOS)
        0
        #else
        -SH.Space.m
        #endif
    }

    @ViewBuilder private var options: some View {
        if content.options.count > SHQuestionDockMetrics.scrollingOptions {
            ScrollView {
                LazyVStack(spacing: SH.Space.xxs) { optionRows }
            }
            .frame(height: SHQuestionDockMetrics.optionsMaxHeight)
            .padding(.horizontal, Self.optionsHang)
        } else {
            VStack(spacing: SH.Space.xxs) { optionRows }
                .padding(.horizontal, Self.optionsHang)
        }
    }

    @ViewBuilder private var optionRows: some View {
        ForEach(content.options) { option in
            SHQuestionRadioRow(option, picked: selection.picked == option.number, showsNumber: true) {
                guard enabled else { return }
                selection.picked = option.number
            }
        }
        // An asker that also takes words: its last row is where they are typed.
        if content.allowsText {
            SHQuestionTextRow(text: $selection.text, focus: focus, number: content.lastNumber)
        }
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
        let sh = Color.sh
        return HStack(spacing: SH.Space.l) {
            if content.showsAnswer, enabled { hints }
            if let notice = content.notice {
                Text(notice).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(2)
                    .shTransition(.content)
            }
            Spacer(minLength: 0)
            if content.showsAnswer {
                if let skip {
                    Button("Skip") { if enabled { skip() } }
                        .buttonStyle(SHQuestionDockButtonStyle(primary: false))
                        .disabled(!enabled)
                        .help("Skip (the agent is told you didn't answer)")
                }
                Button("Answer") { if enabled && answerEnabled { answer(selection) } }
                    .buttonStyle(SHQuestionDockButtonStyle(primary: true))
                    .disabled(!enabled || !answerEnabled)
                    .help("Answer (\(keys.answer))")
            }
        }
        #if os(macOS)
        .padding(.top, SHQuestionBoardMetrics.footerTop)
        .padding(.horizontal, SHQuestionBoardMetrics.footerInset)
        #else
        .padding(.top, SH.Space.l)
        .overlay(alignment: .top) { SHHairline() }
        #endif
    }

    /// "[1]–[N] pick  [↩] answer": the dock's keys, which work while its thread has the keyboard.
    private var hints: some View {
        let last = content.lastNumber
        return HStack(spacing: SH.Space.l) {
            if content.kind == .choice, last > 0 {
                HStack(spacing: 0) {
                    SHQuestionKeycap("1")
                    if last > 1 { Text("–"); SHQuestionKeycap("\(last)") }
                    Text(" pick")
                }
            }
            HStack(spacing: 0) {
                SHQuestionKeycap(keys.answer)
                Text(" answer")
            }
        }
        .font(.sh(.caption))
        .foregroundStyle(Color.sh.textTertiary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.kind == .choice && last > 1
                            ? "Keys: 1 to \(last) pick, \(keys.answer) answers" : "Keys: \(keys.answer) answers")
    }
}

// MARK: Shared parts (the Mac's dock and the touch card)

/// "AGENT IS ASKING · 1 OF N": 11 semibold, uppercase and tracked, in `lanternText`.
public struct SHQuestionEyebrow: View {
    let count: Int

    public init(count: Int = 1) { self.count = count }

    public var body: some View {
        let M = SHQuestionDockMetrics.self
        Text(count > 1 ? "\(SHQuestionHead.title) · 1 of \(count)" : SHQuestionHead.title)
            .font(.shSans(M.eyebrowSize, .semibold))
            .tracking(M.eyebrowSize * M.eyebrowTracking)
            .textCase(.uppercase)
            .foregroundStyle(Color.sh.lanternText)
            .lineLimit(1)
            .accessibilityLabel(count > 1 ? "\(SHQuestionHead.title), 1 of \(count)" : SHQuestionHead.title)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The eyebrow over the question (15 semibold, inline code and emphasis as in prose).
public struct SHQuestionHeading: View {
    let count: Int
    let question: String

    public init(count: Int = 1, question: String) {
        self.count = count
        self.question = question
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            SHQuestionEyebrow(count: count)
            Text(SHProseInline.attributed(question))
                .font(.sh(.title))
                .lineSpacing(SHQuestionDockMetrics.questionLineSpacing)
                .foregroundStyle(Color.sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shAnimation(.content, value: count)
    }
}

/// "Details", folded: the asker's background in 13 `textSecondary` at 1.5, its paragraphs kept,
/// scrolling past `maxHeight` once open (nil: inside a panel that scrolls already).
public struct SHQuestionDetails: View {
    let paragraphs: [String]
    let maxHeight: CGFloat?
    @State private var open = false

    /// `open`: how it starts (folded, unless a preview shows it open).
    public init(_ text: String, maxHeight: CGFloat? = SHQuestionDockMetrics.detailsMaxHeight, open: Bool = false) {
        self.maxHeight = maxHeight
        _open = State(initialValue: open)
        paragraphs = text.split(separator: #/\n[ \t]*\n/#).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHQuestionDockMetrics.self
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Button {
                withSHAnimation(.disclosure) { open.toggle() }
            } label: {
                HStack(spacing: M.detailsToggleSpacing) {
                    SHThreadChevron(isExpanded: open)
                    Text("Details").font(.shSans(M.detailsToggleSize))
                }
                .foregroundStyle(sh.textSecondary)
                #if os(iOS)
                .frame(minHeight: SH.Height.touch)
                #else
                .frame(minHeight: M.detailsToggleHeight)
                #endif
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shFocusRing(radius: SH.Radius.xs)
            .accessibilityLabel("Details")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                Group {
                    if let maxHeight {
                        ScrollView { text }
                            .frame(maxHeight: maxHeight)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        text
                    }
                }
                .shTransition(.disclosure)
            }
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            ForEach(paragraphs.indices, id: \.self) { index in
                Text(SHProseInline.attributed(paragraphs[index]))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.shSans(SHQuestionDockMetrics.detailsSize))
        .lineSpacing(SHQuestionDockMetrics.detailsLineSpacing)
        .foregroundStyle(Color.sh.textSecondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A radio: a 16pt circle in `lineStrong`; picked, a `lantern` ring around an 8pt `lantern` dot.
struct SHQuestionRadio: View {
    let picked: Bool

    var body: some View {
        let sh = Color.sh
        let M = SHQuestionDockMetrics.self
        Circle().strokeBorder(picked ? sh.primary : sh.lineStrong, lineWidth: M.radioLine)
            .overlay { if picked { Circle().fill(sh.primary).frame(width: M.radioDot, height: M.radioDot) } }
            .frame(width: M.radio, height: M.radio)
            .accessibilityHidden(true)
    }
}

/// An option as a radio row, no card: the radio, the title (13.5) with "Recommended" after it in
/// `lanternText` and its description under it in `textSecondary`, and, with keys, its number
/// trailing in mono 11 `textTertiary`. Hover lights the row `bgHover`; a click picks it.
public struct SHQuestionRadioRow: View {
    let option: SHQuestionDockOption
    let picked: Bool
    let showsNumber: Bool
    let pick: () -> Void
    @State private var hovering = false

    public init(_ option: SHQuestionDockOption, picked: Bool, showsNumber: Bool, pick: @escaping () -> Void) {
        self.option = option
        self.picked = picked
        self.showsNumber = showsNumber
        self.pick = pick
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHQuestionDockMetrics.self
        #if os(macOS)
        macRow
        #else
        Button(action: pick) {
            HStack(alignment: .top, spacing: M.rowSpacing) {
                SHQuestionRadio(picked: picked)
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    title.fixedSize(horizontal: false, vertical: true)
                    if let detail = option.detail {
                        Text(detail).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsNumber {
                    Text("\(option.number)").font(.shMono(M.numberSize)).monospacedDigit().foregroundStyle(sh.textTertiary)
                }
            }
            .padding(M.rowPadding)
            #if os(iOS)
            .frame(minHeight: SH.Height.touch)
            #endif
            .background(hovering ? sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SHQuestionDockMetrics.controlRadius))
            .contentShape(RoundedRectangle(cornerRadius: SHQuestionDockMetrics.controlRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .help(showsNumber ? "\(option.title) (\(option.number))" : option.title)
        .accessibilityLabel(option.title)
        .accessibilityValue(option.detail ?? "")
        .accessibilityHint(option.recommended ? "Recommended" : "")
        .accessibilityAddTraits(picked ? .isSelected : [])
        #endif
    }

    #if os(macOS)
    /// The redesign's row: a 20pt key chip, the title in 14 with "Recommended" after it in 12
    /// `textTertiary`, the description under it in 12 `textSecondary`. Picked lights the row
    /// `bgSelected` and fills the chip with ink; the pointer lights it `bgHover`.
    private var macRow: some View {
        let sh = Color.sh
        let B = SHQuestionBoardMetrics.self
        let shape = RoundedRectangle(cornerRadius: B.rowRadius)
        return Button(action: pick) {
            HStack(alignment: .top, spacing: B.rowSpacing) {
                SHQuestionKeyChip(number: option.number, on: picked)
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    macTitle.fixedSize(horizontal: false, vertical: true)
                    if let detail = option.detail {
                        Text(detail).font(.sh(.caption)).foregroundStyle(sh.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.leading)
                .padding(.top, B.bodyTop)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(B.rowPadding)
            .background(picked ? sh.bgSelected : hovering ? sh.bgHover : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .help("\(option.title) (\(option.number))")
        .accessibilityLabel(option.title)
        .accessibilityValue(option.detail ?? "")
        .accessibilityHint(option.recommended ? "Recommended" : "")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var macTitle: Text {
        let sh = Color.sh
        let title = Text(option.title).foregroundStyle(sh.textPrimary)
        guard option.recommended else { return title.font(.sh(.body)) }
        let tag = Text("Recommended").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
        return Text("\(title)\u{2002}\(tag)").font(.sh(.body))
    }
    #endif

    /// The title, then "Recommended" inline after it, wrapping with it.
    private var title: Text {
        let sh = Color.sh
        let title = Text(option.title).foregroundStyle(sh.textPrimary)
        guard option.recommended else { return title.font(.sh(.body)) }
        let tag = Text("Recommended").font(.shSans(SHQuestionDockMetrics.recommendedSize, .medium)).foregroundStyle(sh.lanternText)
        return Text("\(title)  \(tag)").font(.sh(.body))
    }
}

/// The last row where the asker takes words: the same radio (picked while it holds words), a
/// plain field ("Something else…"), and its number.
public struct SHQuestionTextRow: View {
    @Binding var text: String
    let focus: FocusState<SHQuestionDockField?>.Binding
    /// The row's number, trailing; nil without keys.
    let number: Int?
    @State private var hovering = false

    public static let placeholder = "Something else…"

    public init(text: Binding<String>, focus: FocusState<SHQuestionDockField?>.Binding, number: Int?) {
        _text = text
        self.focus = focus
        self.number = number
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHQuestionDockMetrics.self
        let typed = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #if os(macOS)
        let B = SHQuestionBoardMetrics.self
        let shape = RoundedRectangle(cornerRadius: B.rowRadius)
        HStack(alignment: .top, spacing: B.rowSpacing) {
            if let number { SHQuestionKeyChip(number: number, on: typed) }
            TextField(text: $text, prompt: Text(Self.placeholder).foregroundStyle(sh.textTertiary), axis: .vertical) {
                Text(Self.placeholder)
            }
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .font(.sh(.body))
            .foregroundStyle(sh.textPrimary)
            .tint(sh.lantern)
            .focused(focus, equals: .text)
            .padding(.top, B.bodyTop)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Something else")
        }
        .padding(B.rowPadding)
        .background(typed ? sh.bgSelected : hovering ? sh.bgHover : .clear, in: shape)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .onTapGesture { focus.wrappedValue = .text }
        #else
        HStack(alignment: .top, spacing: M.rowSpacing) {
            SHQuestionRadio(picked: typed)
            TextField(text: $text, prompt: Text(Self.placeholder).foregroundStyle(sh.textTertiary), axis: .vertical) {
                Text(Self.placeholder)
            }
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .font(.sh(.body))
            .foregroundStyle(sh.textPrimary)
            .tint(sh.lantern)
            .focused(focus, equals: .text)
            .padding(.vertical, M.textRowInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Something else")
            if let number {
                Text("\(number)").font(.shMono(M.numberSize)).monospacedDigit().foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(M.rowPadding)
        #if os(iOS)
        .frame(minHeight: SH.Height.touch)
        #endif
        .background(hovering ? sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SHQuestionDockMetrics.controlRadius))
        .contentShape(RoundedRectangle(cornerRadius: SHQuestionDockMetrics.controlRadius))
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .onTapGesture { focus.wrappedValue = .text }
        #endif
    }
}

#if os(macOS)
/// A row's key: a 20pt rounded square on a `lineSubtle` line holding its number in mono 11,
/// filled with ink once picked.
struct SHQuestionKeyChip: View {
    let number: Int
    let on: Bool

    var body: some View {
        let sh = Color.sh
        let B = SHQuestionBoardMetrics.self
        let shape = RoundedRectangle(cornerRadius: B.chipRadius)
        Text("\(number)").font(.shMono(B.chipSize)).monospacedDigit()
            .foregroundStyle(on ? sh.textOnPrimary : sh.textSecondary)
            .frame(width: B.chip, height: B.chip)
            .background(on ? sh.primary : sh.bgRaised, in: shape)
            .shBorder(on ? .clear : sh.lineSubtle, in: shape)
            .accessibilityHidden(true)
    }
}
#endif

/// A key in the footer's hints: smaller than `SHKeycap` (the board's inline caps).
struct SHQuestionKeycap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        let M = SHQuestionDockMetrics.self
        Text(key).font(.shMono(M.keycapSize)).foregroundStyle(Color.sh.textSecondary)
            .padding(.horizontal, M.keycapPadding)
            .padding(.vertical, M.keycapLine)
            .shBorder(Color.sh.lineStrong, radius: M.keycapRadius)
    }
}

/// Skip (ghost: `textSecondary`, `bgHover` under the pointer) and Answer (`lantern`, semibold),
/// 28pt at radius 7 in Geist 13, as the board draws them.
struct SHQuestionDockButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        SHQuestionDockButton(configuration: configuration, primary: primary)
    }
}

private struct SHQuestionDockButton: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        let M = SHQuestionDockMetrics.self
        let shape = RoundedRectangle(cornerRadius: M.controlRadius)
        let pressed = enabled && configuration.isPressed
        let fill: Color = primary
            ? (pressed ? sh.primaryPressed : hovering && enabled ? sh.primaryHover : sh.primary)
            : (pressed ? sh.bgSelected : hovering && enabled ? sh.bgHover : .clear)
        #if os(macOS)
        let B = SHQuestionBoardMetrics.self
        let pill = Capsule()
        configuration.label
            .font(.sh(.ui))
            .lineLimit(1)
            .foregroundStyle(primary ? sh.textOnPrimary : hovering && enabled ? sh.textPrimary : sh.textSecondary)
            .padding(.horizontal, primary ? B.answerPadding : B.skipPadding)
            .frame(height: B.buttonHeight)
            .background(fill, in: pill)
            .shEnabledOpacity(enabled)
            .contentShape(pill)
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
            .shFocusRing(radius: B.buttonHeight / 2)
        #else
        configuration.label
            .font(.shSans(M.buttonSize, primary ? .semibold : .regular))
            .lineLimit(1)
            .foregroundStyle(primary ? sh.textOnPrimary : hovering && enabled ? sh.textPrimary : sh.textSecondary)
            .padding(.horizontal, primary ? M.answerPadding : M.skipPadding)
            .frame(height: SH.Height.controlM)
            .background(fill, in: shape)
            .shEnabledOpacity(enabled)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
            .shFocusRing(radius: M.controlRadius)
        #endif
    }
}

// MARK: Yes or no

/// A yes or a no's number: a 20pt rounded square, outlined at rest and filled once picked.
struct SHQuestionDockNumber: View {
    let number: Int
    let picked: Bool

    var body: some View {
        let sh = Color.sh
        let side = SHQuestionDockMetrics.yesNoNumber
        Text("\(number)").font(.shMono(SHQuestionDockMetrics.numberSize, picked ? .semibold : .regular)).monospacedDigit()
            .foregroundStyle(picked ? sh.textOnPrimary : sh.textSecondary)
            .frame(width: side, height: side)
            .background(picked ? sh.primary : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .shBorder(picked ? sh.primary : sh.lineStrong, radius: SH.Radius.xs)
            .accessibilityHidden(true)
    }
}

/// "Recommended" on a yes or a no.
struct SHQuestionRecommendedTag: View {
    var body: some View {
        let M = SHQuestionDockMetrics.self
        Text("Recommended").font(.shSans(M.tagSize, .semibold)).foregroundStyle(Color.sh.lanternText)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, M.tagPadding)
            .frame(height: M.tagHeight)
            .background(Color.sh.lanternTint, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
    }
}

extension View {
    /// A yes or a no's card: `bgWindow` with a `lineSubtle` line at rest, `lanternTint` with a
    /// `lantern` line once picked.
    func shQuestionOptionChrome(picked: Bool) -> some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
        #if os(macOS)
        // The redesign picks with `bgSelected` and ink, as its rows do.
        return background(picked ? sh.bgSelected : .clear, in: shape)
            .shBorder(sh.lineSubtle, radius: SH.Radius.m)
            .contentShape(shape)
        #else
        return background(picked ? sh.lanternTint : sh.bgWindow, in: shape)
            .shBorder(picked ? sh.lantern : sh.lineSubtle, radius: SH.Radius.m)
            .contentShape(shape)
        #endif
    }
}

/// A hidden question (QuestionStates › hidden): the same card, one 46pt line.
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
        #if os(macOS)
        SHQuestionHiddenLine(question: question, showHelp: "Show the question (\(keys.hide))", show: show)
            .padding(.leading, SHQuestionBoardMetrics.headInset.leading + SHQuestionBoardMetrics.padding.leading)
            .padding(.trailing, SHQuestionDockMetrics.hiddenTrailing)
            .frame(height: SHQuestionBoardMetrics.hiddenHeight)
            .shQuestionCard()
        #else
        SHQuestionHiddenLine(question: question, showHelp: "Show the question (\(keys.hide))", show: show)
            .padding(.leading, SHQuestionDockMetrics.hiddenLeading)
            .padding(.trailing, SHQuestionDockMetrics.hiddenTrailing)
            .frame(height: SHQuestionDockMetrics.hiddenHeight)
            .shQuestionCard()
        #endif
    }
}

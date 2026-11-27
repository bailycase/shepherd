import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSidebar

// The pieces Issues & PRs' sidebar list, pages and pins share: tone colors, dots, avatars, the
// state tag, activity rows and the floating field.

extension ForgeTone {
    /// Every tone but merged is the agent state of its name.
    var agentState: AgentState? { AgentState(rawValue: rawValue) }
    /// Merged has no agent state: it draws in the syntax keyword's purple, as the boards do.
    @MainActor var color: Color { agentState?.color ?? Color.sh.synKeyword }
    @MainActor var textColor: Color { agentState?.textColor ?? Color.sh.synKeyword }
    @MainActor var fill: Color { agentState?.tint ?? Color.sh.bgSelected }
}

/// A row's state dot.
struct ForgeDot: View {
    let tone: ForgeTone

    var body: some View {
        Circle().fill(tone.color).frame(width: SHPageMetrics.dot, height: SHPageMetrics.dot).accessibilityHidden(true)
    }
}

/// An author's initial in a circle (the boards' `.av`): `bgSelected`, 10 semibold in `textSecondary`.
struct ForgeAvatar: View {
    let login: String
    var you = false
    var size: CGFloat = AppLayout.forgeAvatarSize

    var body: some View {
        Text(login.first.map { String($0).uppercased() } ?? "?")
            .font(.shSans(AppLayout.forgeAvatarFont, .semibold))
            .foregroundStyle(Color.sh.textSecondary)
            .frame(width: size, height: size)
            .background(Color.sh.bgSelected, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The page's state chip (the boards' `.prs`): "Open", "Draft", "Merged" in 12 medium on `bgSelected` at radius 10, with a
/// chevron when it is a menu. Pins and the pane use its glyph and tone.
struct ForgeStateTag: View {
    let label: String
    let tone: ForgeTone
    var symbol: String? = nil
    var chevron = false
    /// The page's own chip: neutral, whatever the state.
    var plain = false

    var body: some View {
        HStack(spacing: SH.Space.xs) {
            if let symbol { Image(systemName: symbol).font(.sh(.caption)) }
            Text(label).font(plain ? .sh(.caption, weight: .medium) : .sh(.ui))
            if chevron {
                Image(systemName: "chevron.down").font(.shSans(AppLayout.forgeChevron, .semibold))
                    .foregroundStyle(plain ? Color.sh.textTertiary : tone.textColor)
            }
        }
        .foregroundStyle(plain ? Color.sh.textPrimary : tone.textColor)
        .padding(.horizontal, plain ? SH.Space.m : SH.Space.s)
        .frame(height: plain ? AppLayout.forgeTagHeight : SH.Height.controlS - SH.Space.xxs)
        .background(plain ? Color.sh.bgSelected : tone.fill,
                    in: RoundedRectangle(cornerRadius: plain ? AppLayout.forgeTagRadius : SH.Radius.s))
        .fixedSize()
    }
}

/// A rail section's caption ("Reviewers", "Checks · 3 of 4 passed").
struct ForgeCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).accessibilityAddTraits(.isHeader)
    }
}

/// One Activity line (PRReview, IssueReview): a card with the event's glyph, who and what, and
/// when; a comment, or a review with words, shows them under its author.
struct ForgeActivityRow: View, Equatable {
    let event: ForgeEvent
    let viewer: String?
    let kind: ForgeKind
    let now: Date
    /// A review shows its line comments, each under its file, line and hunk (the side pane's PRPane).
    var lineComments = false
    /// Drawn as the side pane's Activity (GXPanePR): events are plain rows, words sit in an outlined box.
    var pane = false

    var body: some View {
        if pane { paneBody } else { pageBody }
    }

    /// The page's Activity (the boards' `.act` and `.rvw`): a plain row per event, a box around a comment or review.
    @ViewBuilder private var pageBody: some View {
        let line = ForgePresentation.line(event, viewer: viewer)
        let age = ForgePresentation.age(event.at, now: now)
        if Self.words(event) != nil || isReviewWithComments {
            ForgeCommentBox(event: event, text: Self.commaText(line.text), you: isViewer, age: age, words: Self.words(event) ?? "",
                            comments: { if case .reviewed(_, _, let comments) = event.kind { comments } else { [] } }())
                .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: SH.Space.m) {
                Image(systemName: glyph).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    .frame(width: AppLayout.forgeAvatarSize)
                    .accessibilityHidden(true)
                Text(line.actor).fontWeight(.medium).foregroundStyle(Color.sh.textPrimary)
                    + Text(" " + Self.commaText(line.text)).foregroundStyle(Color.sh.textSecondary)
                Spacer(minLength: SH.Space.m)
                Text(age).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            }
            .font(.sh(.ui, weight: .regular))
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: AppLayout.forgeActivityRow, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// The boards write "requested changes, 2 comments on outbox.go" where the presentation has a dot.
    static func commaText(_ text: String) -> String { text.replacingOccurrences(of: " · ", with: ", ") }

    private var paneBody: some View {
        let line = ForgePresentation.line(event, viewer: viewer)
        let age = ForgePresentation.age(event.at, now: now)
        return Group {
            if lineComments, case .reviewed(let state, let body, let comments) = event.kind, !body.isEmpty || !comments.isEmpty {
                ForgeReviewCard(event: event, state: state, words: body, comments: comments, you: isViewer, age: age, pane: pane)
            } else if let body = Self.words(event) {
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    HStack(spacing: SH.Space.m) {
                        ForgeAvatar(login: event.actor, you: isViewer)
                        Text(event.actor).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                        if case .reviewed = event.kind {
                            Text(line.text).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textSecondary)
                        }
                        Spacer(minLength: SH.Space.m)
                        Text(age).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    }
                    Text(body)
                        .font(.sh(.body))
                        .foregroundStyle(Color.sh.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, AppLayout.forgeAvatar + SH.Space.m)
                }
                .padding(SH.Space.l)
            } else {
                HStack(spacing: SH.Space.m) {
                    Image(systemName: glyph).font(.sh(.caption)).foregroundStyle(glyphColor)
                        .frame(width: pane ? AppLayout.prPaneEventGlyph : AppLayout.forgeRowAvatar)
                    Text("\(Text(line.actor).font(.sh(.ui, weight: pane ? .medium : .semibold)).foregroundStyle(Color.sh.textPrimary)) \(line.text)")
                        .font(.sh(.ui, weight: .regular))
                        .foregroundStyle(Color.sh.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: SH.Space.m)
                    Text(age).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
                .padding(.horizontal, pane ? 0 : SH.Space.l)
                .frame(minHeight: pane ? AppLayout.prPaneEventHeight : SH.Height.controlL + SH.Space.xxs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ForgeEventBox(pane: pane, plain: Self.words(event) == nil && !(lineComments && isReviewWithComments)))
        .accessibilityElement(children: .combine)
    }

    private var isViewer: Bool { viewer.map { $0.caseInsensitiveCompare(event.actor) == .orderedSame } ?? false }

    private var isReviewWithComments: Bool {
        if case .reviewed(_, let body, let comments) = event.kind { !body.isEmpty || !comments.isEmpty } else { false }
    }

    /// A comment's or a review's words, if it said any.
    static func words(_ event: ForgeEvent) -> String? {
        switch event.kind {
        case .commented(let body): body.isEmpty ? nil : body
        case .reviewed(_, let body, _): body.isEmpty ? nil : body
        default: nil
        }
    }

    private var glyph: String {
        switch event.kind {
        case .opened, .reopened, .readyForReview: ForgeSymbol.kind(kind)
        case .commented, .reviewed: ForgeSymbol.comment
        case .pushed: ForgeSymbol.push
        case .merged: ForgeSymbol.merge
        case .closed: "xmark"
        case .convertedToDraft: "circle"
        case .assigned: "person"
        case .referenced: ForgeSymbol.link
        }
    }

    private var glyphColor: Color {
        switch event.kind {
        case .opened, .reopened, .readyForReview: ForgeTone.done.color
        case .reviewed(let state, _, _): ForgePresentation.tone(state).color
        case .merged: ForgeTone.merged.color
        case .closed: ForgeTone.failed.color
        default: Color.sh.textTertiary
        }
    }
}

/// A comment or review on the page (the boards' `.rvw`): its author and what they did over their words; a review's line
/// comments each under their file and line, with the hunk's last lines.
private struct ForgeCommentBox: View {
    let event: ForgeEvent
    let text: String
    let you: Bool
    let age: String
    let words: String
    let comments: [ForgeLineComment]

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.m) {
                ForgeAvatar(login: event.actor, you: you)
                (Text(event.actor).fontWeight(.medium).foregroundStyle(sh.textPrimary) + Text(" " + text).foregroundStyle(sh.textSecondary))
                    .lineLimit(1)
                Spacer(minLength: SH.Space.m)
                Text(age).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
            }
            .font(.sh(.ui, weight: .regular))
            .padding(.horizontal, AppLayout.forgeBoxInset)
            .padding(.vertical, SH.Space.m)
            if !words.isEmpty { paragraph(words) }
            ForEach(comments) { comment in
                (Text(comment.path).font(.shMono(SHTextStyle.caption.size)) + Text(comment.line.map { ", line \($0)" } ?? ""))
                    .font(.sh(.caption))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, AppLayout.forgeBoxInset)
                    .padding(.bottom, SH.Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !comment.diffHunk.isEmpty { hunk(comment.diffHunk, endingAt: comment.line) }
                paragraph(comment.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: AppLayout.forgeBoxRadius))
        .shBorder(sh.lineSubtle, radius: AppLayout.forgeBoxRadius)
        .padding(.vertical, SH.Space.xs)
    }

    /// A comment's words with their inline Markdown (`code`, **bold**, links) as written.
    private func paragraph(_ text: String) -> some View {
        let words = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(words)
            .shText(.ui)
            .foregroundStyle(Color.sh.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, AppLayout.forgeBoxInset)
            .padding(.top, SH.Space.m)
            .padding(.bottom, AppLayout.forgeBoxInset)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The hunk's last two lines, numbered as the new side counts them.
    private func hunk(_ hunk: String, endingAt line: Int?) -> some View {
        let lines = Self.numbered(hunk, endingAt: line).suffix(AppLayout.prPaneHunkLines)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 0) {
                    Text(line.number.map(String.init) ?? "")
                        .foregroundStyle(Color.sh.textTertiary)
                        .frame(width: AppLayout.forgeHunkNumber, alignment: .trailing)
                        .padding(.trailing, SH.Space.l)
                    Text(line.text).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.shMono(SHTextStyle.caption.size - 0.5))
            }
        }
        .padding(.vertical, SH.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sh.bgHover)
    }

    /// Each line after the `@@` header with its new-side number (none for a removed line); the diff marker leaves the text. A
    /// hunk the host trimmed to its last lines has no header: the comment's line is its last line's, counted back.
    static func numbered(_ hunk: String, endingAt last: Int?) -> [(number: Int?, text: String)] {
        var rows: [(removed: Bool, text: String)] = []
        var start: Int?
        for raw in hunk.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("@@") {
                if let plus = raw.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    start = Int(plus.dropFirst().split(separator: ",").first ?? "")
                }
                continue
            }
            rows.append((raw.first == "-", String(raw.dropFirst())))
        }
        var out: [(number: Int?, text: String)] = rows.map { (nil, $0.text) }
        if let start {
            var number = start
            for index in rows.indices where !rows[index].removed { out[index].number = number; number += 1 }
        } else if let last {
            var number = last
            for index in rows.indices.reversed() where !rows[index].removed { out[index].number = number; number -= 1 }
        }
        return out
    }
}

/// An Activity entry's box: a raised card on the page; in the side pane an outlined box around words and none around a plain event.
private struct ForgeEventBox: ViewModifier {
    let pane: Bool
    let plain: Bool

    func body(content: Content) -> some View {
        if pane {
            content.shBorder(plain ? .clear : Color.sh.lineSubtle, radius: AppLayout.prPaneBoxRadius)
                .padding(.vertical, plain ? 0 : SH.Space.xs)
        } else {
            content.shCard()
        }
    }
}

/// A review with its words and line comments (PRPane): who and what they asked, then each
/// comment's file and line, the hunk's last lines and the words.
private struct ForgeReviewCard: View {
    let event: ForgeEvent
    let state: ForgeReviewState
    let words: String
    let comments: [ForgeLineComment]
    let you: Bool
    let age: String
    var pane = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.m) {
                ForgeAvatar(login: event.actor, you: you)
                Text(event.actor).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                Text(ForgePresentation.line(ForgeEvent(id: event.id, actor: event.actor, at: event.at,
                                                       kind: .reviewed(state: state, body: "", comments: [])), viewer: nil).text)
                    .font(.sh(.ui))
                    .foregroundStyle(state == .changesRequested ? ForgeTone.failed.textColor : Color.sh.textSecondary)
                Spacer(minLength: SH.Space.m)
                Text(age).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            }
            .padding(SH.Space.m)
            if !words.isEmpty { paragraph(words) }
            ForEach(comments) { comment in
                SHHairline()
                HStack(spacing: SH.Space.s) {
                    Text(comment.path).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.middle)
                    if let line = comment.line { Text("line \(line)").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
                }
                .padding(.horizontal, SH.Space.m)
                .padding(.vertical, SH.Space.s)
                let hunk = comment.diffHunk.split(separator: "\n", omittingEmptySubsequences: false).suffix(AppLayout.prPaneHunkLines)
                if !comment.diffHunk.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hunk.enumerated()), id: \.offset) { _, text in
                            Text(String(text))
                                .font(.sh(.code))
                                .foregroundStyle(Color.sh.textPrimary)
                                .lineLimit(1)
                                .padding(.horizontal, SH.Space.m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(text.hasPrefix("+") ? Color.sh.doneTint : text.hasPrefix("-") ? Color.sh.failedTint : Color.clear)
                        }
                    }
                    .padding(.vertical, SH.Space.xs)
                    .background(Color.sh.bgSunken)
                }
                paragraph(comment.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ForgeEventBox(pane: pane, plain: false))
        .accessibilityElement(children: .combine)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.sh(.body))
            .foregroundStyle(Color.sh.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, AppLayout.forgeAvatar + SH.Space.l + SH.Space.m)
            .padding(.trailing, SH.Space.m)
            .padding(.vertical, SH.Space.m)
    }
}

/// The dock under a page (PRReview's Ask the agent, IssueReview's Leave a comment): the composer's card, 720 wide at the
/// leading edge, its button sending what is typed.
struct ForgeFloatingField: View {
    let placeholder: String
    /// The send button: an arrow in the ink circle, or the words in a link.
    let sendTitle: String?
    let sending: Bool
    let send: (String) async -> Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 0) {
            SHComposer(isFocused: focused, layout: .inline, above: { EmptyView() }, top: { EmptyView() }, leading: { EmptyView() }, field: {
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.sh.textTertiary), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.sh(.body))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(submit)
                    .accessibilityLabel(placeholder)
                    .padding(.leading, SH.Space.m)
            }, controls: {
                if let sendTitle {
                    Button(sendTitle, action: submit)
                        .buttonStyle(.shLink(color: empty || sending ? Color.sh.textTertiary : Color.sh.textPrimary, font: .sh(.ui, weight: .medium)))
                        .padding(.horizontal, SH.Space.m)
                        .disabled(empty || sending)
                } else {
                    SHComposerActionButton(.send, enabled: !empty && !sending, action: submit)
                }
            })
            .frame(maxWidth: AppLayout.forgeComposerWidth)
            Spacer(minLength: 0)
        }
        .padding(.leading, AppLayout.forgePageLeading)
        .padding(.trailing, AppLayout.forgePageTrailing)
        .padding(.bottom, AppLayout.forgeComposerBottom)
    }

    private func submit() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !sending else { return }
        Task { if await send(words) { text = "" } }
    }
}

/// A rail row: a thread linked to the item (`.rr` and `.gch-rsub`): its glyph and title, and where it runs under them.
struct ForgeThreadLinkRow: View {
    let link: ForgeThreadLink
    /// An issue's Linked row says how the thread is going.
    var showsState = false
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: open) {
                HStack(spacing: SH.Space.m) {
                    Image(systemName: ForgeSymbol.comment).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                        .frame(width: AppLayout.forgeAvatarSize)
                        .accessibilityHidden(true)
                    Text(link.title).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                    Spacer(minLength: SH.Space.s)
                    if showsState {
                        Text(link.running ? "Running" : "Idle").font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                    }
                }
                .frame(minHeight: AppLayout.forgeRailRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the thread")
            .accessibilityLabel("\(link.title), \(link.running ? "running" : "idle"), open the thread")
            Text([link.branch, "this Mac"].compactMap { $0 }.joined(separator: ", "))
                .font(.shMono(SHTextStyle.caption.size))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, AppLayout.forgeAvatarSize + SH.Space.m)
        }
    }
}

extension String {
    /// "changes requested" as "Changes requested".
    var forgeCapitalized: String { prefix(1).uppercased() + dropFirst() }
}

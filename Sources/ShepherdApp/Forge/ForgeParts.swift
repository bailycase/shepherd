import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

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

/// The glyphs Issues & PRs draws. The boards' octicons have no SF Symbol; these are the nearest.
enum ForgeSymbol {
    static let pullRequest = "arrow.triangle.pull"
    static let issue = "smallcircle.circle"
    static let merge = "arrow.triangle.merge"
    static let comment = "text.bubble"
    static let push = "circle.and.line.horizontal"
    static let link = "link"
    static let external = "arrow.up.right.square"
    static let review = "checkmark.bubble"
    static let filter = "line.3.horizontal.decrease"
    static let edit = "pencil"

    static func kind(_ kind: ForgeKind) -> String { kind == .pullRequest ? pullRequest : issue }
}

/// A row's state dot.
struct ForgeDot: View {
    let tone: ForgeTone

    var body: some View {
        Circle().fill(tone.color).frame(width: SHPageMetrics.dot, height: SHPageMetrics.dot).accessibilityHidden(true)
    }
}

/// An author's initial in a circle; lantern when it is you.
struct ForgeAvatar: View {
    let login: String
    var you = false
    var size: CGFloat = AppLayout.forgeAvatar

    var body: some View {
        Text(login.first.map { String($0).uppercased() } ?? "?")
            .font(.sh(.micro))
            .foregroundStyle(you ? Color.sh.lanternText : Color.sh.textSecondary)
            .frame(width: size, height: size)
            .background(you ? Color.sh.lanternTint : Color.sh.bgSelected, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The page's state tag ("Open", "Merged"): its glyph, word and, as a menu, a chevron.
struct ForgeStateTag: View {
    let label: String
    let tone: ForgeTone
    var symbol: String? = nil
    var chevron = false

    var body: some View {
        HStack(spacing: SH.Space.xs) {
            if let symbol { Image(systemName: symbol).font(.sh(.caption)) }
            Text(label).font(.sh(.ui))
            if chevron { Image(systemName: "chevron.down").font(.sh(.micro)) }
        }
        .foregroundStyle(tone.textColor)
        .padding(.horizontal, SH.Space.s)
        .frame(height: SH.Height.controlS - SH.Space.xxs)
        .background(tone.fill, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .fixedSize()
    }
}

/// A rail section's caption ("Reviewers", "Checks · 3 of 4 passed").
struct ForgeCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary).accessibilityAddTraits(.isHeader)
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

    var body: some View {
        let line = ForgePresentation.line(event, viewer: viewer)
        let age = ForgePresentation.age(event.at, now: now)
        Group {
            if lineComments, case .reviewed(let state, let body, let comments) = event.kind, !body.isEmpty || !comments.isEmpty {
                ForgeReviewCard(event: event, state: state, words: body, comments: comments, you: isViewer, age: age)
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
                    Image(systemName: glyph).font(.sh(.caption)).foregroundStyle(glyphColor).frame(width: AppLayout.forgeRowAvatar)
                    Text("\(Text(line.actor).fontWeight(.semibold).foregroundStyle(Color.sh.textPrimary)) \(line.text)")
                        .font(.sh(.ui, weight: .regular))
                        .foregroundStyle(Color.sh.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: SH.Space.m)
                    Text(age).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
                .padding(.horizontal, SH.Space.l)
                .frame(minHeight: SH.Height.controlL + SH.Space.xxs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard()
        .accessibilityElement(children: .combine)
    }

    private var isViewer: Bool { viewer.map { $0.caseInsensitiveCompare(event.actor) == .orderedSame } ?? false }

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

/// A review with its words and line comments (PRPane): who and what they asked, then each
/// comment's file and line, the hunk's last lines and the words.
private struct ForgeReviewCard: View {
    let event: ForgeEvent
    let state: ForgeReviewState
    let words: String
    let comments: [ForgeLineComment]
    let you: Bool
    let age: String

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
        .shCard()
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

/// The floating field under a page (PRReview's Ask the agent, IssueReview's Leave a comment): a
/// raised capsule over the page's bottom, its button sending what is typed.
struct ForgeFloatingField: View {
    let placeholder: String
    /// The send button: an arrow in a lantern circle, or a titled button.
    let sendTitle: String?
    let sending: Bool
    let send: (String) async -> Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: SH.Space.m) {
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.sh.textTertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.sh(.body))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel(placeholder)
            if let sendTitle {
                Button(sendTitle, action: submit)
                    .buttonStyle(.sh(.secondary, size: .s))
                    .disabled(empty || sending)
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.sh(.headline))
                        .foregroundStyle(Color.sh.textOnLantern)
                        .frame(width: AppLayout.forgeSendButton, height: AppLayout.forgeSendButton)
                        .background(empty ? Color.sh.lineStrong : Color.sh.lantern, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(empty || sending)
                .accessibilityLabel("Send")
            }
        }
        .padding(.leading, SH.Space.l)
        .padding(.trailing, SH.Space.s)
        .frame(maxWidth: AppLayout.forgeComposerWidth)
        .frame(minHeight: AppLayout.forgeComposerHeight)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.l))
        .shBorder(focused ? Color.sh.running : Color.sh.lineStrong, radius: SH.Radius.l)
        .shPopover(radius: SH.Radius.l)
        .padding(.horizontal, SH.Space.l)
        .padding(.bottom, AppLayout.forgeComposerBottom)
    }

    private func submit() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !sending else { return }
        Task { if await send(words) { text = "" } }
    }
}

/// A rail row: a thread linked to the item, its dot, title and word, and where it runs.
struct ForgeThreadLinkRow: View {
    let link: ForgeThreadLink
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            Button(action: open) {
                HStack(spacing: SH.Space.m) {
                    ForgeDot(tone: link.running ? .running : .idle)
                    Text(link.title).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                    Spacer(minLength: SH.Space.s)
                    Text(link.running ? "running" : "idle").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the thread")
            .accessibilityLabel("\(link.title), \(link.running ? "running" : "idle"), open the thread")
            Text([link.branch, "this Mac"].compactMap { $0 }.joined(separator: " · "))
                .font(.sh(.mono))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, SHPageMetrics.dot + SH.Space.m)
        }
    }
}

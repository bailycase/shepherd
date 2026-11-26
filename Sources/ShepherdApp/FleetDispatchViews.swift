import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import ShepherdSidebar

// Dispatches in a thread (FleetDispatch, FleetRemote) and where else a record needs a decision (FleetStates): plain values in
// (`FleetDispatchPresentation`), what a button does is the caller's (`FleetThreadActions`).

/// What the buttons on dispatch cards do. One per window; the closures read the view model when they are called, so a card
/// never holds it.
final class FleetThreadActions: @unchecked Sendable {
    var card: @MainActor (FleetCardAction, FleetDispatchCard) -> Void = { _, _ in }
    /// Opens the thread that ran a result's work (the card's Open thread), and its changes (Review changes).
    var openResult: @MainActor (FleetDispatchCard) -> Void = { _ in }
    var reviewResult: @MainActor (FleetDispatchCard) -> Void = { _ in }
    /// Opens the thread that sent this one (the header's "sent by" link).
    /// Tries the Mac's link again now (the offline banner's Retry).
    var retryHost: @MainActor () -> Void = {}
    /// The move card's Cancel (a move waiting for the turn to end) and Dismiss (a failed one).
    var cancelMove: @MainActor (UUID) -> Void = { _ in }
    var dismissMove: @MainActor (UUID) -> Void = { _ in }
}

/// What a thread draws about dispatches (`ThreadView`): the one that sent work shows its dispatches' cards where it sent them and the
/// results that came back; the one that was sent shows where it came from.
struct FleetThreadSurface: Equatable {
    /// The thread was sent from another thread or by the person: its host, sender and what the From box says.
    var sentBy: FleetSentBy?
    /// The row of the thread that started it, when this Mac can open it ("started by" is then a link).
    var sender: SidebarRowID?
    /// Its dispatch is going: "its last message goes back" shows.
    var goesBack = false
    /// The dispatches this thread sent, as cards; the thread draws each where the `fleet_dispatch` call is.
    var cards: [FleetDispatchCard] = []
    var parent: AgentID?
    var actions: FleetThreadActions?
    /// The Mac running it stopped answering: the transcript fades under the offline banner.
    var offline = false
    /// This thread is moving to another Mac, or waits to, or a move of it failed (FleetMove): the card drawn above its conversation.
    var move: FleetMoveCard?

    static func == (a: FleetThreadSurface, b: FleetThreadSurface) -> Bool {
        a.sentBy == b.sentBy && a.sender == b.sender && a.goesBack == b.goesBack && a.cards == b.cards && a.parent == b.parent
            && a.actions === b.actions && a.offline == b.offline && a.move == b.move
    }

    /// The card a `fleet_dispatch` call at `toolCallID` made.
    func card(forToolCall toolCallID: String?) -> FleetDispatchCard? {
        guard let toolCallID, let parent, let id = FleetDispatchID.forToolCall(toolCallID, agent: parent) else { return nil }
        return cards.first { $0.id == id }
    }

    /// The card of the dispatch a result message belongs to.
    func card(for result: FleetResultMessage) -> FleetDispatchCard? {
        if let id = result.dispatchID { return cards.first { $0.id == id && $0.layout == .row } }
        // A branch can outlive its dispatch card. Older results keep the title match, never a branch guess.
        return cards.filter { $0.title == result.title && $0.host == result.host && $0.layout == .row }.max { $0.createdAt < $1.createdAt }
    }
}

extension EnvironmentValues {
    @Entry var fleetThread: FleetThreadSurface? = nil
}

// MARK: - Pieces

/// Where it runs, as the boards say it beside a title: "on mini" in the quiet color.
struct FleetHostTag: View {
    let name: String

    var body: some View {
        Text("on \(FleetWherePicker.tagName(name))")
            .font(.sh(.ui, weight: .regular))
            .foregroundStyle(Color.sh.textTertiary)
            .lineLimit(1)
            .accessibilityHidden(true)
    }
}

/// A card's button.
private struct FleetCardButton: View {
    let action: FleetCardAction
    let run: () -> Void

    var body: some View {
        Button(action.title, action: run)
            .buttonStyle(.shTextAction(quiet: action == .cancel))
            .accessibilityLabel(action.title)
    }
}

// MARK: - The dispatch cards

/// One dispatch: a row of "Sent to other Macs" while it is on a Mac (FleetDispatch), or a card saying what it waits for or why it
/// didn't go (FleetStates).
struct FleetDispatchCardView: View, Equatable {
    let card: FleetDispatchCard
    var actions: FleetThreadActions?
    /// The thread that sent it draws what a card can say in a few words as one line (FleetDispatch); the Fleet page keeps the full card.
    var compactRows = false

    nonisolated static func == (a: FleetDispatchCardView, b: FleetDispatchCardView) -> Bool {
        a.card == b.card && a.actions === b.actions && a.compactRows == b.compactRows
    }

    var body: some View {
        if compactRows, let compact = card.compact {
            FleetCompactDispatchRow(card: card, compact: compact, actions: actions)
        } else {
            switch card.layout {
            case .row: row
            case .state: state
            }
        }
    }

    /// The state at the end of the title line: a word, red when it didn't go.
    private var pill: some View {
        Text(card.pill).font(.sh(.ui, weight: .regular)).foregroundStyle(card.tone == .bad ? Color.sh.failed : Color.sh.textTertiary).lineLimit(1)
    }

    private func buttons(_ list: [FleetCardAction]) -> some View {
        HStack(spacing: SH.Space.s) {
            ForEach(list, id: \.self) { action in
                FleetCardButton(action: action) { actions?.card(action, card) }
            }
        }
        .padding(.horizontal, -SH.Space.s)
    }

    /// The title line (FleetStates): an arrow, the title, where it went, and the state at the end.
    private var head: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m) {
            Image(systemName: "arrow.turn.down.right")
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .frame(width: AppLayout.fleetCompactRowGlyph)
                .accessibilityHidden(true)
            Text(card.title).font(.sh(.ui, weight: .medium)).foregroundStyle(sh.textPrimary).lineLimit(1)
            if let host = card.host { FleetHostTag(name: host) }
            Spacer(minLength: SH.Space.l)
            pill
        }
    }

    /// FleetDispatch: the title line, why it went there, and Open and Stop.
    private var row: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.m) {
            head
            Text(card.detail)
                .font(.sh(.ui, weight: .regular))
                .lineSpacing(AppLayout.fleetProseSpacing)
                .foregroundStyle(sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !card.actions.isEmpty { buttons(card.actions) }
        }
        .padding(AppLayout.fleetMoveCardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.xl, fill: sh.bgRaised, line: sh.lineStrong, lift: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.accessibilityLabel)
    }

    /// "Sending with uncommitted changes": how much of the checkout's changes has reached the Mac, and a warning above the size that takes a while.
    private func sendingProgress(_ sending: FleetSendingCard) -> some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                SHMeter(fraction: sending.fraction ?? 0, height: AppLayout.fleetMetricBarHeight)
                Text(sending.progress)
                    .font(.sh(.caption, weight: .regular))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let warning = sending.warning {
                Text(warning).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.lanternText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sending.progress)
        .accessibilityValue(sending.warning ?? "")
    }

    /// "Cloning" (FleetStates, "Repo isn't on that Mac"): git's own progress under the words, in the sending card's own bar.
    private func cloningProgress(_ cloning: FleetCloningCard) -> some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m) {
            SHMeter(fraction: cloning.fraction ?? 0, height: AppLayout.fleetMetricBarHeight)
            Text(cloning.progress)
                .font(.sh(.caption, weight: .regular))
                .foregroundStyle(sh.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cloning.progress)
    }

    /// FleetStates: the title line, what it waits for, how far it is and what the person can do.
    private var state: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.m) {
            head
            Text(card.detail)
                .font(.sh(.ui, weight: .regular))
                .lineSpacing(AppLayout.fleetProseSpacing)
                .foregroundStyle(sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let sending = card.sending { sendingProgress(sending) }
            if let cloning = card.cloning { cloningProgress(cloning) }
            if !card.actions.isEmpty { buttons(card.actions) }
        }
        .padding(AppLayout.fleetMoveCardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.xl, fill: sh.bgRaised, line: sh.lineStrong, lift: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.accessibilityLabel)
    }
}

/// A sent thread as one line (FleetDispatch, in the thread that sent it): an arrow, the title, the Mac's tag and where it stands ("back · 2m",
/// "delivering · 4m", "goes when studio wakes"). Its buttons (Open, Stop, Cancel, Run on This Mac) appear while the pointer is over it and are
/// always in its menu; the row opens the thread that runs it.
struct FleetCompactDispatchRow: View {
    let card: FleetDispatchCard
    let compact: FleetDispatchCard.Compact
    var actions: FleetThreadActions?
    @State private var hovering = false
    @Environment(\.shMotionPaused) private var motionPaused

    var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
        HStack(spacing: SH.Space.m) {
            ZStack {
                Image(systemName: "checkmark").opacity(card.pill == "Done" ? 1 : 0)
                Image(systemName: "arrow.turn.down.right").opacity(card.pill == "Done" ? 0 : 1)
            }
            .font(.sh(.caption, weight: .regular))
            .foregroundStyle(sh.textSecondary)
            .frame(width: AppLayout.fleetCompactRowGlyph)
            .accessibilityHidden(true)
            Text(card.title).font(.sh(.ui, weight: .medium)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.tail)
            words
            Spacer(minLength: SH.Space.l)
            if hovering {
                ForEach(card.actions.filter { buttonWorthy($0) }, id: \.self) { action in
                    Button(action.title) { actions?.card(action, card) }
                        .buttonStyle(.shTextAction(quiet: action == .cancel))
                }
            }
            Image(systemName: "chevron.right")
                .font(.sh(.micro, weight: .semibold))
                .foregroundStyle(sh.textTertiary)
                .opacity(card.remoteAgentID == nil ? 0 : 1)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SH.Space.l)
        .frame(maxWidth: .infinity, minHeight: AppLayout.fleetCompactRowHeight, alignment: .leading)
        .background(sh.bgRaised, in: shape)
        .shBorder(sh.lineStrong, radius: SH.Radius.m)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .onTapGesture { if card.remoteAgentID != nil { actions?.card(.open, card) } }
        .contextMenu {
            ForEach(card.actions.filter { if case .openOthers = $0 { false } else { true } }, id: \.self) { action in
                Button(action.title) { actions?.card(action, card) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityAddTraits(card.remoteAgentID == nil ? [] : .isButton)
        .modifier(FleetCardAccessibilityActions(card: card, actions: actions))
    }

    /// The line after the title: where it is and how it stands, "On mini, working · 4m", "Back from mini · 2m".
    private var lead: String {
        let host = card.host.map(FleetWherePicker.tagName)
        guard let host else { return compact.words.prefix(1).uppercased() + compact.words.dropFirst() }
        if card.pill == "Done" { return "Back from \(host)" }
        return "On \(host), \(compact.words)"
    }

    /// The buttons a row shows on hover: the ones that act on it, not the long ways around.
    private func buttonWorthy(_ action: FleetCardAction) -> Bool {
        switch action {
        case .open, .stop, .cancel, .runHereNow: true
        case .runHere, .tryAgain, .sendTo, .send, .openOthers: false
        }
    }

    @ViewBuilder private var words: some View {
        if compact.timed, card.updatedAt > 0 {
            let since = Date(timeIntervalSince1970: card.updatedAt / 1000)
            TimelineView(SHElapsedSchedule(start: since, aligned: true, paused: motionPaused)) { context in
                text("\(lead) · \(SHDuration.text(max(0, context.date.timeIntervalSince(since))))")
            }
        } else {
            text(lead)
        }
    }

    private func text(_ string: String) -> some View {
        Text(string).font(.sh(.ui, weight: .regular)).foregroundStyle(compact.tone == .bad ? Color.sh.failed : Color.sh.textTertiary).lineLimit(1)
    }
}

/// Every button of a card as a named VoiceOver action, so nothing on hover is only on hover.
private struct FleetCardAccessibilityActions: ViewModifier {
    let card: FleetDispatchCard
    var actions: FleetThreadActions?

    func body(content: Content) -> some View {
        card.actions.reduce(AnyView(content)) { view, action in
            AnyView(view.accessibilityAction(named: action.title) { actions?.card(action, card) })
        }
    }
}

/// A Mac that is linked and still taking in changes (FleetStates, "A Mac behind the fleet").
struct FleetBehindMacCard: View, Equatable {
    let mac: FleetDispatchPresentation.BehindMac

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "desktopcomputer")
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(sh.textSecondary)
                    .frame(width: AppLayout.fleetCompactRowGlyph)
                    .accessibilityHidden(true)
                Text(mac.name).font(.sh(.ui, weight: .medium)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Spacer(minLength: SH.Space.l)
                Text(mac.pill).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.lantern).lineLimit(1)
            }
            Text(mac.detail)
                .font(.sh(.ui, weight: .regular))
                .lineSpacing(AppLayout.fleetProseSpacing)
                .foregroundStyle(sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppLayout.fleetMoveCardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.xl, fill: sh.bgRaised, line: sh.lineStrong, lift: true)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The result

/// A dispatched thread's last message, back in the thread that sent it (FleetDispatch's second card): what it said, and the
/// threads and changes it made. The words are another agent's, drawn as text.
struct FleetResultCard: View, Equatable {
    let result: FleetResultMessage
    /// When it arrived, as "11:31".
    let time: String?
    let card: FleetDispatchCard?
    var actions: FleetThreadActions?

    private var title: String { card?.title ?? result.title }

    nonisolated static func == (a: FleetResultCard, b: FleetResultCard) -> Bool {
        a.result == b.result && a.time == b.time && a.card == b.card && a.actions === b.actions
    }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "checkmark")
                    .font(.sh(.caption, weight: .regular))
                    .foregroundStyle(sh.textSecondary)
                    .frame(width: AppLayout.fleetCompactRowGlyph)
                    .accessibilityHidden(true)
                (Text("Result from ") + Text(title).fontWeight(.medium).foregroundStyle(sh.textPrimary) + Text(" on \(FleetWherePicker.tagName(result.host))"))
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.l)
                if let time {
                    Text(time).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textTertiary)
                }
            }
            Text(Self.styled(result.text))
                .font(.sh(.ui, weight: .regular))
                .lineSpacing(AppLayout.fleetProseSpacing)
                .foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let notice = result.checkoutNotice {
                Text(verbatim: notice)
                    .font(.sh(.caption, weight: .regular))
                    .foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let card, card.remoteAgentID != nil {
                HStack(spacing: SH.Space.s) {
                    Button("Open thread") { actions?.openResult(card) }
                        .buttonStyle(.shTextAction)
                    if result.branch != nil {
                        Button("Review changes") { actions?.reviewResult(card) }
                            .buttonStyle(.shTextAction)
                    }
                }
                .padding(.horizontal, -SH.Space.s)
            }
        }
        .padding(AppLayout.fleetMoveCardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.xl, fill: sh.bgRaised, line: sh.lineStrong, lift: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Result from \(title) on \(result.host)")
    }

    /// The text with its inline code in mono.
    static func styled(_ text: String) -> AttributedString {
        var out = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
            out[run.range].font = .sh(.code)
        }
        return out
    }
}

// MARK: - The dispatched thread

/// A user turn a dispatch wrote (`ThreadView.fleetMessage`).
struct FleetMessageRow: View, Equatable {
    enum Kind: Equatable {
        /// The result a dispatched thread sent back, and the card of the dispatch it belongs to.
        case result(FleetResultMessage, FleetDispatchCard?)
        /// The task a dispatched thread started with, and who sent it.
        case from(FleetSentBy, String)
    }

    let kind: Kind
    let time: String?
    var actions: FleetThreadActions?

    nonisolated static func == (a: FleetMessageRow, b: FleetMessageRow) -> Bool { a.kind == b.kind && a.time == b.time && a.actions === b.actions }

    var body: some View {
        switch kind {
        case .result(let result, let card): FleetResultCard(result: result, time: time, card: card, actions: actions)
        case .from(let sentBy, let task): FleetFromBox(sentBy: sentBy, task: task, time: time)
        }
    }
}

/// What the person sent from another thread, as the dispatched thread's first message: the words that were sent, dashed, under
/// "From <thread> on <Mac> · 11:14" (FleetRemote). The instructions the host added after them are not drawn.
struct FleetFromBox: View, Equatable {
    let sentBy: FleetSentBy
    /// The task, as it was sent.
    let task: String
    let time: String?

    var body: some View {
        let sh = Color.sh
        let metrics = SHUserBubbleMetrics.standard
        VStack(alignment: .trailing, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.s) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.sh(.micro, weight: .regular))
                    .accessibilityHidden(true)
                Text([sentBy.fromLine, time].compactMap { $0 }.joined(separator: " · "))
                    .font(.sh(.caption, weight: .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(sh.textTertiary)
            Text(FleetResultCard.styled(task))
                .font(.sh(.body))
                .foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.vertical, metrics.vertical)
                .padding(.horizontal, metrics.horizontal)
                .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .shBorder(sh.lineStrong, in: RoundedRectangle(cornerRadius: SH.Radius.m), dash: AppLayout.fleetFromDash)
                .frame(maxWidth: metrics.maxWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sentBy.fromLine). \(task)")
    }
}

/// "When this finishes, its last message goes back to Speed up checkout CI. You can still talk to it here."
struct FleetGoesBackBanner: View, Equatable {
    let line: String

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Image(systemName: "arrow.left")
                .font(.sh(.micro, weight: .regular))
                .accessibilityHidden(true)
            Text(line).font(.sh(.caption, weight: .regular)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(sh.textSecondary)
        .padding(.vertical, SH.Space.m)
        .padding(.horizontal, SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .accessibilityElement(children: .combine)
    }
}

/// "Mac mini stopped answering 2 minutes ago. Work there keeps running; this view catches up when it reconnects."
struct FleetOfflineBannerView: View {
    let banner: FleetOfflineBanner
    let retry: () -> Void

    var body: some View {
        let sh = Color.sh
        // The age moves on by itself.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: SH.Space.l) {
                Image(systemName: "wifi.slash")
                    .font(.sh(.ui, weight: .medium))
                    .accessibilityHidden(true)
                Text(banner.message(now: context.date)).font(.sh(.ui, weight: .regular)).frame(maxWidth: .infinity, alignment: .leading)
                Button(action: retry) {
                    Text("Retry")
                        .font(.sh(.caption, weight: .medium))
                        .padding(.horizontal, SH.Space.l)
                        .frame(height: AppLayout.fleetCardButtonHeight)
                        .shBorder(sh.lantern, radius: SH.Radius.s)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(sh.lanternText)
            .padding(.vertical, SH.Space.m)
            .padding(.horizontal, SH.Space.xxl)
            .frame(maxWidth: .infinity)
            .background(sh.lanternTint)
            .overlay(alignment: .bottom) { SHHairline() }
            .accessibilityElement(children: .combine)
        }
    }
}

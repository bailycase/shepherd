import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

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
    var openSender: @MainActor (DispatchedFrom) -> Void = { _ in }
    /// Tries the Mac's link again now (the offline banner's Retry).
    var retryHost: @MainActor () -> Void = {}
}

/// What a thread draws about dispatches (`ThreadView`): the one that sent work shows its dispatches' cards where it sent them and the
/// results that came back; the one that was sent shows where it came from.
struct FleetThreadSurface: Equatable {
    /// The thread was sent from another thread or by the person: its host, sender and what the From box says.
    var sentBy: FleetSentBy?
    var dispatched: DispatchedFrom?
    /// Its dispatch is going: "its last message goes back" shows.
    var goesBack = false
    /// The dispatches this thread sent, as cards; the thread draws each where the `fleet_dispatch` call is.
    var cards: [FleetDispatchCard] = []
    var parent: AgentID?
    var actions: FleetThreadActions?
    /// The Mac running it stopped answering: the transcript fades under the offline banner.
    var offline = false

    static func == (a: FleetThreadSurface, b: FleetThreadSurface) -> Bool {
        a.sentBy == b.sentBy && a.dispatched == b.dispatched && a.goesBack == b.goesBack && a.cards == b.cards && a.parent == b.parent
            && a.actions === b.actions && a.offline == b.offline
    }

    /// The card a `fleet_dispatch` call at `toolCallID` made.
    func card(forToolCall toolCallID: String?) -> FleetDispatchCard? {
        guard let toolCallID, let parent, let id = FleetDispatchID.forToolCall(toolCallID, agent: parent) else { return nil }
        return cards.first { $0.id == id }
    }

    /// The card of the dispatch a result message belongs to.
    func card(for result: FleetResultMessage) -> FleetDispatchCard? {
        cards.filter { $0.title == result.title && $0.host == result.host && $0.layout == .row }.max { $0.createdAt < $1.createdAt }
    }
}

extension EnvironmentValues {
    @Entry var fleetThread: FleetThreadSurface? = nil
}

// MARK: - Pieces

/// The Mac's short name as a tag ("mini"): mono 10 on a 1pt strong line.
struct FleetHostTag: View {
    let name: String

    var body: some View {
        let sh = Color.sh
        Text(FleetWherePicker.tagName(name))
            .font(.shMono(AppLayout.fleetTagFont))
            .foregroundStyle(sh.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, SH.Space.xs)
            .frame(height: AppLayout.fleetTagHeight)
            .shBorder(sh.lineStrong, radius: SH.Radius.xs)
            .accessibilityHidden(true)
    }
}

/// A card's button.
private struct FleetCardButton: View {
    let action: FleetCardAction
    let run: () -> Void

    var body: some View {
        Button(action.title, action: run)
            .buttonStyle(.sh(.secondary, size: .s))
            .accessibilityLabel(action.title)
    }
}

// MARK: - The dispatch cards

/// One dispatch: a row of "Sent to other Macs" while it is on a Mac (FleetDispatch), or a card saying what it waits for or why it
/// didn't go (FleetStates).
struct FleetDispatchCardView: View, Equatable {
    let card: FleetDispatchCard
    var actions: FleetThreadActions?

    nonisolated static func == (a: FleetDispatchCardView, b: FleetDispatchCardView) -> Bool { a.card == b.card && a.actions === b.actions }

    var body: some View {
        switch card.layout {
        case .row: row
        case .state: state
        }
    }

    private var pill: some View { FleetDispatchStatePill(text: card.pill, tone: card.tone) }

    private func buttons(_ list: [FleetCardAction]) -> some View {
        HStack(spacing: SH.Space.m) {
            ForEach(list, id: \.self) { action in
                FleetCardButton(action: action) { actions?.card(action, card) }
            }
        }
    }

    /// FleetDispatch: the tile, the title with the Mac's tag over why it went there, the state and Open and Stop.
    private var row: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.l) {
            RoundedRectangle(cornerRadius: SH.Radius.m)
                .fill(sh.runningTint)
                .frame(width: AppLayout.fleetRowTile, height: AppLayout.fleetRowTile)
                .overlay {
                    Image(systemName: "arrow.right.to.line")
                        .font(.sh(.caption, weight: .medium))
                        .foregroundStyle(sh.running)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                HStack(spacing: SH.Space.m) {
                    Text(card.title).font(.sh(.headline)).foregroundStyle(sh.textPrimary).lineLimit(1)
                    if let host = card.host { FleetHostTag(name: host) }
                }
                Text(card.detail)
                    .font(.sh(.caption, weight: .regular))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            pill
            buttons(card.actions)
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.l, fill: sh.bgRaised, line: sh.lineSubtle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.accessibilityLabel)
    }

    /// FleetStates: the title with the Mac's tag and the state, what it waits for, and what the person can do.
    private var state: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                Text(card.title).font(.sh(.headline)).foregroundStyle(sh.textPrimary).lineLimit(1)
                if let host = card.host { FleetHostTag(name: host) }
                Spacer(minLength: SH.Space.l)
                pill
            }
            Text(card.detail)
                .font(.sh(.ui, weight: .regular))
                .lineSpacing(SHTextStyle.caption.lineSpacing)
                .foregroundStyle(sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !card.actions.isEmpty { buttons(card.actions) }
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.l, fill: sh.bgRaised, line: sh.lineSubtle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.accessibilityLabel)
    }
}

/// A Mac that is linked and still taking in changes (FleetStates, "A Mac behind the fleet").
struct FleetBehindMacCard: View, Equatable {
    let mac: FleetDispatchPresentation.BehindMac

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                Text(mac.name).font(.sh(.headline)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Spacer(minLength: SH.Space.l)
                FleetPill(text: mac.pill, dot: sh.lantern, text: sh.lanternText, fill: sh.lanternTint)
            }
            Text(mac.detail)
                .font(.sh(.ui, weight: .regular))
                .lineSpacing(SHTextStyle.caption.lineSpacing)
                .foregroundStyle(sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.l, fill: sh.bgRaised, line: sh.lineSubtle)
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

    nonisolated static func == (a: FleetResultCard, b: FleetResultCard) -> Bool {
        a.result == b.result && a.time == b.time && a.card == b.card && a.actions === b.actions
    }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "checkmark")
                    .font(.sh(.micro, weight: .semibold))
                    .foregroundStyle(sh.done)
                    .frame(width: AppLayout.fleetResultTick)
                    .accessibilityHidden(true)
                (Text("Result from ") + Text(result.title).fontWeight(.semibold).foregroundStyle(sh.textPrimary) + Text(" on \(result.host)"))
                    .font(.sh(.caption, weight: .regular))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.l)
                if let time {
                    Text(time).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary)
                }
            }
            Text(Self.styled(result.text))
                .font(.sh(.body))
                .foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let card, card.remoteAgentID != nil {
                HStack(spacing: SH.Space.m) {
                    Button("Open thread") { actions?.openResult(card) }
                        .buttonStyle(.sh(.secondary, size: .s))
                    if result.branch != nil {
                        Button("Review changes") { actions?.reviewResult(card) }
                            .buttonStyle(.sh(.secondary, size: .s))
                    }
                }
            }
        }
        .padding(.vertical, SH.Space.l)
        .padding(.horizontal, SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.l, fill: sh.bgSunken, line: sh.lineSubtle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Result from \(result.title) on \(result.host)")
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

/// The dispatched thread's header, after its title: the Mac it runs on as a pill with a dot, and "sent by <thread>" as a link.
struct FleetSentByHeader: View, Equatable {
    let sentBy: FleetSentBy
    let online: Bool
    var openSender: (() -> Void)?

    nonisolated static func == (a: FleetSentByHeader, b: FleetSentByHeader) -> Bool {
        a.sentBy == b.sentBy && a.online == b.online && (a.openSender == nil) == (b.openSender == nil)
    }

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            HStack(spacing: SH.Space.s) {
                Circle().fill(online ? sh.done : sh.textTertiary).frame(width: AppLayout.fleetDotSize, height: AppLayout.fleetDotSize)
                Text(sentBy.host).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary).lineLimit(1)
            }
            .padding(.horizontal, SH.Space.m)
            .frame(height: AppLayout.fleetHeaderPillHeight)
            .shBorder(sh.lineStrong, radius: SH.Radius.s)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(online ? "Runs on \(sentBy.host)" : "Runs on \(sentBy.host), offline")
            HStack(spacing: SH.Space.xs) {
                Text("sent by").foregroundStyle(sh.textTertiary)
                if let openSender, sentBy.fromThread {
                    Button(action: openSender) { Text(sentBy.sender).foregroundStyle(sh.running) }
                        .buttonStyle(.plain)
                        .help("Open \(sentBy.sender)")
                } else {
                    Text(sentBy.sender).foregroundStyle(sentBy.fromThread ? sh.textSecondary : sh.textTertiary)
                }
            }
            .font(.sh(.caption, weight: .regular))
            .lineLimit(1)
        }
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

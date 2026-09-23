import SwiftUI
import ShepherdDesign
import ShepherdProtocol
import ShepherdRemote

/// The 52pt thread header (spec §3, §6): project / title (the title truncates) · status pill ·
/// spacer · "n turns · 42k ctx" · the right-pane toggle · options.
struct ThreadHeader: View {
    @ObservedObject var store: NativeThreadStore
    let project: String
    let title: String
    var leadingInset: CGFloat = 0
    var paneOpen = false
    var togglePane: (() -> Void)?
    var rename: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(project).font(Fonts.label).foregroundStyle(Tokens.textTertiary).lineLimit(1).fixedSize()
                Text("/").font(Fonts.labelRegular).foregroundStyle(Tokens.textDisabled)
                Text(title).font(Fonts.title).foregroundStyle(Tokens.text).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(-1)
                    .help(title)
            }
            ThreadStatusPill(store: store)
            Spacer(minLength: 12)
            ThreadCounters(store: store)
            if let togglePane {
                Button(action: togglePane) {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(IconButtonStyle(size: Metrics.buttonMedium, tint: paneOpen ? Tokens.accent : nil))
                .background(paneOpen ? Tokens.accentBg : .clear, in: RoundedRectangle(cornerRadius: Radius.button))
                .help(paneOpen ? "Close the pane" : "Review changes")
                .accessibilityLabel(paneOpen ? "Close the pane" : "Review changes")
            }
            Menu {
                Button("Refresh Thread") { Task { await store.refresh(fresh: true) } }
                if store.olderCursor != nil {
                    Button("Load Older Messages") { Task { await store.loadOlder() } }
                }
                if let rename {
                    Divider()
                    Button("Rename…", action: rename)
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Tokens.text)
                    .frame(width: Metrics.buttonMedium, height: Metrics.buttonMedium)
                    .background(Tokens.bgSurface, in: RoundedRectangle(cornerRadius: Radius.button))
                    .overlay { RoundedRectangle(cornerRadius: Radius.button).strokeBorder(Tokens.borderStrong, lineWidth: 1) }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Thread options")
        }
        .padding(.leading, Metrics.headerPadding + leadingInset)
        .padding(.trailing, Metrics.headerPadding)
        .frame(height: Metrics.headerHeight)
        .frame(maxWidth: .infinity)
        .background(Tokens.bgSurface)
        .overlay(alignment: .bottom) { Tokens.border.frame(height: 1) }
    }
}

/// Idle / Running · elapsed / Needs you / Error, from the thread snapshot (spec §6). A subagent
/// waiting on the user outranks the parent's own state.
struct ThreadStatusPill: View {
    @ObservedObject var store: NativeThreadStore

    var body: some View {
        let state = threadPillState(store)
        if state == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                StatusPill(.running, label: "Running · \(threadRunElapsed(store, now: context.date))")
            }
        } else {
            StatusPill(state, label: state == .needsYou ? nativeSubagentNeedsYouLabel(store.subagents) ?? "Needs you" : nil)
        }
    }
}

/// "18 turns · 46k ctx" in micro; the turn count shows once the whole history is loaded.
private struct ThreadCounters: View {
    @ObservedObject var store: NativeThreadStore

    var body: some View {
        let parts = [
            store.olderCursor == nil && store.snapshot != nil ? turnsText : nil,
            store.snapshot?.stats?.contextTokens.map { "\(nativeTokenCount($0)) ctx" },
            nativeSubagentRollup(store.subagents),
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(Fonts.micro).foregroundStyle(Tokens.textMuted).lineLimit(1).fixedSize()
                .help(nativeContextTooltip(store.snapshot?.stats))
        }
    }

    private var turnsText: String {
        let turns = store.messages.count { $0.role == "user" }
        return "\(turns) turn\(turns == 1 ? "" : "s")"
    }
}

@MainActor
func threadPillState(_ store: NativeThreadStore) -> AgentPillState {
    if store.loadError != nil { return .error }
    if store.snapshot?.dialogs.isEmpty == false || nativeSubagentNeedsYouLabel(store.subagents) != nil { return .needsYou }
    if store.settledRunning { return .running }
    return .idle
}

/// Time since the turn began: the last user message's timestamp while running.
@MainActor
func threadRunElapsed(_ store: NativeThreadStore, now: Date) -> String {
    let start = store.displayedMessages.last { $0.role == "user" }?.timestamp.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
    return nativeDurationText(max(0, now.timeIntervalSince(start)), live: true)
}

/// Header when no thread is on screen (or a remote utility terminal): the same 52pt strip,
/// breadcrumb only.
struct PlainHeader: View {
    let project: String
    let title: String
    var leadingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(project).font(Fonts.label).foregroundStyle(Tokens.textTertiary).lineLimit(1)
            Text("/").font(Fonts.labelRegular).foregroundStyle(Tokens.textDisabled)
            Text(title).font(Fonts.title).foregroundStyle(Tokens.text).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, Metrics.headerPadding + leadingInset)
        .padding(.trailing, Metrics.headerPadding)
        .frame(height: Metrics.headerHeight)
        .frame(maxWidth: .infinity)
        .background(Tokens.bgSurface)
        .overlay(alignment: .bottom) { Tokens.border.frame(height: 1) }
    }
}

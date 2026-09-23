import SwiftUI
import ShepherdUI
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
                Text(project).font(Font.nw(.ui)).foregroundStyle(Color.nw.textSecondary).lineLimit(1).fixedSize()
                Text("/").font(Font.nw(.body)).foregroundStyle(Color.nw.textTertiary)
                Text(title).font(Font.nw(.title)).foregroundStyle(Color.nw.textPrimary).lineLimit(1).truncationMode(.tail)
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
                .buttonStyle(.nwIcon(bordered: true, isOn: paneOpen))
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
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.nw.textSecondary)
                    .frame(width: NW.Height.controlM, height: NW.Height.controlM)
                    .overlay { Circle().strokeBorder(Color.nw.lineStrong, lineWidth: 1) }
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Thread options")
        }
        .padding(.leading, AppLayout.headerPadding + leadingInset)
        .padding(.trailing, AppLayout.headerPadding)
        .frame(height: AppLayout.headerHeight)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

/// Idle / Running · elapsed / Needs you / Error (a lost connection, drawn as `failed`), from the
/// thread snapshot (spec §6). A subagent waiting on the user outranks the parent's own state.
struct ThreadStatusPill: View {
    @ObservedObject var store: NativeThreadStore

    var body: some View {
        let state = threadPillState(store)
        if state == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                NWStatusPill(.running, label: "Running · \(threadRunElapsed(store, now: context.date))")
            }
        } else {
            NWStatusPill(state, label: label(state))
        }
    }

    private func label(_ state: AgentState) -> String? {
        switch state {
        case .attention: nativeSubagentNeedsYouLabel(store.subagents) ?? AgentState.attention.label
        case .failed: "Error"
        default: nil
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
            Text(parts.joined(separator: " · ")).font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary).lineLimit(1).fixedSize()
                .help(nativeContextTooltip(store.snapshot?.stats))
        }
    }

    private var turnsText: String {
        let turns = store.messages.count { $0.role == "user" }
        return "\(turns) turn\(turns == 1 ? "" : "s")"
    }
}

@MainActor
func threadPillState(_ store: NativeThreadStore) -> AgentState {
    if store.loadError != nil { return .failed }
    if store.snapshot?.dialogs.isEmpty == false || nativeSubagentNeedsYouLabel(store.subagents) != nil { return .attention }
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
            Text(project).font(Font.nw(.ui)).foregroundStyle(Color.nw.textSecondary).lineLimit(1)
            Text("/").font(Font.nw(.body)).foregroundStyle(Color.nw.textTertiary)
            Text(title).font(Font.nw(.title)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, AppLayout.headerPadding + leadingInset)
        .padding(.trailing, AppLayout.headerPadding)
        .frame(height: AppLayout.headerHeight)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The iPad ⌘K palette (iPadPalette board): the field across the top, the results and actions
/// on the left, and a live preview of the selected thread on the right. The arrow keys move the
/// selection, Return opens it, Esc closes; a tap opens a row at once, and the pointer moves the
/// selection. Threads come first, then conversations, then actions for the thread on screen and
/// the app's own.
struct SearchPalette: View {
    let initialQuery: String
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var store = MobileSearchStore(includesActions: true)
    @State private var preview = PalettePreviewStore()
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: NW.Space.m) {
                NWTouchSearchField("Search threads and actions", text: $store.query, focus: $focused, large: true) {
                    if let entry = store.selected { activate(entry) }
                }
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    store.moveSelection(press.key == .upArrow ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    navigator.dismissPresented()
                    return .handled
                }
                Button { navigator.dismissPresented() } label: {
                    NWKeycap("esc").nwTouchTarget(height: NW.Height.controlS, width: NW.Height.controlS)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
                .padding(.trailing, NW.Space.l)
            }
            NWHairline()
            HStack(spacing: 0) {
                PaletteResults(sections: store.sections, selection: store.selectionID, status: store.status, idle: store.isIdle,
                               query: store.query, select: { store.select($0) }, activate: activate)
                    .frame(width: MobileLayout.paletteListWidth)
                NWHairline(.vertical)
                PalettePreviewPane(entry: store.selected, state: preview.state, activate: activate)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.nw.bgRaised)
        .toolbar(.hidden, for: .navigationBar)
        .presentationSizing(PaletteSizing())
        .presentationCornerRadius(MobileLayout.paletteRadius)
        .presentationBackground(Color.nw.bgRaised)
        .task {
            if store.query.isEmpty, !initialQuery.isEmpty { store.query = initialQuery }
            store.attach(hosts, thread: navigator.selectedThread)
            focused = true
        }
        .task(id: store.selected?.thread) {
            await preview.follow(store.selected?.thread, hosts: hosts)
        }
        .onDisappear { store.detach() }
    }

    private func activate(_ entry: SearchEntry) {
        switch entry.action {
        case .open(let ref):
            navigator.dismissPresented()
            navigator.open(.thread(ref))
        case .rename(let ref):
            navigator.present(.search(.rename(ref)))
        case .delete(let ref):
            navigator.present(.search(.delete(ref)))
        case .move(let ref, let direction):
            navigator.dismissPresented()
            let hosts = hosts
            AgentActions.run("Couldn’t move the thread", navigator: navigator) {
                try await AgentActions.move(ref, direction, hosts: hosts)
            }
        case .newThread:
            NewThreadHooks.open(navigator: navigator)
        case .settings:
            navigator.dismissPresented()
            navigator.open(.settings(.root))
        }
    }
}

/// The board's card: 820 by 560, which the system narrows to fit a smaller window.
private struct PaletteSizing: PresentationSizing {
    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        ProposedViewSize(width: MobileLayout.paletteWidth, height: MobileLayout.paletteHeight)
    }
}

/// The palette's left column: mono section headers, rows at 48pt, the selection tinted.
private struct PaletteResults: View {
    let sections: [SearchEntrySection]
    let selection: String?
    let status: SearchStatusLine
    let idle: Bool
    let query: String
    let select: (String) -> Void
    let activate: (SearchEntry) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        NWPaletteSectionHeader(section.title)
                            .padding(.top, NW.Space.s)
                        ForEach(section.entries) { entry in
                            PaletteRow(entry: entry, selected: entry.id == selection, select: select, activate: activate)
                                .equatable()
                                .id(entry.id)
                        }
                    }
                    if !idle && sections.allSatisfy({ $0.kind == .actions }) && status.searching == nil {
                        Text("No threads match “\(query)”.")
                            .font(.nw(.caption))
                            .foregroundStyle(Color.nw.textTertiary)
                            .padding(NW.Space.m)
                    }
                    SearchStatusView(status: status)
                        .padding(.horizontal, NW.Space.m)
                        .padding(.vertical, NW.Space.s)
                }
                .padding(NW.Space.s)
            }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }
}

private struct PaletteRow: View, Equatable {
    let entry: SearchEntry
    let selected: Bool
    let select: (String) -> Void
    let activate: (SearchEntry) -> Void
    @Environment(MobileNavigator.self) private var navigator

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.entry == rhs.entry && lhs.selected == rhs.selected }

    var body: some View {
        Button { activate(entry) } label: {
            NWSearchResultRow(leading: entry.leading, title: entry.title, detail: entry.detail, tag: entry.host,
                              shortcut: selected ? "↩" : nil, selected: selected, dimmed: entry.dimmed,
                              minHeight: NWSearchMetrics.compactRowHeight)
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Windows/: the row's thread in a window of its own.
            if case .open(let ref) = entry.action {
                OpenInNewWindowButton(thread: ref) { navigator.dismissPresented() }
            }
        }
        .onHover { if $0 { select(entry.id) } }
        .accessibilityLabel(entry.spoken)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The right column: what the selected row opens. A thread shows its status, where it runs,
/// its latest exchange (kept live while selected) and the matched snippet; an app action says
/// what it does.
private struct PalettePreviewPane: View {
    let entry: SearchEntry?
    let state: PalettePreviewStore.State
    let activate: (SearchEntry) -> Void
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            if let entry {
                if let thread = state.thread {
                    HStack(spacing: NW.Space.m) {
                        NWStateGlyph(thread.state)
                        Text(thread.title).font(.nw(.title)).foregroundStyle(Color.nw.textPrimary).lineLimit(2)
                    }
                    HStack(spacing: NW.Space.m) {
                        NWStatusPill(thread.state)
                        Text(thread.meta).font(.nw(.mono)).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
                    }
                    PaletteExcerpt(lines: state.lines, loading: state.loading, note: state.note)
                } else {
                    Label { Text(entry.title.map(\.text).joined()).font(.nw(.title)) } icon: {
                        if case .symbol(let name) = entry.leading { Image(systemName: name) }
                    }
                    .foregroundStyle(Color.nw.textPrimary)
                }
                if let caption = Self.caption(entry) {
                    NWHighlightedText(caption, style: .caption, color: .secondary, lines: 3)
                }
                // Windows/ (iPadPalette board): Open in new window beside Open, for a thread; under
                // it when the two don't fit side by side (large text).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NW.Space.m) { actions(entry) }
                    VStack(alignment: .leading, spacing: NW.Space.m) { actions(entry) }
                }
            } else {
                Text("Nothing selected").font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
        }
        .padding(NW.Space.l + NW.Space.xxs)
    }

    @ViewBuilder private func actions(_ entry: SearchEntry) -> some View {
        Button { activate(entry) } label: {
            HStack(spacing: NW.Space.s) {
                Text(Self.verb(entry))
                NWKeycap("↩")
            }
        }
        .buttonStyle(.nw(Self.destructive(entry) ? .danger : .primary, size: .l))
        .nwTouchTarget(height: NW.Height.controlL)
        if case .open(let ref) = entry.action {
            OpenInNewWindowButton(thread: ref, prominent: true) { navigator.dismissPresented() }
        }
    }

    private static func caption(_ entry: SearchEntry) -> [NWHighlightRun]? {
        switch entry.action {
        case .open: entry.snippet == nil ? nil : entry.detail
        case .rename: [NWHighlightRun("Give this thread a name of your own. The host keeps it; the agent won’t rename it again.")]
        case .move(_, let direction): [NWHighlightRun("Moves this thread one place \(direction == .up ? "up" : "down") in its space on every device.")]
        case .delete: [NWHighlightRun("Stops the agent and closes its thread. You confirm on the next screen.")]
        case .newThread: [NWHighlightRun("Start an agent on any connected host.")]
        case .settings: [NWHighlightRun("Hosts, appearance, and this device’s settings.")]
        }
    }

    private static func verb(_ entry: SearchEntry) -> String {
        switch entry.action {
        case .open: "Open"
        case .rename: "Rename…"
        case .move(_, let direction): direction == .up ? "Move up" : "Move down"
        case .delete: "Delete…"
        case .newThread: "New thread"
        case .settings: "Open Settings"
        }
    }

    private static func destructive(_ entry: SearchEntry) -> Bool {
        if case .delete = entry.action { return true }
        return false
    }
}

/// The selected thread's latest exchange, in a bordered box.
private struct PaletteExcerpt: View {
    let lines: [ThreadPreview.Line]
    let loading: Bool
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            if let note {
                Text(note).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
            ForEach(lines) { line in
                switch line.kind {
                case .user:
                    Text(line.text)
                        .font(.nw(.caption))
                        .foregroundStyle(Color.nw.textPrimary)
                        .lineLimit(3)
                        .padding(.horizontal, NW.Space.m)
                        .padding(.vertical, NW.Space.s)
                        .background(Color.nw.bgBubble, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                case .assistant:
                    Text(line.text)
                        .font(.nw(.caption))
                        .foregroundStyle(Color.nw.textSecondary)
                        .lineLimit(4)
                case .activity:
                    Label(line.text, systemImage: line.failed ? "xmark.circle" : "chevron.right")
                        .font(.nw(.mono))
                        .foregroundStyle(line.failed ? Color.nw.failed : Color.nw.textTertiary)
                        .lineLimit(1)
                }
            }
            if loading && lines.isEmpty {
                ProgressView().progressViewStyle(NWSpinnerStyle()).frame(maxWidth: .infinity)
            }
        }
        .padding(NW.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: MobileLayout.palettePreviewHeight, alignment: .bottom)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .background(Color.nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Latest in this thread")
    }
}

/// The palette's preview of one thread: fetched when it is selected, refreshed while it stays
/// selected (the preview is live), and kept per thread so arrowing back shows it at once.
@MainActor
@Observable
final class PalettePreviewStore {
    struct Thread: Equatable {
        var title: String
        var state: AgentState
        /// "Studio · Shepherd · claude-opus"
        var meta: String
    }

    struct State: Equatable {
        var thread: Thread?
        var lines: [ThreadPreview.Line] = []
        var loading = false
        /// Why the lines are old or missing.
        var note: String?
    }

    /// A thread's preview and the snapshot it came from, so a refresh of a thread that hasn't
    /// moved is the host's small `unchanged` answer rather than its history again.
    struct Cached {
        var preview: ThreadPreview
        var piSessionID: String
        var generation: String
        /// Nil asks the host for the whole snapshot again.
        var revision: UInt64?
    }

    private(set) var state = State()
    @ObservationIgnored private var cache: [AgentRef: Cached] = [:]
    static let refresh: Duration = .seconds(3)
    static let settle: Duration = .milliseconds(120)

    /// Follows `ref` until the task is cancelled (the selection moved or the palette closed).
    func follow(_ ref: AgentRef?, hosts: MobileHosts) async {
        guard let ref else {
            set(State())
            return
        }
        show(ref, hosts: hosts, loading: cache[ref] == nil)
        // Arrowing through rows fetches only where the selection settles.
        try? await Task.sleep(for: Self.settle)
        while !Task.isCancelled {
            guard let host = hosts.host(ref.host), host.agent(ref.agent) != nil else {
                show(ref, hosts: hosts, loading: false, note: "This thread is no longer on its host.")
                return
            }
            guard let client = host.connectedClient, host.supports(RemoteProtocol.nativeThreadCapability) else {
                show(ref, hosts: hosts, loading: false,
                     note: host.phase.isConnected ? "Update Shepherd on \(host.name) to preview threads." : "\(host.name) is offline.")
                return
            }
            do {
                let known = cache[ref]
                let result = try await client.nativeThread(agentID: ref.agent, request: .snapshot(afterRevision: known?.revision))
                guard !Task.isCancelled else { return }
                switch result {
                case .snapshot(let snapshot):
                    cache[ref] = Cached(preview: ThreadPreview(snapshot), piSessionID: snapshot.piSessionID,
                                        generation: snapshot.generation, revision: snapshot.revision)
                case .unchanged(let session, let generation, _):
                    // Another pi session with the same revision: ask again for all of it.
                    if known?.piSessionID != session || known?.generation != generation { cache[ref]?.revision = nil }
                default:
                    break
                }
                show(ref, hosts: hosts, loading: false)
            } catch {
                guard !Task.isCancelled else { return }
                show(ref, hosts: hosts, loading: false, note: "Couldn’t load the thread: \(error)")
            }
            try? await Task.sleep(for: Self.refresh)
        }
    }

    private func show(_ ref: AgentRef, hosts: MobileHosts, loading: Bool, note: String? = nil) {
        guard let host = hosts.host(ref.host) else { return set(State()) }
        let agent = host.agent(ref.agent)
        let space = agent.flatMap { agent in host.state.spaces.first { $0.id == agent.spaceID }?.name }
        let preview = cache[ref]?.preview
        let model = preview?.model.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        let thread = Thread(title: agent?.name ?? "Thread", state: AgentState(agent?.status ?? .idle),
                            meta: [host.name, space, model].compactMap { $0 }.joined(separator: " · "))
        set(State(thread: thread, lines: preview?.lines ?? [], loading: loading, note: note))
    }

    private func set(_ next: State) {
        if next != state { state = next }
    }
}

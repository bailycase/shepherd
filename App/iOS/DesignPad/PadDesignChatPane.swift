import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The design's 360pt pane (iPadDesign): its tabs, Chat (the design agent's thread on the host,
/// whose composer is one field with Send; Scribble writes into it), Tweak (the selection's
/// controls, written through `designs.v1`) and Comments (the open comments' cards, with their
/// count). The thread stays mounted under the other tabs, hidden, so switching tabs never
/// rebuilds it.
struct PadDesignChatPane: View {
    let canvas: PadDesignCanvas
    let agent: AgentRef?
    let hostName: String?

    static func tabs(open: Int) -> [NWDesignPaneTabs.Tab] {
        [NWDesignPaneTabs.Tab(id: PadDesignPaneTab.chat.rawValue, title: "Chat"),
         NWDesignPaneTabs.Tab(id: PadDesignPaneTab.tweak.rawValue, title: "Tweak"),
         NWDesignPaneTabs.Tab(id: PadDesignPaneTab.comments.rawValue, title: "Comments", count: open > 0 ? open : nil)]
    }

    var body: some View {
        @Bindable var canvas = canvas
        let tab = canvas.paneTab
        let chat = tab == .chat
        VStack(spacing: 0) {
            NWDesignPaneTabs(Self.tabs(open: canvas.openComments.count), selection: tab.rawValue, size: .touch) { id in
                canvas.paneTab = PadDesignPaneTab(rawValue: id) ?? .chat
            }
            .frame(height: MobileLayout.padDesignHeaderHeight, alignment: .bottom)
            ZStack {
                Group {
                    if let agent {
                        PadDesignChat(ref: agent)
                            .environment(\.designMarkupCanvas, canvas)
                    } else {
                        // Not drawn on any board: the least that is honest.
                        Text("This design has no agent\(hostName.map { " on \($0)" } ?? ""). Open it there to start one.")
                            .font(.nw(.caption))
                            .foregroundStyle(Color.nw.textTertiary)
                            .padding(MobileLayout.gutter)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .opacity(chat ? 1 : 0)
                .allowsHitTesting(chat)
                .accessibilityHidden(!chat)
                if tab == .comments {
                    PadDesignCommentsList(cards: canvas.cards()) { canvas.openThread($0.uuidString) }
                        .background(Color.nw.bgWindow)
                }
                if tab == .tweak {
                    PadDesignTweakPane(model: canvas.tweak, target: canvas.tweakTarget) { canvas.paneTab = .chat }
                        .background(Color.nw.bgWindow)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Color.nw.bgWindow.ignoresSafeArea())
        .overlay(alignment: .leading) { NWHairline(.vertical).ignoresSafeArea() }
    }
}

/// The design agent's thread in the pane: its turns and its composer, polling the host only while
/// on screen and the app is active, through the thread's viewers (another window may show it).
private struct PadDesignChat: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(ThreadStores.self) private var threads

    var body: some View {
        let host = hosts.host(ref.host)
        let agent = host?.agent(ref.agent)
        let store = threads.store(for: ref)
        ThreadTranscript(ref: ref, store: store, banner: banner(host: host, agent: agent, store: store))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if agent != nil {
                    ThreadComposer(ref: ref)
                        .overlay(alignment: .top) { NWHairline() }
                }
            }
            .environment(\.composerDesignChat, true)
            .environment(\.nwProseSize, .small)
            .background(Color.nw.bgWindow)
            .designAgentThread(ref)
    }

    private func banner(host: MobileHost?, agent: Agent?, store: NativeThreadStore) -> String? {
        guard let host else { return "This host was forgotten." }
        if agent == nil { return host.phase.isConnected ? "The design agent is no longer on \(host.name)." : nil }
        if !host.phase.isConnected { return "\(host.name) is offline · showing the last known chat" }
        return store.loadError
    }
}

/// Keeps the design agent's thread current while the view is on screen and the app is active:
/// its poll loop, through the thread's viewers (another window may show it too). The chat runs
/// it, and a narrow window's reply card does while the chat is folded away.
private struct DesignAgentThread: ViewModifier {
    let ref: AgentRef?
    @Environment(MobileHosts.self) private var hosts
    @Environment(ThreadStores.self) private var threads
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    private struct RunKey: Equatable {
        var ref: AgentRef?
        var session: UUID?
        var active: Bool
    }

    func body(content: Content) -> some View {
        let host = ref.flatMap { hosts.host($0.host) }
        let supported = host?.supports(RemoteProtocol.nativeThreadCapability) == true && ref.flatMap { host?.agent($0.agent) } != nil
        let key = RunKey(ref: ref, session: supported ? host?.session : nil, active: visible && scenePhase == .active)
        content
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task(id: key) {
                guard let ref else { return }
                let viewers = threads.viewers(for: ref)
                guard key.active, let session = key.session, let client = host?.connectedClient else {
                    viewers.rest(detached: key.session == nil)
                    return
                }
                let agentID = ref.agent
                await viewers.run(connection: session) { request in try await client.nativeThread(agentID: agentID, request: request) }
            }
    }
}

extension View {
    /// Polls the design agent's thread while this view is on screen (`DesignAgentThread`).
    func designAgentThread(_ ref: AgentRef?) -> some View {
        modifier(DesignAgentThread(ref: ref))
    }
}

/// The Comments tab: the open comments' cards, oldest first, one lazy row each. A card opens its
/// thread on the canvas.
private struct PadDesignCommentsList: View {
    let cards: [PadDesignCommentCard]
    let open: (UUID) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileLayout.padDesignCommentsSpacing) {
                ForEach(cards) { card in
                    Button { open(card.id) } label: {
                        NWCommentCard(number: card.number, target: card.target, meta: card.meta, text: card.text)
                            .equatable()
                    }
                    .buttonStyle(.plain)
                }
                if cards.isEmpty {
                    // Not drawn on any board: the least that is honest.
                    Text("No open comments. Pick Comment on the canvas, then tap an element.")
                        .font(.nw(.caption))
                        .foregroundStyle(Color.nw.textTertiary)
                }
            }
            .padding(MobileLayout.padDesignCommentsPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

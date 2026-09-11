import SwiftUI
import ShepherdCore
import ShepherdProtocol

struct ThreadView: View {
    @ObservedObject var connection: HostConnection
    let agentID: AgentID
    @StateObject private var store = ThreadStore()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nearBottom = true
    @State private var visible = false
    @FocusState private var composing: Bool

    private var agent: Agent? { connection.state.agents.first { $0.id == agentID } }
    private var clientID: ObjectIdentifier? {
        guard visible, scenePhase == .active, connection.phase == .connected, agent != nil,
              let client = connection.client else { return nil }
        return ObjectIdentifier(client)
    }
    private var available: Bool {
        clientID != nil && connection.client?.capabilities.contains(RemoteProtocol.nativeThreadCapability) == true
    }
    // One short line for the states that matter; the store keeps the full reason.
    private var banner: String? {
        if connection.phase != .connected { return "\(connection.phase.label) · showing last known thread" }
        if !available { return "Update Shepherd on your Mac to use native threads" }
        if let error = store.loadError { return error }
        if let snapshot = store.snapshot, !snapshot.dialogsSupported { return "Questions need the pi dialog bridge on your Mac" }
        if store.snapshot?.clipped == true { return "Some output is clipped · full thread on your Mac" }
        return nil
    }

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if agent != nil {
                        if let banner {
                            Text(banner)
                                .font(MobileTokens.caption)
                                .foregroundStyle(tokens.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if store.olderCursor != nil {
                            Button(store.loadingOlder ? "loading history…" : "load older messages") {
                                Task { await store.loadOlder() }
                            }
                            .font(MobileTokens.caption)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(!available || !store.ready || store.loadingOlder)
                        } else if store.snapshot == nil && available && store.loadError == nil {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                        }
                        ForEach(store.displayedMessages, id: \.entryID) { message in
                            ThreadMessageView(message: message)
                        }
                        if let snapshot = store.snapshot {
                            if snapshot.running, snapshot.provisional.isEmpty, snapshot.dialogs.isEmpty {
                                Label("working", systemImage: "ellipsis")
                                    .font(MobileTokens.caption)
                                    .foregroundStyle(tokens.status(.working))
                                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                            }
                            ForEach(snapshot.dialogs, id: \.id) { dialog in
                                ThreadDialogView(dialog: dialog, enabled: available && store.supports("answer")) { answer in
                                    Task {
                                        await store.answer(dialogID: dialog.id, sessionID: snapshot.piSessionID,
                                                           generation: snapshot.generation, answer: answer)
                                    }
                                }
                                .id(snapshot.generation + ":" + snapshot.piSessionID + ":" + dialog.id)
                            }
                        }
                        Color.clear.frame(height: 1).id("thread-bottom")
                    } else {
                        Text("This agent is no longer on the host.")
                            .foregroundStyle(tokens.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .padding(MobileTokens.inset)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 120
            } action: { _, value in nearBottom = value }
            .onChange(of: store.snapshot) { _, _ in
                if nearBottom { proxy.scrollTo("thread-bottom", anchor: .bottom) }
            }
            .onChange(of: store.sentCount) { _, _ in
                composing = false
                proxy.scrollTo("thread-bottom", anchor: .bottom)
            }
            .onChange(of: composing) { _, focused in
                if focused { withAnimation { proxy.scrollTo("thread-bottom", anchor: .bottom) } }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if agent != nil { composer }
        }
        .background(tokens.background)
        .font(MobileTokens.prose)
        .foregroundStyle(tokens.primary)
        .tint(tokens.accent)
        .navigationTitle(agent?.name ?? "thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(tokens.sidebar, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if let agent {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(agent.name).font(MobileTokens.heading).lineLimit(1)
                        HStack(spacing: 6) {
                            AgentStatusLabel(status: agent.status)
                            if let model = store.snapshot?.model {
                                Text("· " + model + (store.snapshot?.thinking.map { " · \($0)" } ?? ""))
                                    .font(MobileTokens.caption).lineLimit(1)
                            }
                        }
                        .foregroundStyle(tokens.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("refresh thread", systemImage: "arrow.clockwise") { Task { await store.refresh(fresh: true) } }
                        .disabled(!available)
                }
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; store.stop() }
        .task(id: clientID) {
            guard available, let client = connection.client else { store.stop(); return }
            await store.run { request in
                try await client.nativeThread(agentID: agentID, request: request)
            }
        }
    }

    private var composer: some View {
        let tokens = MobileTokens(scheme: scheme)
        let canSend = available && store.supports("send")
            && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let running = store.snapshot?.running == true
        return VStack(alignment: .leading, spacing: MobileTokens.spacing) {
            if let notice = store.notice {
                Text(notice)
                    .font(MobileTokens.caption)
                    .foregroundStyle(tokens.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack(alignment: .bottom, spacing: MobileTokens.spacing) {
                Menu {
                    Picker("delivery", selection: $store.delivery) {
                        Label("Follow-up · when agent finishes", systemImage: "text.append").tag(NativeThreadDelivery.followUp)
                        Label("Steer · after current tools", systemImage: "arrow.turn.down.right").tag(NativeThreadDelivery.steer)
                    }
                } label: {
                    Image(systemName: store.delivery == .steer ? "arrow.turn.down.right" : "text.append")
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(store.delivery == .steer ? tokens.status(.blocked) : tokens.secondary)
                }
                .accessibilityLabel("Message delivery")
                .accessibilityValue(store.delivery == .steer ? "steer" : "follow-up")

                TextField(store.delivery == .steer ? "Steer the agent" : "Message", text: $store.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textInputAutocapitalization(.sentences)
                    .focused($composing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(tokens.background, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(tokens.border, lineWidth: 1))
                    .accessibilityLabel("Message to agent")

                if running {
                    Button("cancel agent", systemImage: "stop.circle.fill") { Task { await store.abort() } }
                        .labelStyle(.iconOnly)
                        .font(.system(size: 30))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(tokens.danger)
                        .disabled(!available || !store.supports("abort"))
                }
                Button("send", systemImage: "arrow.up.circle.fill") { Task { await store.send() } }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 30))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(canSend ? tokens.accent : tokens.secondary.opacity(0.5))
                    .disabled(!canSend)
                    .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, MobileTokens.spacing)
        .padding(.vertical, MobileTokens.spacing)
        .background(tokens.sidebar)
    }
}

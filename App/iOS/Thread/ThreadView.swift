import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Thread (DESIGN.md › iOS): back · title with a status line beneath ·
// options (Stop while running); turns from nativeTurns; pill composer with Send inside the
// field; approval as a bottom sheet. Attachments are not supported by the bridge, so there is
// no attach icon (no fake affordances).
struct ThreadView: View {
    @ObservedObject var connection: HostConnection
    let agentID: AgentID
    @State private var store = NativeThreadStore()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nearBottom = true
    @State private var visible = false
    /// Sheet key the user swiped away; "Waiting for you" brings it back.
    @State private var dismissedDialog: String?
    @FocusState private var composing: Bool
    @Environment(\.dismiss) private var dismiss

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
    private var pendingDialog: NativeThreadDialog? { store.snapshot?.dialogs.first }
    private func dialogKey(_ snapshot: NativeThreadSnapshot, _ dialog: NativeThreadDialog) -> String {
        snapshot.generation + ":" + snapshot.piSessionID + ":" + dialog.id
    }
    private var sheetShown: Binding<Bool> {
        Binding(
            get: {
                guard let snapshot = store.snapshot, let dialog = pendingDialog else { return false }
                return dismissedDialog != dialogKey(snapshot, dialog)
            },
            set: { shown in
                guard !shown, let snapshot = store.snapshot, let dialog = pendingDialog else { return }
                dismissedDialog = dialogKey(snapshot, dialog)
            }
        )
    }

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        let running = store.snapshot?.running == true
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileTokens.turnSpacing) {
                    if agent != nil {
                        if let banner {
                            Text(banner)
                                .font(MobileTokens.micro)
                                .foregroundStyle(tokens.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if store.olderCursor != nil {
                            Button(store.loadingOlder ? "Loading history…" : "Load older messages") {
                                Task { await store.loadOlder() }
                            }
                            .font(MobileTokens.caption12)
                            .foregroundStyle(tokens.accentText)
                            .frame(maxWidth: .infinity, minHeight: MobileTokens.touch)
                            .disabled(!available || !store.ready || store.loadingOlder)
                        } else if store.snapshot == nil && available && store.loadError == nil {
                            HStack(spacing: 8) {
                                MobileSpinner(color: tokens.accent)
                                Text("Connecting…").font(MobileTokens.caption12).foregroundStyle(tokens.textMuted)
                            }
                            .frame(maxWidth: .infinity, minHeight: MobileTokens.touch)
                        }
                        ForEach(nativeTurns(store.displayedMessages)) { turn in
                            if turn.isUser {
                                MobileUserTurn(messages: turn.messages)
                            } else {
                                MobileAgentTurn(messages: turn.messages, running: running)
                            }
                        }
                        if let snapshot = store.snapshot, snapshot.running, snapshot.provisional.isEmpty, snapshot.dialogs.isEmpty {
                            MobileThinkingDisclosure(text: nil, streaming: true)
                        }
                        Color.clear.frame(height: 1).id("thread-bottom")
                    } else {
                        Text("This agent is no longer on the host.")
                            .font(MobileTokens.caption12)
                            .foregroundStyle(tokens.textMuted)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .padding(.horizontal, MobileTokens.inset)
                .padding(.vertical, MobileTokens.inset)
            }
            // Follow the tail: open at the bottom and stay pinned while streaming text grows in
            // place; scrolling up detaches, sending re-attaches.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(nearBottom ? .bottom : nil, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // containerSize excludes the insets and the offset starts at -top, so this is 0 at the tail.
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height - geometry.contentInsets.top < 120
            } action: { _, value in nearBottom = value }
            .onChange(of: store.snapshot) { _, _ in
                if nearBottom { proxy.scrollTo("thread-bottom", anchor: .bottom) }
            }
            .onChange(of: store.sentCount) { _, _ in
                composing = false
                nearBottom = true
                proxy.scrollTo("thread-bottom", anchor: .bottom)
            }
            .onChange(of: composing) { _, focused in
                if focused { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { proxy.scrollTo("thread-bottom", anchor: .bottom) } }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if agent != nil { composer }
        }
        .background(tokens.surface)
        .font(MobileTokens.prose)
        .foregroundStyle(tokens.text)
        .tint(tokens.accent)
        .navigationTitle(agent?.name ?? "Thread")
        // The system bar centres its title and wraps leading items in a capsule; the thread wants
        // back · leading title with a status line · trailing actions on a flat 52pt row.
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 4) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(tokens.text)
                        .frame(width: MobileTokens.touch, height: MobileTokens.touch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                if let agent { header(agent, tokens) }
                Spacer(minLength: 0)
                if agent != nil, running || pendingDialog != nil {
                    Button { Task { await store.abort() } } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(tokens.dangerText)
                            .frame(width: MobileTokens.touch, height: MobileTokens.touch)
                    }
                    .buttonStyle(.plain)
                    .disabled(!available || !store.supports("abort"))
                    .accessibilityLabel("Stop agent")
                }
                if agent != nil {
                    Menu {
                        Picker("Delivery", selection: $store.delivery) {
                            Label("Follow-up · when agent finishes", systemImage: "text.append").tag(NativeThreadDelivery.followUp)
                            Label("Steer · after current tools", systemImage: "arrow.turn.down.right").tag(NativeThreadDelivery.steer)
                        }
                        Button("Refresh thread", systemImage: "arrow.clockwise") { Task { await store.refresh(fresh: true) } }
                            .disabled(!available)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(tokens.textSecondary)
                            .frame(width: MobileTokens.touch, height: MobileTokens.touch)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Thread options")
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .background(tokens.surface)
            .overlay(alignment: .bottom) { tokens.border.frame(height: 1) }
        }
        .sheet(isPresented: sheetShown) {
            if let snapshot = store.snapshot, let dialog = pendingDialog {
                ThreadDialogView(dialog: dialog, enabled: available && store.supports("answer")) { answer in
                    Task {
                        await store.answer(dialogID: dialog.id, sessionID: snapshot.piSessionID,
                                           generation: snapshot.generation, answer: answer)
                    }
                }
                .id(dialogKey(snapshot, dialog))
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

    /// Title (label/600) with the status line beneath: dot + pill text, no fill; "· N turns" once history is complete.
    private func header(_ agent: Agent, _ tokens: MobileTokens) -> some View {
        let snapshot = store.snapshot
        let pill = nativeAgentPill(running: snapshot?.running == true, awaitingAnswer: snapshot?.dialogs.isEmpty == false,
                                   error: store.loadError != nil)
        let (dot, text): (Color, Color) = switch pill {
        case .idle: (tokens.success, tokens.successText)
        case .running: (tokens.accent, tokens.accentText)
        case .needsApproval: (tokens.warning, tokens.warningText)
        case .error: (tokens.danger, tokens.dangerText)
        case .stopped: (tokens.textMuted, tokens.textSecondary)
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(agent.name).font(MobileTokens.title).foregroundStyle(tokens.text).lineLimit(1)
            HStack(spacing: 5) {
                if pill == .running {
                    MobileSpinner(color: tokens.accent, size: 9)
                } else {
                    Circle().fill(dot).frame(width: MobileTokens.statusSize, height: MobileTokens.statusSize)
                }
                Text(pill.label).font(MobileTokens.caption12).foregroundStyle(text)
                // The bridge reports no context size; the turn count is exact only once the whole history is loaded.
                if store.olderCursor == nil, snapshot != nil {
                    let turns = store.messages.count { $0.role == "user" }
                    Text("· \(turns) turn\(turns == 1 ? "" : "s")").font(MobileTokens.micro).foregroundStyle(tokens.textMuted)
                }
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.name), \(pill.label)")
    }

    private var composer: some View {
        let tokens = MobileTokens(scheme: scheme)
        let running = store.snapshot?.running == true
        let waiting = pendingDialog != nil
        let draftEmpty = store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = available && store.acceptsSend && !draftEmpty
        let showStop = (running || waiting) && draftEmpty
        let widgets = (store.snapshot?.widgets ?? []).filter { $0.kind != .unknown }
        let placeholder = waiting ? "Waiting for you…"
            : running ? "Queue a follow-up…"
            : store.delivery == .steer ? "Steer the agent…" : "Follow up…"
        return VStack(alignment: .leading, spacing: MobileTokens.spacing) {
            if !widgets.isEmpty {
                // Extension status lives with the composer, not in the transcript.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(widgets) { widget in
                        HStack(alignment: .firstTextBaseline, spacing: MobileTokens.spacing) {
                            Text((widget.title ?? "\(widget.namespace) · \(widget.key)").uppercased())
                                .font(MobileTokens.section).tracking(0.5).foregroundStyle(tokens.textTertiary)
                            Text(widget.text).font(MobileTokens.micro).foregroundStyle(tokens.textSecondary)
                                .lineLimit(widget.kind == .status ? 1 : 4)
                        }
                        .textSelection(.enabled)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 4)
            }
            if let notice = store.notice {
                Text(notice)
                    .font(MobileTokens.micro)
                    .foregroundStyle(tokens.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack(alignment: .bottom, spacing: 10) {
                if waiting {
                    Button { dismissedDialog = nil } label: {
                        Text("Waiting for you")
                            .font(MobileTokens.caption12)
                            .foregroundStyle(tokens.warningText)
                            .lineLimit(1)
                            .frame(minHeight: MobileTokens.touch)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Waiting for you, show question")
                }
                HStack(alignment: .bottom, spacing: 6) {
                    TextField(placeholder, text: $store.draft, axis: .vertical)
                        .lineLimit(1...5)
                        .font(MobileTokens.bubble)
                        .textInputAutocapitalization(.sentences)
                        .focused($composing)
                        .padding(.leading, 16)
                        .padding(.vertical, 12)
                        .accessibilityLabel("Message to agent")
                    if showStop {
                        Button { Task { await store.abort() } } label: {
                            Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(tokens.onButtonPrimary)
                                .frame(width: 32, height: 32)
                                .background(tokens.danger, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: MobileTokens.touch, height: MobileTokens.touch)
                        .disabled(!available || !store.supports("abort"))
                        .accessibilityLabel("Stop agent")
                    } else {
                        Button { Task { await store.send() } } label: {
                            Image(systemName: store.busy ? "ellipsis" : "arrow.up").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(canSend && !store.busy ? tokens.onButtonPrimary : tokens.textDisabled)
                                .frame(width: 32, height: 32)
                                .background(canSend && !store.busy ? tokens.buttonPrimary : tokens.track, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: MobileTokens.touch, height: MobileTokens.touch)
                        .disabled(!canSend || store.busy)
                        .accessibilityLabel("Send message")
                    }
                }
                .frame(minHeight: MobileTokens.touch)
                .background(tokens.raised, in: RoundedRectangle(cornerRadius: MobileTokens.pillRadius))
                .overlay(RoundedRectangle(cornerRadius: MobileTokens.pillRadius)
                    .strokeBorder(composing ? tokens.accent : tokens.borderStrong, lineWidth: 1))
            }
        }
        .padding(.horizontal, MobileTokens.inset)
        .padding(.top, MobileTokens.spacing)
        // The system bottom safe area (home indicator) supplies ~30pt; 8 more keeps the pill off it.
        .padding(.bottom, MobileTokens.spacing)
        .background(alignment: .top) {
            LinearGradient(colors: [tokens.surface.opacity(0), tokens.surface], startPoint: .top, endPoint: .bottom)
                .frame(height: 24).offset(y: -24)
        }
        .background(tokens.surface)
    }
}

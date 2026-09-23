import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// The composer (spec §3, §6, §11): pinned under the thread in the same 760pt column, a fade
/// above it, the raised card with the field (or a pending question) and one action row:
/// attach · / commands · model · thinking · Send or Stop. Menus open above the card.
struct Composer: View {
    @Bindable var store: NativeThreadStore
    let active: Bool
    let agentName: String?
    let hasTurns: Bool
    let gutter: CGFloat
    var composing: FocusState<Bool>.Binding
    var listModels: (() async -> [PiModelCatalog.Entry])?
    /// Bumped by the model-picker shortcut: open the model picker.
    var modelPickerRequest = 0
    @State private var attachments: [ImageAttachment] = []
    @State private var attachmentError: String?
    @State private var dropTargeted = false
    @State private var commandIndex = 0
    /// Esc closes the slash menu for the draft as typed; typing more reopens it.
    @State private var dismissedQuery: String?
    @State private var menu: Menu?
    @State private var models: [PiModelCatalog.Entry] = []
    @State private var confirmingStopAll = false

    private enum Menu: Equatable { case models }

    // One effective state, shared with the header pill: a lost connection wins over a cached
    // running snapshot (error maps to Send + an inline error, never Stop).
    private var errored: Bool { store.loadError != nil }
    private var running: Bool { !errored && store.settledRunning }
    private var dialogs: [NativeThreadDialog] { errored ? [] : (store.snapshot?.dialogs ?? []) }
    private var canSend: Bool {
        active && store.supports("send") && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canAttach: Bool { store.snapshot?.supportedActions.contains("sendImages") == true }
    /// pi answers `/name` prompts itself; the list comes from its command registry.
    private var commands: [NativeCommand] { store.snapshot?.commands ?? [] }
    private var commandQuery: String? {
        guard !commands.isEmpty, store.draft.hasPrefix("/"), !store.draft.contains(where: \.isWhitespace),
              store.draft != dismissedQuery else { return nil }
        return String(store.draft.dropFirst()).lowercased()
    }
    private var commandMatches: [NativeCommand] {
        guard let query = commandQuery else { return [] }
        guard !query.isEmpty else { return commands }
        let prefix = commands.filter { $0.name.lowercased().hasPrefix(query) }
        let rest = commands.filter { !$0.name.lowercased().hasPrefix(query) }
            .filter { $0.name.lowercased().contains(query) || ($0.description ?? "").lowercased().contains(query) }
        return prefix + rest
    }
    private var menuOpen: Bool { commandQuery != nil || menu != nil }

    var body: some View {
        let widgets = (store.snapshot?.widgets ?? []).filter { $0.kind != .unknown }
        VStack(alignment: .leading, spacing: 8) {
            if !widgets.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(widgets) { WidgetRow(widget: $0) }
                }
                .padding(.horizontal, 4)
            }
            if let error = store.loadError {
                NWBanner(.failed, title: "Lost connection to the agent process.", message: error) {
                    Button("Reconnect") { Task { await store.refresh(fresh: true) } }
                        .buttonStyle(.nw(.secondary, size: .s))
                }
            } else if let attachmentError {
                NWBanner(.failed, title: attachmentError)
            } else if let notice = store.notice {
                Text(notice).font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary).textSelection(.enabled).padding(.horizontal, 4)
            }
            if commandQuery != nil {
                SlashMenu(matches: commandMatches, total: commands.count, query: commandQuery ?? "", selected: $commandIndex) { choose($0) }
            }
            if menu == .models {
                ModelPicker(current: store.snapshot?.model, models: models, agentName: agentName) { model in
                    menu = nil
                    composing.wrappedValue = true
                    RecentModels.record(model, thread: agentName)
                    Task { await store.setModel(model) }
                } close: { menu = nil; composing.wrappedValue = true }
            }
            card
        }
        .frame(maxWidth: AppLayout.threadMaxWidth)
        .padding(.horizontal, gutter)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            // The thread fades under the composer.
            LinearGradient(colors: [Color.nw.bgWindow.opacity(0), Color.nw.bgWindow], startPoint: .top, endPoint: .bottom)
                .frame(height: 48).offset(y: -48).allowsHitTesting(false)
        }
        .background(Color.nw.bgWindow)
        .onChange(of: commandQuery) { _, _ in commandIndex = 0 }
        // The catalog decides whether the thinking chip applies; it is cached per process.
        .task { if models.isEmpty { await loadModels() } }
        .onChange(of: modelPickerRequest) { _, _ in openModels() }
        .confirmationDialog("Stop the agent and every running subagent?", isPresented: $confirmingStopAll) {
            Button("Stop All", role: .destructive) { Task { await store.abortAll() } }
            Button("Stop Only the Agent") { Task { await store.abort() } }
        } message: {
            Text("\(store.subagents.count { !$0.isTerminal }) subagents are still running.")
        }
    }

    // MARK: Card

    private var card: some View {
        let focused = composing.wrappedValue || dropTargeted || menuOpen
        return VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        NWAttachmentChip(attachment.name) { attachments.removeAll { $0.id == attachment.id } }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }
            if let dialog = dialogs.first, let snapshot = store.snapshot {
                // The card swaps its field for the question so it can never scroll out of view.
                QuestionPanel(dialog: dialog, count: dialogs.count, enabled: active && store.supports("answer")) { answer in
                    Task {
                        await store.answer(dialogID: dialog.id, sessionID: snapshot.piSessionID,
                                           generation: snapshot.generation, answer: answer)
                    }
                }
                .id(snapshot.generation + ":" + snapshot.piSessionID + ":" + dialog.id)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
            } else {
                field
            }
            actionRow
        }
        .nwCard(line: .nw.lineStrong)
        .nwFocusRing(focused, radius: NW.Radius.m)
        .onDrop(of: [.image, .fileURL], isTargeted: canAttach ? $dropTargeted : nil) { providers in
            guard canAttach else { return false }
            attach(providers)
            return true
        }
    }

    private var placeholder: String {
        if running { return "Queue a follow-up — sent when the turn ends" }
        if !hasTurns { return "Describe the task, or / for commands…" }
        return commands.isEmpty ? "Follow up…" : "Follow up, or / for commands…"
    }

    private var field: some View {
        TextField(placeholder, text: $store.draft, axis: .vertical)
            .lineLimit(1...AppLayout.composerMaxRows)
            .textFieldStyle(.plain)
            .font(Font.nw(.body))
            .lineSpacing(NWTextStyle.body.lineSpacing)
            .foregroundStyle(Color.nw.textPrimary)
            .autocorrectionDisabled()
            .focused(composing)
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) { store.draft += "\n"; return .handled }
                if commandQuery != nil {
                    if commandMatches.indices.contains(commandIndex) { choose(commandMatches[commandIndex]) }
                    return .handled
                }
                guard canSend, !store.busy else { return .handled }
                sendDraft()
                return .handled
            }
            .onKeyPress(.tab) {
                guard commandQuery != nil, commandMatches.indices.contains(commandIndex) else { return .ignored }
                complete(commandMatches[commandIndex])
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard commandQuery != nil else { return .ignored }
                commandIndex = max(0, commandIndex - 1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard commandQuery != nil else { return .ignored }
                commandIndex = min(max(0, commandMatches.count - 1), commandIndex + 1)
                return .handled
            }
            .onKeyPress(.escape) {
                guard commandQuery != nil else { return .ignored }
                dismissedQuery = store.draft
                return .handled
            }
            .onPasteCommand(of: [.image, .fileURL]) { providers in
                guard canAttach else { return }
                attach(providers)
            }
            .accessibilityLabel("Message")
    }

    private var actionRow: some View {
        HStack(spacing: 4) {
            if canAttach {
                Button { pickImages() } label: {
                    Image(systemName: "paperclip").font(.system(size: 14, weight: .regular)).foregroundStyle(Color.nw.textSecondary)
                        .frame(width: NW.Height.controlL, height: NW.Height.controlL).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(attachments.count >= NativeImage.maxPerSend)
                .help("Attach images (drop or paste also works), up to \(NativeImage.maxPerSend)")
                .accessibilityLabel("Attach file")
            }
            if !commands.isEmpty {
                Button {
                    store.draft = "/"
                    dismissedQuery = nil
                    composing.wrappedValue = true
                } label: {
                    HStack(spacing: 6) { Text("/").foregroundStyle(Color.nw.textTertiary); Text("commands") }.font(Font.nwMono(12))
                }
                .buttonStyle(NWComposerChipStyle(active: commandQuery != nil))
                .accessibilityLabel("Commands")
            }
            modelChip
            thinkingChip
            if running, !store.draft.isEmpty { deliveryChip }
            Spacer(minLength: 8)
            primary
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8))
    }

    @ViewBuilder private var primary: some View {
        if store.busy {
            ProgressView().progressViewStyle(.nwSpinner(size: 13, color: Color.nw.textTertiary))
                .frame(width: NW.Height.controlL, height: NW.Height.controlL)
                .accessibilityLabel("Waiting for pi")
        } else if running, dialogs.isEmpty, store.draft.isEmpty {
            NWComposerActionButton(.stop, enabled: active && store.supports("abort")) { stop() }
                .help(store.hasLiveSubagents ? "Stop the agent and its subagents" : "Stop the agent's turn")
        } else {
            NWComposerActionButton(.send, enabled: canSend && dialogs.isEmpty) { sendDraft() }
                .help(dialogs.isEmpty ? "Send (⏎)" : "Answer the question first")
        }
    }

    private func stop() {
        if store.subagents.count(where: { !$0.isTerminal }) > 1 { confirmingStopAll = true }
        else { Task { await store.abortAll() } }
    }

    // MARK: Chips

    @ViewBuilder private var modelChip: some View {
        if let model = store.snapshot?.model {
            let settable = store.snapshot?.supportedActions.contains("setModel") == true
            Button { openModels() } label: {
                HStack(spacing: 6) {
                    Text(nativeModelShortName(model)).font(Font.nwMono(12))
                    if settable { NWChipChevron() }
                }
            }
            .buttonStyle(NWComposerChipStyle(active: menu == .models))
            .disabled(!settable || !store.supports("setModel"))
            .help("Model: \(model)")
            .accessibilityLabel("Model \(model)")
        }
    }

    /// Off / Low / Medium / High, independent of the model; hidden when the model takes no
    /// thinking level.
    @ViewBuilder private var thinkingChip: some View {
        if let thinking = store.snapshot?.thinking, store.snapshot?.supportedActions.contains("setThinking") == true,
           reasoningAvailable {
            SwiftUI.Menu {
                ForEach(["off", "low", "medium", "high"], id: \.self) { level in
                    Button {
                        Task { await store.setThinking(level) }
                    } label: {
                        if level == thinking { Label(level.capitalized, systemImage: "checkmark") } else { Text(level.capitalized) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb").font(.system(size: 11)).foregroundStyle(Color.nw.textSecondary)
                    Text("Thinking")
                    Text(thinking.capitalized).foregroundStyle(Color.nw.textPrimary).fontWeight(.medium)
                    NWChipChevron()
                }
                .font(Font.nw(.caption))
                .foregroundStyle(Color.nw.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: NW.Height.controlL)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!store.supports("setThinking"))
            .accessibilityLabel("Thinking level: \(thinking)")
        }
    }

    /// Unknown models (a catalog that did not load) keep the chip.
    private var reasoningAvailable: Bool {
        guard let model = store.snapshot?.model, let entry = models.first(where: { $0.id == model }) else { return true }
        return entry.reasoning
    }

    private var deliveryChip: some View {
        SwiftUI.Menu {
            Picker("Delivery", selection: $store.delivery) {
                Text("Follow-up · after the turn ends").tag(NativeThreadDelivery.followUp)
                Text("Steer · after the current tools").tag(NativeThreadDelivery.steer)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(store.delivery == .steer ? "Steer" : "Follow-up")
                NWChipChevron()
            }
            .font(Font.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
            .padding(.horizontal, 10).frame(height: NW.Height.controlL).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Delivery")
    }

    // MARK: Actions

    private func openModels() {
        guard store.supports("setModel") else { NSSound.beep(); return }
        menu = menu == .models ? nil : .models
        guard menu == .models, models.isEmpty else { return }
        Task { await loadModels() }
    }

    private func loadModels() async {
        if let listModels { models = await listModels() }
        else { models = await Task.detached(priority: .utility) { PiModelCatalog.entries() }.value }
    }

    private func choose(_ command: NativeCommand) {
        store.draft = "/\(command.name)"
        dismissedQuery = nil
        composing.wrappedValue = true
        guard canSend else { return }
        sendDraft()
    }

    private func complete(_ command: NativeCommand) {
        store.draft = "/\(command.name) "
        dismissedQuery = nil
    }

    private func sendDraft() {
        let images = attachments.map(\.image)
        Task {
            let before = store.sentCount
            await store.send(images: images)
            if store.sentCount > before { attachments.removeAll() }
        }
    }

    /// Dropped or pasted images become attachments through the same resize rules as terminal
    /// drops (longest edge 2000px, JPEG stays JPEG, everything else PNG).
    private func attach(_ providers: [NSItemProvider]) {
        attachmentError = nil
        Task {
            let urls = await AppImageDrop.resolve(providers)
            attach(urls: urls)
        }
    }

    private func attach(urls: [URL]) {
        for url in urls {
            guard attachments.count < NativeImage.maxPerSend else {
                attachmentError = "At most \(NativeImage.maxPerSend) images per message."
                return
            }
            guard let attachment = ImageAttachment(url: url) else {
                attachmentError = "\(url.lastPathComponent) is not an image Shepherd can attach."
                continue
            }
            guard attachment.image.data.count <= NativeImage.maxBytes else {
                attachmentError = "\(url.lastPathComponent) is over \(NativeImage.maxBytes / 1024 / 1024) MiB after resizing."
                continue
            }
            attachments.append(attachment)
        }
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        attachmentError = nil
        Task {
            let urls = await AppImageDrop.resolve(panel.urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() })
            attach(urls: urls)
        }
    }
}

// MARK: Slash menu

/// SlashMenu (spec §11): pi's commands filtered by what follows "/", above the card. Row 36pt:
/// the command in mono with the typed prefix bold, its description, a source tag, ⏎ on the
/// highlighted row. ↑↓ ⏎ ⇥ esc are handled by the field, which keeps focus.
struct SlashMenu: View {
    let matches: [NativeCommand]
    let total: Int
    let query: String
    @Binding var selected: Int
    let choose: (NativeCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Commands").nwSectionLabel()
                Text("· \(matches.count) of \(total)").font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.name) { index, command in
                            row(command, highlighted: index == selected)
                                .onHover { if $0 { selected = index } }
                                .onTapGesture { choose(command) }
                                .id(index)
                        }
                        if matches.isEmpty {
                            Text("No command matches “/\(query)”").font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                                .padding(.horizontal, 14).frame(height: AppLayout.menuRowHeight)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .frame(height: min(CGFloat(max(matches.count, 1)), CGFloat(AppLayout.menuMaxRows)) * AppLayout.menuRowHeight + 6)
                .onChange(of: selected) { _, index in proxy.scrollTo(index) }
            }
        }
        .nwPopover()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }

    private func row(_ command: NativeCommand, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            commandText(command.name)
                .frame(width: 150, alignment: .leading)
            Text(command.description ?? "").font(Font.nw(.caption)).foregroundStyle(Color.nw.textSecondary).lineLimit(1)
            Spacer(minLength: 8)
            if let source = command.source, source != "extension" { NWTag(source) }
            if highlighted {
                Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.nw.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: AppLayout.menuRowHeight)
        .nwRowBackground(selected: highlighted, hovering: false, selectedFill: Color.nw.runningTint)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("/\(command.name), \(command.description ?? "")")
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    }

    private func commandText(_ name: String) -> Text {
        let typed = name.lowercased().hasPrefix(query) ? query.count : 0
        let head = String(name.prefix(typed)), tail = String(name.dropFirst(typed))
        let slash = Text("/").foregroundStyle(Color.nw.textTertiary)
        let typedPart = Text(head).fontWeight(.bold).foregroundStyle(Color.nw.textPrimary)
        return Text("\(slash)\(typedPart)\(Text(tail).foregroundStyle(Color.nw.textPrimary))")
            .font(Font.nw(.mono))
    }
}

// MARK: Model picker

/// ModelPicker (spec §11): 380pt, search on top, Recent then one group per provider; row 40pt:
/// a check for the current model, the id in mono with a note, the context size.
struct ModelPicker: View {
    let current: String?
    let models: [PiModelCatalog.Entry]
    let agentName: String?
    let choose: (String) -> Void
    let close: () -> Void
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var searching: Bool

    private var filtered: [PiModelCatalog.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? models : models.filter { $0.id.lowercased().contains(q) }
    }

    private var groups: [(title: String, rows: [(entry: PiModelCatalog.Entry, note: String?)])] {
        let entries = filtered
        let recent = RecentModels.load()
        let recentRows = recent.compactMap { item -> (PiModelCatalog.Entry, String?)? in
            let entry = entries.first { $0.id == item.id } ?? (query.isEmpty ? PiModelCatalog.Entry(id: item.id, context: nil) : nil)
            guard let entry else { return nil }
            let note = item.id == current ? "Current · this thread" : item.note
            return (entry, note)
        }
        var result: [(String, [(entry: PiModelCatalog.Entry, note: String?)])] = []
        if !recentRows.isEmpty { result.append(("Recent", recentRows.map { (entry: $0.0, note: $0.1) })) }
        let recentIDs = Set(recent.map(\.id))
        var providers: [String] = []
        var byProvider: [String: [PiModelCatalog.Entry]] = [:]
        for entry in entries where !recentIDs.contains(entry.id) {
            if byProvider[entry.provider] == nil { providers.append(entry.provider) }
            byProvider[entry.provider, default: []].append(entry)
        }
        for provider in providers {
            result.append((provider, byProvider[provider]!.map { (entry: $0, note: $0.id == current ? "Current · this thread" : nil) }))
        }
        return result
    }

    var body: some View {
        let groups = groups
        let flat = groups.flatMap(\.rows)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color.nw.textTertiary)
                TextField("Search models", text: $query).textFieldStyle(.plain).font(Font.nw(.body)).focused($searching)
                    .onKeyPress(.downArrow) { selected = min(flat.count - 1, selected + 1); return .handled }
                    .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
                    .onKeyPress(.return) { if flat.indices.contains(selected) { choose(flat[selected].entry.id) }; return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                Text(KeybindingsStore.shared.display(.modelPicker)).font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .overlay(alignment: .bottom) { NWHairline() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if models.isEmpty {
                        HStack(spacing: 8) { ProgressView().progressViewStyle(.nwSpinner(size: 12)); Text("Loading models…").font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary) }
                            .padding(14)
                    }
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        Text(group.title).nwSectionLabel().padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                        ForEach(Array(group.rows.enumerated()), id: \.offset) { index, row in
                            let position = flatIndex(group: group.title, index: index, in: groups)
                            modelRow(row.entry, note: row.note, highlighted: position == selected)
                                .onHover { if $0 { selected = position } }
                                .onTapGesture { choose(row.entry.id) }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: AppLayout.modelPickerWidth)
        .fixedSize(horizontal: false, vertical: true)
        .nwPopover()
        .onAppear { searching = true }
        .onChange(of: query) { _, _ in selected = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose a model")
    }

    private func flatIndex(group: String, index: Int, in groups: [(title: String, rows: [(entry: PiModelCatalog.Entry, note: String?)])]) -> Int {
        var position = 0
        for candidate in groups {
            if candidate.title == group { return position + index }
            position += candidate.rows.count
        }
        return position
    }

    private func modelRow(_ entry: PiModelCatalog.Entry, note: String?, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.nw.running).opacity(entry.id == current ? 1 : 0).frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(nativeModelShortName(entry.id)).font(Font.nw(.mono)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
                if let note { Text(note).font(Font.nwSans(11)).foregroundStyle(Color.nw.textSecondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let context = entry.context { Text(context).font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary) }
        }
        .padding(.horizontal, 8)
        .frame(height: note == nil ? 32 : AppLayout.modelRowHeight)
        .nwRowBackground(selected: highlighted, hovering: false, selectedFill: Color.nw.runningTint)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.id + (entry.id == current ? ", current" : ""))
        .accessibilityAddTraits(.isButton)
    }
}

/// The last models picked in any thread, newest first (the model picker's Recent group).
enum RecentModels {
    struct Item: Codable, Equatable {
        var id: String
        var at: Date
        var thread: String?

        var note: String? {
            let age = Date().timeIntervalSince(at)
            let when = age < 3600 ? "\(max(1, Int(age / 60)))m ago" : age < 86_400 ? "\(Int(age / 3600))h ago" : "\(Int(age / 86_400))d ago"
            return thread.map { "Used \(when) in “\($0)”" } ?? "Used \(when)"
        }
    }

    static let key = "shepherd.recentModels"
    static let limit = 4

    static func load(_ defaults: UserDefaults = .standard) -> [Item] {
        guard let data = defaults.data(forKey: key), let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items
    }

    static func record(_ id: String, thread: String?, at date: Date = Date(), defaults: UserDefaults = .standard) {
        var items = load(defaults).filter { $0.id != id }
        items.insert(Item(id: id, at: date, thread: thread), at: 0)
        if let data = try? JSONEncoder().encode(Array(items.prefix(limit))) { defaults.set(data, forKey: key) }
    }
}

/// "provider/model" → "model".
func nativeModelShortName(_ model: String) -> String {
    guard let slash = model.firstIndex(of: "/") else { return model }
    return String(model[model.index(after: slash)...])
}

/// "42k" / "1.2M" for the header's context count.
func nativeTokenCount(_ tokens: Int) -> String {
    if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
    if tokens >= 1_000 { return "\(tokens / 1_000)k" }
    return "\(tokens)"
}

func nativeContextTooltip(_ stats: NativeThreadStats?) -> String {
    guard let stats else { return "" }
    var parts: [String] = []
    if let tokens = stats.contextTokens {
        var line = "\(tokens) context tokens"
        if let window = stats.contextWindow { line += " of \(nativeTokenCount(window))" }
        if let percent = stats.contextPercent { line += " (\(Int(percent.rounded()))%)" }
        parts.append(line)
    }
    if let total = stats.totalTokens { parts.append("\(nativeTokenCount(total)) tokens this session") }
    if let cost = stats.cost { parts.append(String(format: "$%.2f", cost)) }
    return parts.joined(separator: " · ")
}

// MARK: Questions

/// A question from pi or an extension (select / confirm / input / editor), in place of the
/// field so it can never scroll away. Shepherd has no permission model: these are questions,
/// answered with the values the asker offered.
struct QuestionPanel: View {
    let dialog: NativeThreadDialog
    /// Pending questions in total; the panel shows the first as "1 / N".
    var count = 1
    let enabled: Bool
    let answer: (NativeDialogAnswer) -> Void
    @State private var text: String

    init(dialog: NativeThreadDialog, count: Int = 1, enabled: Bool, answer: @escaping (NativeDialogAnswer) -> Void) {
        self.dialog = dialog
        self.count = count
        self.enabled = enabled
        self.answer = answer
        _text = State(initialValue: dialog.prefill ?? "")
    }

    var body: some View {
        let blocked = !enabled || dialog.unavailable != nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                NWStateGlyph(.attention, size: 13)
                Text(dialog.title).font(Font.nw(.ui)).foregroundStyle(Color.nw.textPrimary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if count > 1 { Text("1 / \(count)").font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary).monospacedDigit() }
            }
            if let message = dialog.message {
                ScrollView {
                    Text(message).font(Font.nw(.mono)).foregroundStyle(Color.nw.textPrimary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                .overlay { RoundedRectangle(cornerRadius: NW.Radius.m).strokeBorder(Color.nw.lineSubtle, lineWidth: 1) }
            }
            if let unavailable = dialog.unavailable {
                Text(unavailable == "external-editor" ? "An external editor is open · finish it before answering here" : "This question is too large to show here")
                    .font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
            Group {
                switch dialog.kind {
                case .confirm:
                    HStack(spacing: 8) {
                        Button("Yes") { answer(.confirm(value: true)) }.buttonStyle(NWButtonStyle(.primary, size: .m))
                        Button("No") { answer(.confirm(value: false)) }.buttonStyle(NWButtonStyle(.secondary))
                        Spacer(minLength: 0)
                        Button("Dismiss") { answer(.cancel) }.buttonStyle(NWButtonStyle(.ghost, size: .s))
                    }
                    // Y/N answer only while the panel itself has focus, so typing in the composer
                    // can never answer by accident.
                    .focusable()
                    .onKeyPress(characters: .init(charactersIn: "yYnN")) { press in
                        guard !blocked else { return .ignored }
                        answer(.confirm(value: press.characters.lowercased() == "y"))
                        return .handled
                    }
                case .select:
                    FlowLayout(spacing: 6) {
                        ForEach(Array((dialog.options ?? []).enumerated()), id: \.offset) { index, option in
                            Button(option) { answer(.select(value: option)) }
                                .buttonStyle(NWButtonStyle(index == 0 ? .primary : .secondary))
                                .accessibilityLabel("Choose \(option)")
                        }
                        Button("Dismiss") { answer(.cancel) }.buttonStyle(NWButtonStyle(.ghost))
                    }
                case .input, .editor:
                    TextField(dialog.placeholder ?? "Answer", text: $text, axis: .vertical)
                        .lineLimit(dialog.kind == .editor ? 5...12 : 1...5)
                        .nwField(mono: dialog.kind == .editor)
                        .autocorrectionDisabled()
                        .accessibilityLabel(dialog.kind == .editor ? "Editor answer" : "Answer")
                    HStack(spacing: 8) {
                        Button("Submit") { answer(dialog.kind == .editor ? .editor(value: text) : .input(value: text)) }
                            .buttonStyle(NWButtonStyle(.primary))
                        Button("Dismiss") { answer(.cancel) }.buttonStyle(NWButtonStyle(.ghost))
                    }
                }
            }
            .disabled(blocked)
            if dialog.timeout != nil {
                Text("pi may stop waiting for this answer").font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question: \(dialog.title)")
    }
}

// MARK: Accessories

/// An extension's status or text widget, above the composer.
struct WidgetRow: View {
    let widget: NativeThreadWidget

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(widget.title ?? "\(widget.namespace) · \(widget.key)").nwSectionLabel()
            Text(widget.text).font(Font.nw(.micro)).foregroundStyle(Color.nw.textSecondary)
                .lineLimit(widget.kind == .status ? 1 : 4)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

/// A resized image waiting in the composer. `image.data` is the bytes pi will receive.
struct ImageAttachment: Identifiable {
    let id = UUID()
    let name: String
    let image: NativeImage

    /// nil when the file is not a raster image.
    init?(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image),
              let data = try? Data(contentsOf: url), NSBitmapImageRep(data: data) != nil else { return nil }
        name = url.lastPathComponent
        image = NativeImage(mimeType: type == .jpeg ? "image/jpeg" : type == .gif ? "image/gif" : type == .webP ? "image/webp" : "image/png", data: data)
    }
}

/// Left-to-right wrapping row (answer buttons, a result's file links).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, place(in: bounds.width, subviews: subviews).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func place(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + 6; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

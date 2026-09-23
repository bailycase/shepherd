import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// The composer (NWComposer board): pinned under the thread in the same 820pt column, a fade
/// above it, the `NWComposer` card with the field (or a pending question) and one row of
/// controls: attach · / commands · model · thinking · Send or Stop. Menus open above the card.
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
    @State private var picking = false

    private enum Menu: Equatable { case models, thinking }

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
        let query = commandQuery
        VStack(alignment: .leading, spacing: AppLayout.menuGap) {
            if !widgets.isEmpty {
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    ForEach(widgets) { WidgetRow(widget: $0) }
                }
                .padding(.horizontal, NW.Space.xs)
            }
            if let error = store.loadError {
                NWBanner(.failed, title: "Lost connection to the agent process.", message: error) {
                    Button("Reconnect") { Task { await store.refresh(fresh: true) } }
                        .buttonStyle(.nw(.secondary, size: .s))
                }
            } else if let attachmentError {
                NWBanner(.failed, title: attachmentError)
            } else if let notice = store.notice {
                Text(notice).font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary).textSelection(.enabled)
                    .padding(.horizontal, NW.Space.xs)
            }
            if let query {
                let matches = commandMatches
                NWSlashMenu(commands: matches.map(Self.slashCommand), total: commands.count, query: query,
                            selection: $commandIndex) { command in
                    if let match = matches.first(where: { $0.name == command.name }) { choose(match) }
                }
            }
            if menu == .models {
                ModelPicker(current: store.snapshot?.model, models: models) { model in
                    menu = nil
                    composing.wrappedValue = true
                    RecentModels.record(model, thread: agentName)
                    Task { await store.setModel(model) }
                } close: { menu = nil; composing.wrappedValue = true }
            }
            if menu == .thinking, let thinking = store.snapshot?.thinking {
                NWThinkingMenu(options: Self.thinkingLevels, current: thinking) { level in
                    menu = nil
                    composing.wrappedValue = true
                    Task { await store.setThinking(level.id) }
                } onClose: { menu = nil; composing.wrappedValue = true }
            }
            card
        }
        .frame(maxWidth: AppLayout.threadMaxWidth)
        .padding(.horizontal, gutter)
        .padding(.bottom, AppLayout.composerBottom)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            // The thread fades under the composer.
            LinearGradient(colors: [Color.nw.bgWindow.opacity(0), Color.nw.bgWindow], startPoint: .top, endPoint: .bottom)
                .frame(height: AppLayout.composerFade).offset(y: -AppLayout.composerFade).allowsHitTesting(false)
        }
        .background(Color.nw.bgWindow)
        .onChange(of: query) { _, _ in commandIndex = 0 }
        // The catalog decides whether the thinking chip applies; it is cached per process.
        .task { if models.isEmpty { await loadModels() } }
        .onChange(of: modelPickerRequest) { _, _ in openModels() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            attachmentError = nil
            Task {
                let resolved = await AppImageDrop.resolve(urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() })
                attach(urls: resolved)
            }
        }
        .sheet(isPresented: $confirmingStopAll) {
            StopAllDialog(runningSubagents: store.subagents.count { !$0.isTerminal },
                          stopAgent: { confirmingStopAll = false; Task { await store.abort() } },
                          stopAll: { confirmingStopAll = false; Task { await store.abortAll() } },
                          cancel: { confirmingStopAll = false })
        }
    }

    private static func slashCommand(_ command: NativeCommand) -> NWSlashCommand {
        NWSlashCommand(name: command.name, description: command.description,
                       tag: command.source.flatMap { $0 == "extension" ? nil : $0 })
    }

    /// Off / Low / Medium / High, with the board's notes.
    private static let thinkingLevels = [
        NWThinkingOption(id: "off", title: "Off"),
        NWThinkingOption(id: "low", title: "Low", note: "quick"),
        NWThinkingOption(id: "medium", title: "Medium", note: "default"),
        NWThinkingOption(id: "high", title: "High", note: "slower, deeper"),
    ]

    // MARK: Card

    private var card: some View {
        let focused = composing.wrappedValue || dropTargeted || menuOpen
        return NWComposer(isFocused: focused) {
            ForEach(attachments) { attachment in
                NWAttachmentChip(attachment.name, thumbnail: attachment.thumbnail) {
                    attachments.removeAll { $0.id == attachment.id }
                }
            }
        } field: {
            if let dialog = dialogs.first, let snapshot = store.snapshot {
                // The card swaps its field for the question so it can never scroll out of view.
                QuestionPanel(dialog: dialog, count: dialogs.count, enabled: active && store.supports("answer")) { answer in
                    Task {
                        await store.answer(dialogID: dialog.id, sessionID: snapshot.piSessionID,
                                           generation: snapshot.generation, answer: answer)
                    }
                }
                .id(snapshot.generation + ":" + snapshot.piSessionID + ":" + dialog.id)
            } else {
                field
            }
        } controls: {
            actionRow
        }
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
        TextField(text: $store.draft, prompt: Text(placeholder).foregroundStyle(Color.nw.textTertiary), axis: .vertical) {
            Text("Message the agent")
        }
            .lineLimit(1...NWComposerMetrics.fieldMaxLines)
            .textFieldStyle(.plain)
            .font(Font.nw(.body))
            .lineSpacing(max(0, NWTextStyle.body.lineSpacing - 1))
            .foregroundStyle(Color.nw.textPrimary)
            .autocorrectionDisabled()
            .focused(composing)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) { store.draft += "\n"; return .handled }
                if commandQuery != nil {
                    let matches = commandMatches
                    if matches.indices.contains(commandIndex) { choose(matches[commandIndex]) }
                    return .handled
                }
                guard canSend, !store.busy else { return .handled }
                sendDraft()
                return .handled
            }
            .onKeyPress(.tab) {
                let matches = commandMatches
                guard commandQuery != nil, matches.indices.contains(commandIndex) else { return .ignored }
                complete(matches[commandIndex])
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
                if menu != nil { menu = nil; return .handled }
                guard commandQuery != nil else { return .ignored }
                dismissedQuery = store.draft
                return .handled
            }
            .onPasteCommand(of: [.image, .fileURL]) { providers in
                guard canAttach else { return }
                attach(providers)
            }
            .accessibilityLabel("Message the agent")
    }

    /// Full chip labels when they fit; in a narrow thread (a docked right pane) the chips drop
    /// their words ("/", the thinking level alone) instead of truncating mid-word.
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            actionChips(compact: false)
            actionChips(compact: true)
        }
    }

    private func actionChips(compact: Bool) -> some View {
        HStack(spacing: NW.Space.xxs) {
            if canAttach {
                Button { picking = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.nwIcon(size: NWComposerMetrics.chipHeight))
                    .disabled(attachments.count >= NativeImage.maxPerSend)
                    .help("Attach images (drop or paste also works), up to \(NativeImage.maxPerSend)")
                    .accessibilityLabel("Attach file")
            }
            if !commands.isEmpty {
                Button {
                    store.draft = "/"
                    dismissedQuery = nil
                    menu = nil
                    composing.wrappedValue = true
                } label: {
                    HStack(spacing: NW.Space.s) {
                        Text("/").font(Font.nw(.code))
                        if !compact { Text("commands") }
                    }
                }
                .buttonStyle(.nwComposerChip(active: commandQuery != nil))
                .help("Commands")
                .accessibilityLabel("Commands")
            }
            modelChip
            thinkingChip(compact: compact)
            if running, !store.draft.isEmpty { deliveryChip }
            Spacer(minLength: NW.Space.m)
            primary
        }
    }

    @ViewBuilder private var primary: some View {
        if store.busy {
            ProgressView().progressViewStyle(.nwSpinner(color: Color.nw.textTertiary))
                .frame(width: NWComposerMetrics.actionSize, height: NWComposerMetrics.actionSize)
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
                HStack(spacing: NW.Space.s) {
                    Text(nativeModelShortName(model)).font(Font.nw(.code))
                    if settable { NWChipChevron() }
                }
            }
            .buttonStyle(.nwComposerChip(active: menu == .models))
            .disabled(!settable || !store.supports("setModel"))
            .help("Model: \(model)")
            .accessibilityLabel("Model \(model)")
        }
    }

    /// Off / Low / Medium / High, independent of the model; hidden when the model takes no
    /// thinking level.
    @ViewBuilder private func thinkingChip(compact: Bool) -> some View {
        if let thinking = store.snapshot?.thinking, store.snapshot?.supportedActions.contains("setThinking") == true,
           reasoningAvailable {
            Button {
                menu = menu == .thinking ? nil : .thinking
            } label: {
                HStack(spacing: NW.Space.s) {
                    Image(systemName: "lightbulb").font(.system(size: AppLayout.chipSymbol, weight: .medium)).foregroundStyle(Color.nw.textSecondary)
                    if !compact { Text("Thinking") }
                    Text(thinking.capitalized).foregroundStyle(Color.nw.textPrimary).fontWeight(.medium)
                    NWChipChevron()
                }
            }
            .buttonStyle(.nwComposerChip(active: menu == .thinking))
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
            HStack(spacing: NW.Space.s) {
                Text(store.delivery == .steer ? "Steer" : "Follow-up")
                NWChipChevron()
            }
            .font(Font.nwSans(12)).foregroundStyle(Color.nw.textSecondary)
            .padding(.horizontal, NW.Space.m).frame(height: NWComposerMetrics.chipHeight).contentShape(Rectangle())
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
}

// MARK: Model picker

/// The model picker over `NWModelPicker`: Recent (up to 4), then one section per provider.
/// Recent models are read once when the picker opens.
struct ModelPicker: View {
    let current: String?
    let models: [PiModelCatalog.Entry]
    let choose: (String) -> Void
    let close: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @State private var recent: [RecentModels.Item] = []

    var body: some View {
        NWModelPicker(query: $query, sections: sections, loading: models.isEmpty, selection: $selection,
                      onChoose: { choose($0.id) }, onClose: close)
            .onAppear { recent = RecentModels.load() }
    }

    private var sections: [NWModelSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let entries = q.isEmpty ? models : models.filter { $0.id.lowercased().contains(q) }
        func option(_ entry: PiModelCatalog.Entry) -> NWModelOption {
            NWModelOption(id: entry.id, title: nativeModelShortName(entry.id), note: entry.context, isCurrent: entry.id == current)
        }
        var result: [NWModelSection] = []
        let recentOptions = recent.compactMap { item -> NWModelOption? in
            if let entry = entries.first(where: { $0.id == item.id }) { return option(entry) }
            return q.isEmpty ? NWModelOption(id: item.id, title: nativeModelShortName(item.id), isCurrent: item.id == current) : nil
        }
        if !recentOptions.isEmpty { result.append(NWModelSection(title: "Recent", options: recentOptions)) }
        let recentIDs = Set(recent.map(\.id))
        var providers: [String] = []
        var byProvider: [String: [NWModelOption]] = [:]
        for entry in entries where !recentIDs.contains(entry.id) {
            if byProvider[entry.provider] == nil { providers.append(entry.provider) }
            byProvider[entry.provider, default: []].append(option(entry))
        }
        for provider in providers { result.append(NWModelSection(title: provider, options: byProvider[provider] ?? [])) }
        return result
    }
}

/// The last models picked in any thread, newest first (the model picker's Recent group).
enum RecentModels {
    struct Item: Codable, Equatable {
        var id: String
        var at: Date
        var thread: String?
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
        var line = "\(tokens.formatted()) context tokens"
        if let window = stats.contextWindow { line += " of \(nativeTokenCount(window))" }
        if let percent = stats.contextPercent { line += " (\(Int(percent.rounded()))%)" }
        parts.append(line)
    }
    if let total = stats.totalTokens { parts.append("\(nativeTokenCount(total)) tokens this session") }
    if let cost = stats.cost { parts.append(cost.formatted(.currency(code: "USD"))) }
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
        VStack(alignment: .leading, spacing: AppLayout.questionSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                NWStateGlyph(.attention, size: AppLayout.questionGlyph)
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
                .frame(maxHeight: AppLayout.questionMessageMaxHeight)
                .padding(.horizontal, NW.Space.l).padding(.vertical, NW.Space.m)
                .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
            }
            if let unavailable = dialog.unavailable {
                Text(unavailable == "external-editor" ? "An external editor is open · finish it before answering here" : "This question is too large to show here")
                    .font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
            Group {
                switch dialog.kind {
                case .confirm:
                    HStack(spacing: NW.Space.m) {
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
                    FlowLayout(spacing: NW.Space.s) {
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
                    HStack(spacing: NW.Space.m) {
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
        .padding(.top, NW.Space.xxs)
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
        HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
            Text(widget.title ?? "\(widget.namespace) · \(widget.key)").nwSectionLabel()
            Text(widget.text).font(Font.nw(.micro)).foregroundStyle(Color.nw.textSecondary)
                .lineLimit(widget.kind == .status ? 1 : 4)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

/// A resized image waiting in the composer. `image.data` is the bytes pi will receive; the
/// thumbnail is decoded once, here.
struct ImageAttachment: Identifiable {
    let id = UUID()
    let name: String
    let image: NativeImage
    let thumbnail: Image?

    /// nil when the file is not a raster image.
    init?(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image),
              let data = try? Data(contentsOf: url), NSBitmapImageRep(data: data) != nil else { return nil }
        name = url.lastPathComponent
        image = NativeImage(mimeType: type == .jpeg ? "image/jpeg" : type == .gif ? "image/gif" : type == .webP ? "image/webp" : "image/png", data: data)
        thumbnail = NSImage(data: data).map { Image(nsImage: $0) }
    }
}

/// Left-to-right wrapping row (answer buttons, a result's file links). `lineSpacing` separates
/// wrapped rows (the item spacing unless given); items wider than the row are offered its width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = place(in: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let origin = placement.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          proposal: ProposedViewSize(placement.sizes[index]))
        }
    }

    private func place(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width { x = 0; y += rowHeight + (lineSpacing ?? spacing); rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins, sizes)
    }
}

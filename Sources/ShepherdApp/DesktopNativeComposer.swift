import SwiftUI
import UniformTypeIdentifiers
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

// The floating composer for the native thread (spec §3, §6; layout after t3code/bb):
// status line · optional command menu · card (attachments · field or approval panel · chip row).

struct NativeComposer: View {
    @ObservedObject var store: NativeThreadStore
    @ObservedObject var clock: NativeThreadClock
    let active: Bool
    let agentName: String?
    let hasTurns: Bool
    let gutter: CGFloat
    /// nil for RPC agents: there is no terminal to show, so every handoff link is hidden.
    let showTerminal: (() -> Void)?
    var composing: FocusState<Bool>.Binding
    /// RPC agents: images attached to the next send (already resized per TerminalImageDrop).
    @State private var attachments: [NativeAttachment] = []
    @State private var attachmentError: String?
    @State private var dropTargeted = false
    @State private var commandIndex = 0
    /// Esc closes the menu for the draft as typed; typing more reopens it.
    @State private var dismissedQuery: String?

    private var isRPC: Bool { store.snapshot?.isRPC == true }
    // One effective state, shared with the header pill: a lost connection wins over a
    // cached running snapshot (spec §6 maps error to Send + InlineError, never Stop).
    private var errored: Bool { store.loadError != nil }
    private var running: Bool { !errored && store.settledRunning }
    private var dialogs: [NativeThreadDialog] { errored ? [] : (store.snapshot?.dialogs ?? []) }
    private var canSend: Bool {
        active && store.supports("send") && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canAttach: Bool {
        store.supports("sendImages") || store.snapshot?.supportedActions.contains("sendImages") == true
    }
    /// pi answers `/name` prompts itself under RPC; the list comes from get_commands. A
    /// terminal agent has none, so "/" is just a character there.
    private var commands: [NativeCommand] { isRPC ? (store.snapshot?.commands ?? []) : [] }
    /// "/" at line start: the draft is one token starting with a slash.
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

    var body: some View {
        let widgets = (store.snapshot?.widgets ?? []).filter { $0.kind != .unknown }
        let waiting = !dialogs.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            if !widgets.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(widgets) { NativeWidgetRow(widget: $0) }
                }
            }
            if let error = store.loadError {
                NativeInlineError(text: "Lost connection to the agent process · \(error)",
                                  reconnect: { Task { await store.refresh(fresh: true) } }, showTerminal: showTerminal)
            } else if let attachmentError {
                Text(attachmentError).font(NativeFonts.caption).foregroundStyle(NativeTokens.dangerText).textSelection(.enabled)
            } else if let notice = store.notice {
                Text(notice).font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted).textSelection(.enabled)
            }
            // Running state lives in the thread's shimmering working row; only a pending
            // question earns a line here, since the card itself becomes the answer form.
            if waiting { statusLine(waiting: waiting) }
            if commandQuery != nil {
                NativeCommandMenu(matches: commandMatches, selected: $commandIndex) { choose($0) }
            }
            card(waiting: waiting)
        }
        .frame(maxWidth: NativeMetrics.threadMaxWidth)
        .padding(.horizontal, gutter)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            LinearGradient(colors: [NativeTokens.bgSurface.opacity(0), NativeTokens.bgSurface], startPoint: .top, endPoint: .bottom)
                .frame(height: 40).offset(y: -40)
        }
        .background(NativeTokens.bgSurface)
        .onChange(of: commandQuery) { _, _ in commandIndex = 0 }
    }

    /// 22pt line above the card: "Waiting for you · 4s".
    private func statusLine(waiting: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(NativeTokens.warning).frame(width: 6, height: 6)
            Text("Waiting for you · \(clock.waitingElapsed(now: clock.now))")
        }
        .font(NativeFonts.caption)
        .foregroundStyle(NativeTokens.textMuted)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.leading, 4)
        .frame(height: NativeMetrics.statusLineHeight)
        .accessibilityElement(children: .combine)
    }

    private func card(waiting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                NativeAttachmentRow(attachments: attachments) { id in attachments.removeAll { $0.id == id } }
            }
            if let dialog = dialogs.first, let snapshot = store.snapshot {
                // The card swaps its field for the question so it can never scroll out of view.
                NativeApprovalCard(dialog: dialog, count: dialogs.count, enabled: active && store.supports("answer"),
                                   showTerminal: showTerminal) { answer in
                    Task {
                        await store.answer(dialogID: dialog.id, sessionID: snapshot.piSessionID,
                                           generation: snapshot.generation, answer: answer)
                    }
                }
                .id(snapshot.generation + ":" + snapshot.piSessionID + ":" + dialog.id)
            } else {
                field
            }
            HStack(spacing: 8) {
                if canAttach { attachButton }
                modelChips
                if running { deliveryChip }
                Spacer(minLength: 0)
                primary(waiting: waiting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(NativeTokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.xl))
        .overlay(RoundedRectangle(cornerRadius: Radius.xl)
            .strokeBorder(composing.wrappedValue || dropTargeted ? NativeTokens.accent : NativeTokens.borderStrong, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: Radius.xl)
            .fill(NativeTokens.accent.opacity(composing.wrappedValue || dropTargeted ? 0.12 : 0)).padding(-3))
        .shadow(color: NativeTokens.composerShadow, radius: 3, y: 1)
        .onDrop(of: [.image, .fileURL], isTargeted: canAttach ? $dropTargeted : nil) { providers in
            guard canAttach else { return false }
            attach(providers)
            return true
        }
    }

    private var field: some View {
        let placeholder = hasTurns ? "Follow up…" : "Message \(agentName ?? "the agent")…"
        return TextField(placeholder, text: $store.draft, axis: .vertical)
            .lineLimit(1...8)
            .textFieldStyle(.plain)
            .font(NativeFonts.bodySmall)
            .lineSpacing(NativeFonts.bodySmallLeading)
            .autocorrectionDisabled()
            .focused(composing)
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
            .accessibilityLabel("Native message to agent")
            .help(isRPC ? "Enter sends. Type / for pi’s commands; drop or paste images to attach them."
                  : "Sent as literal text. Slash commands, images, and custom extension UI need Terminal.")
    }

    /// One 28pt circle: Send when idle or when a draft exists during a run, Stop while running
    /// with an empty draft, a spinner while pi is accepting an action.
    @ViewBuilder private func primary(waiting: Bool) -> some View {
        if store.busy {
            NativeSpinner(color: NativeTokens.textMuted, size: 12)
                .frame(width: NativeMetrics.iconButton, height: NativeMetrics.iconButton)
                .background(NativeTokens.bgTrack, in: Circle())
                .help("Waiting for pi to accept the action")
                .accessibilityLabel("Waiting for pi")
        } else if running, !waiting, store.draft.isEmpty {
            Button { Task { await store.abort() } } label: {
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .medium))
            }
            // Page 7: a semantic fill only ever carries its matching .text; never white on danger.
            .buttonStyle(NativeIconButtonStyle(fill: NativeTokens.dangerBg, label: NativeTokens.dangerText))
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!active || !store.supports("abort"))
            .help("Stop the agent’s current turn (⌘.)")
            .accessibilityLabel("Stop agent")
        } else {
            let enabled = canSend && !waiting
            Button { sendDraft() } label: {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(NativeIconButtonStyle(fill: enabled ? NativeTokens.text : NativeTokens.bgTrack,
                                               label: enabled ? NativeTokens.bgRaised : NativeTokens.textDisabled))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!enabled)
            .help(waiting ? "Answer the question first"
                  : running ? (store.delivery == .steer ? "Steer · delivered after the current tools" : "Follow-up · sent when the turn ends")
                  : "Send (⏎)")
            .accessibilityLabel("Send message")
            // ⌘. still stops the run while the circle shows Send.
            if running {
                Button("Stop agent") { Task { await store.abort() } }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!active || !store.supports("abort"))
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
        }
    }

    private var deliveryChip: some View {
        Menu {
            Picker("Delivery", selection: $store.delivery) {
                Text("Follow-up · after the agent finishes").tag(NativeThreadDelivery.followUp)
                Text("Steer · after the current tools").tag(NativeThreadDelivery.steer)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            NativeChip(text: store.delivery == .steer ? "steer" : "follow-up", menu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Delivery. Follow-up waits until the agent finishes; steer is delivered after the current tools.")
        .accessibilityLabel("Message delivery")
    }

    private var attachButton: some View {
        Button { pickImages() } label: {
            Image(systemName: "paperclip").font(.system(size: 11, weight: .medium)).foregroundStyle(NativeTokens.textSecondary)
                .frame(width: NativeMetrics.chipHeight, height: NativeMetrics.chipHeight)
                .background(NativeTokens.bgHover, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .disabled(attachments.count >= NativeImage.maxPerSend)
        .help("Attach images (drop or paste also works), up to \(NativeImage.maxPerSend)")
        .accessibilityLabel("Attach image")
    }

    /// Model and thinking chips. Menus only when the bridge supports setting them (RPC).
    @ViewBuilder private var modelChips: some View {
        let snapshot = store.snapshot
        if let model = snapshot?.model {
            if snapshot?.supportedActions.contains("setModel") == true {
                NativeModelMenu(current: model, disabled: !store.supports("setModel")) { choice in Task { await store.setModel(choice) } }
            } else {
                NativeChip(text: nativeModelShortName(model)).help("Model in use: \(model). Change it in Terminal.")
            }
        }
        if let thinking = snapshot?.thinking, snapshot?.supportedActions.contains("setThinking") == true {
            Menu {
                Picker("Thinking", selection: Binding(get: { thinking }, set: { level in Task { await store.setThinking(level) } })) {
                    ForEach(["off", "low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                NativeChip(text: "think \(thinking)", menu: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!store.supports("setThinking"))
            .help("Thinking level for the next turn")
            .accessibilityLabel("Thinking level")
        }
    }

    private func choose(_ command: NativeCommand) {
        store.draft = "/\(command.name) "
        dismissedQuery = nil
        composing.wrappedValue = true
    }

    private func sendDraft() {
        let images = attachments.map(\.image)
        Task {
            let before = store.sentCount
            await store.send(images: images)
            if store.sentCount > before { attachments.removeAll() }
        }
    }

    /// Dropped or pasted image providers become attachments through the same resize rules
    /// as terminal drops (longest edge 2000px, JPEG stays JPEG, everything else PNG).
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
            guard let attachment = NativeAttachment(url: url) else {
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
            // Same path as a drop so oversized files are shrunk into the drop directory.
            let urls = await AppImageDrop.resolve(panel.urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() })
            attach(urls: urls)
        }
    }
}

// MARK: Command menu

/// pi's slash commands filtered by what follows the "/" in the draft. Sits inline above the
/// card (t3 ComposerCommandMenu) so the field keeps focus; ↑/↓/⏎/Esc are handled by the field.
struct NativeCommandMenu: View {
    let matches: [NativeCommand]
    @Binding var selected: Int
    let choose: (NativeCommand) -> Void

    private static let rowHeight: CGFloat = 28

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.name) { index, command in
                        Button { choose(command) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("/\(command.name)").font(NativeFonts.code).foregroundStyle(NativeTokens.text).lineLimit(1)
                                if let description = command.description, !description.isEmpty {
                                    Text(description).font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if let source = command.source {
                                    Text(source).font(NativeFonts.micro).foregroundStyle(NativeTokens.textTertiary)
                                        .padding(.horizontal, 6).frame(height: 18)
                                        .background(NativeTokens.bgHover, in: RoundedRectangle(cornerRadius: Radius.sm))
                                }
                            }
                            .padding(.horizontal, 12).frame(height: Self.rowHeight)
                            .background(index == selected ? NativeTokens.bgHoverStrong : .clear, in: RoundedRectangle(cornerRadius: Radius.sm))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { selected = index } }
                        .id(index)
                        .accessibilityLabel("Insert /\(command.name)")
                        .accessibilityAddTraits(index == selected ? .isSelected : [])
                    }
                    if matches.isEmpty {
                        Text("No matching command").font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted)
                            .padding(.horizontal, 12).frame(height: Self.rowHeight)
                    }
                }
                .padding(4)
            }
            .frame(height: min(CGFloat(max(matches.count, 1)) * Self.rowHeight + 8, 240))
            .onChange(of: selected) { _, index in proxy.scrollTo(index) }
        }
        .background(NativeTokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.xl))
        .overlay(RoundedRectangle(cornerRadius: Radius.xl).strokeBorder(NativeTokens.borderStrong, lineWidth: 1))
        .shadow(color: NativeTokens.composerShadow, radius: 3, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slash commands")
    }
}

// MARK: Approval panel (page 8, §6)

/// pi's standard dialogs inside the composer card (t3 ComposerPendingApprovalPanel):
/// confirm → Allow once / Deny, select → stacked options, input/editor → field + Submit.
/// "Always for this agent" needs a matching option to exist; pi's dialogs have none.
struct NativeApprovalCard: View {
    let dialog: NativeThreadDialog
    /// Pending dialogs in total; the panel shows the first as "1/N".
    var count = 1
    let enabled: Bool
    /// nil for RPC agents: there is no terminal to show, so every handoff link is hidden.
    let showTerminal: (() -> Void)?
    let answer: (NativeDialogAnswer) -> Void
    @State private var text: String

    init(dialog: NativeThreadDialog, count: Int = 1, enabled: Bool, showTerminal: (() -> Void)?, answer: @escaping (NativeDialogAnswer) -> Void) {
        self.dialog = dialog
        self.count = count
        self.enabled = enabled
        self.showTerminal = showTerminal
        self.answer = answer
        _text = State(initialValue: dialog.prefill ?? "")
    }

    var body: some View {
        let blocked = !enabled || dialog.unavailable != nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 13, weight: .medium)).foregroundStyle(NativeTokens.warning)
                Text(dialog.title).font(NativeFonts.label).foregroundStyle(NativeTokens.warningText).textSelection(.enabled)
                Spacer(minLength: 0)
                if count > 1 {
                    Text("1/\(count)").font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).monospacedDigit()
                }
            }
            if let message = dialog.message {
                ScrollView {
                    Text(message).font(NativeFonts.code).foregroundStyle(NativeTokens.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(NativeTokens.bgMuted, in: RoundedRectangle(cornerRadius: Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(NativeTokens.border, lineWidth: 1))
            }
            if let unavailable = dialog.unavailable {
                HStack(spacing: 8) {
                    Text(unavailable == "external-editor"
                         ? "An external editor is open · finish it in Terminal before answering here"
                         : showTerminal == nil ? "This question is too large to show here" : "This question is unavailable natively · answer in Terminal")
                        .font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted)
                    NativeTerminalLink(action: showTerminal)
                }
            }
            Group {
                switch dialog.kind {
                case .confirm:
                    HStack(spacing: 8) {
                        Button("Allow once") { answer(.confirm(value: true)) }.buttonStyle(NativeButtonStyle(.primary))
                            .help("Y when the panel is focused")
                        Button("Deny") { answer(.confirm(value: false)) }.buttonStyle(NativeButtonStyle(.ghost))
                            .foregroundStyle(NativeTokens.dangerText)
                            .help("N when the panel is focused")
                        Spacer(minLength: 0)
                        Button("Cancel") { answer(.cancel) }.buttonStyle(.plain).font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted)
                    }
                    // Spec §6: Y/N answer only while the panel itself holds focus, so typing in the
                    // composer can never approve a command by accident.
                    .focusable()
                    .onKeyPress(characters: .init(charactersIn: "yYnN")) { press in
                        guard !blocked else { return .ignored }
                        answer(.confirm(value: press.characters.lowercased() == "y"))
                        return .handled
                    }
                case .select:
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array((dialog.options ?? []).enumerated()), id: \.offset) { index, option in
                            Button { answer(.select(value: option)) } label: {
                                Text(option).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(NativeButtonStyle(index == 0 ? .primary : .secondary))
                            .accessibilityLabel("Choose \(option)")
                        }
                        Button("Cancel") { answer(.cancel) }.buttonStyle(NativeButtonStyle(.ghost)).foregroundStyle(NativeTokens.dangerText)
                    }
                case .input, .editor:
                    TextField(dialog.placeholder ?? "Answer", text: $text, axis: .vertical)
                        .lineLimit(dialog.kind == .editor ? 5...12 : 1...5)
                        .textFieldStyle(.plain)
                        .font(dialog.kind == .editor ? NativeFonts.code : NativeFonts.bodySmall)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(NativeTokens.bgMuted, in: RoundedRectangle(cornerRadius: Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(NativeTokens.border, lineWidth: 1))
                        .accessibilityLabel(dialog.kind == .editor ? "Editor answer" : "Input answer")
                    HStack(spacing: 8) {
                        Button("Submit") { answer(dialog.kind == .editor ? .editor(value: text) : .input(value: text)) }
                            .buttonStyle(NativeButtonStyle(.primary))
                        Button("Cancel") { answer(.cancel) }.buttonStyle(NativeButtonStyle(.ghost)).foregroundStyle(NativeTokens.dangerText)
                    }
                }
            }
            .disabled(blocked)
            if dialog.timeout != nil {
                Text("May time out in pi").font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent is asking: \(dialog.title)")
    }
}

/// Kept for callers that still reference the old name.
typealias DesktopNativeDialog = NativeApprovalCard

// MARK: Composer accessories

struct NativeInlineError: View {
    let text: String
    let reconnect: () -> Void
    /// nil for RPC agents: there is no terminal to show, so every handoff link is hidden.
    let showTerminal: (() -> Void)?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(NativeTokens.danger)
            Text(text).font(NativeFonts.caption).foregroundStyle(NativeTokens.dangerText).lineLimit(2)
            Spacer(minLength: 0)
            Button("Reconnect", action: reconnect).buttonStyle(.plain).font(NativeFonts.captionMedium).foregroundStyle(NativeTokens.dangerText).underline()
            // Page 7 pairing rule: on dangerBg only dangerText, never accentText.
            NativeTerminalLink(action: showTerminal, color: NativeTokens.dangerText)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(NativeTokens.dangerBg, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(NativeTokens.danger.opacity(0.3), lineWidth: 1))
    }
}

struct NativeWidgetRow: View {
    let widget: NativeThreadWidget
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text((widget.title ?? "\(widget.namespace) · \(widget.key)").uppercased()).font(NativeFonts.section).tracking(0.5)
                .foregroundStyle(NativeTokens.textTertiary)
            Text(widget.text).font(NativeFonts.micro).foregroundStyle(NativeTokens.textSecondary)
                .lineLimit(widget.kind == .status ? 1 : 4)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

/// A resized image waiting in the composer. `data` is the bytes pi will receive.
struct NativeAttachment: Identifiable {
    let id = UUID()
    let name: String
    let image: NativeImage
    let thumbnail: NSImage?

    /// nil when the file is not a raster image.
    init?(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image),
              let data = try? Data(contentsOf: url), NSBitmapImageRep(data: data) != nil else { return nil }
        name = url.lastPathComponent
        image = NativeImage(mimeType: type == .jpeg ? "image/jpeg" : type == .gif ? "image/gif" : type == .webP ? "image/webp" : "image/png", data: data)
        thumbnail = NSImage(data: data)
    }
}

struct NativeAttachmentRow: View {
    let attachments: [NativeAttachment]
    let remove: (UUID) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let thumbnail = attachment.thumbnail {
                                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "photo").foregroundStyle(NativeTokens.textMuted)
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(NativeTokens.border, lineWidth: 1))
                        Button { remove(attachment.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(NativeTokens.bgRaised)
                                .frame(width: 16, height: 16).background(NativeTokens.text, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .help("Remove \(attachment.name)")
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .help(attachment.name)
                    .accessibilityLabel("Attached image \(attachment.name)")
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }
}

/// Model chip as a menu over pi's catalog (same source as Settings ▸ Agents).
struct NativeModelMenu: View {
    let current: String
    let disabled: Bool
    let choose: (String) -> Void
    @State private var options: [String] = []

    var body: some View {
        Menu {
            Picker("Model", selection: Binding(get: { current }, set: { choose($0) })) {
                if !options.contains(current) { Text(current).tag(current) }
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            NativeChip(text: nativeModelShortName(current), menu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(disabled)
        .help("Model in use: \(current). Pick another for the next turn.")
        .accessibilityLabel("Model")
        .task { options = await Task.detached(priority: .utility) { PiConfig.modelIDs() }.value }
    }
}

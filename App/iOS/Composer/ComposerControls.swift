import SwiftUI
import PhotosUI
import ShepherdCore
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The + beside the field (the boards' `.gt-att`): a menu of Photos and Files, where images come from, and Commands, which puts a
/// slash in an empty field. Up to the images a message still has room for are taken, resized for the send as they arrive
/// (`ComposerState.attach`). Pasting into the field and dropping on the composer reach the same place (`ComposerImageInput`).
struct AttachButton: View {
    let state: ComposerState
    let enabled: Bool
    /// Drawn as the paperclip chip in the iPad's card (Projects), or as the pill's +.
    var chip = false
    /// The host takes images: Photos and Files are offered.
    var offersImages = true
    /// Opens the command list; nil where the thread has no commands.
    var commands: (() -> Void)?
    @State private var items: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var choosingFiles = false

    var body: some View {
        let canAttach = offersImages && enabled && state.room > 0 && state.pendingImports == 0
        Menu {
            if offersImages {
                Button("Photos", systemImage: "photo.on.rectangle") { choosingPhotos = true }
                    .disabled(!canAttach)
                Button("Files", systemImage: "folder") { choosingFiles = true }
                    .disabled(!canAttach)
            }
            if let commands {
                Button("Commands", systemImage: "slash.circle", action: commands)
            }
        } label: {
            Image(systemName: chip ? "paperclip" : "plus")
                .font(chip ? .sh(.ui, weight: .medium) : .system(size: SHTouchComposerMetrics.plusGlyph, weight: .light))
                .foregroundStyle(Color.sh.textSecondary)
                .frame(width: chip ? SHComposerMetrics.chipHeight : SHTouchComposerMetrics.attachSize,
                       height: chip ? SHComposerMetrics.chipHeight : SHTouchComposerMetrics.attachSize)
                .contentShape(Rectangle())
                .shTouchTarget(height: chip ? SHComposerMetrics.chipHeight : SHTouchComposerMetrics.attachSize,
                               width: chip ? SHComposerMetrics.chipHeight : SHTouchComposerMetrics.attachSize)
        }
        .disabled(!canAttach && commands == nil)
        .accessibilityLabel(commands == nil ? "Attach images" : "Attach and commands")
        .photosPicker(isPresented: $choosingPhotos, selection: $items, maxSelectionCount: max(1, state.room), matching: .images, photoLibrary: .shared())
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { await state.attach(files: urls) }
        }
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            items = []
            state.pendingImports += 1
            Task {
                defer { state.pendingImports -= 1 }
                state.attachmentError = nil
                let pixels = MobileLayout.attachmentThumbnailPixels
                var errors: [String] = []
                var failures = 0
                // One original at a time: each is resized off the main thread and released before the next loads.
                for (index, item) in picked.enumerated() {
                    guard state.room > 0 else {
                        errors.append(NativeImagePreparation.Failure.full.description)
                        break
                    }
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        failures += 1
                        continue
                    }
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
                    let name = picked.count == 1 ? "Photo.\(ext)" : "Photo \(index + 1).\(ext)"
                    let prepared = await Task.detached(priority: .userInitiated) { ComposerState.prepare(data, name: name, thumbnailPixels: pixels) }.value
                    if let error = state.append(prepared) { errors.append(error) }
                }
                if failures > 0 { errors.append("\(failures) image(s) couldn't be loaded. Select them again to retry.") }
                if !errors.isEmpty { state.attachmentError = errors.joined(separator: " ") }
            }
        }
    }
}

/// The model chip (the boards' `.md`): the current model in 13pt `textSecondary`, then the thinking level where the pill has room
/// for it (iPad, iPhone Duo open), then a chevron. It opens the picker sheet when the agent can change model, and is plain text
/// otherwise. `short` draws the model's short name (a design's chat, iPadDesign: "opus").
struct ModelChip: View {
    let model: String?
    /// The thinking level's title, drawn after the name.
    var thinking: String?
    let canChange: Bool
    var short = false
    let open: () -> Void

    var body: some View {
        let title = model.map(short ? NativeModelChoices.compactName : NativeModelChoices.shortName) ?? "Model"
        Button(action: open) {
            HStack(spacing: SH.Space.xs) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if let thinking { Text(thinking).foregroundStyle(Color.sh.textTertiary).lineLimit(1) }
                if canChange { SHChipChevron() }
            }
            .font(.shSans(SHTouchComposerMetrics.chipSize))
            .foregroundStyle(Color.sh.textSecondary)
            .padding(.horizontal, SH.Space.xs)
            .frame(minHeight: SHTouchComposerMetrics.attachSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canChange)
        .accessibilityLabel("Model, \(model ?? title)" + (thinking.map { ", thinking \($0)" } ?? ""))
        .accessibilityHint(canChange ? "Choose the agent's model, thinking level and speed" : "")
    }
}

/// The thinking levels pi offers the thread's model and the speed tiers the host offers, as the model picker's first sections: each
/// a checked list, the level or tier set as it is tapped.
struct ModelSettingsSections: View {
    let store: NativeThreadStore
    let state: ComposerState
    let live: Bool

    var body: some View {
        if NativeThinkingLevel.offered(thinking: store.thinking, supportedActions: store.supportedActions, model: store.model,
                                       listing: state.models, levels: store.thinkingLevels) {
            let level = store.thinking
            Section("Thinking") {
                Picker("Thinking", selection: Binding(get: { level ?? "" }, set: { choice in Task { await store.setThinking(choice) } })) {
                    ForEach(store.thinkingLevels) { option in
                        Text(option.note.map { "\(option.title) · \($0)" } ?? option.title).tag(option.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(!live)
            }
        }
        if store.offersServiceTier {
            Section("Speed") {
                Picker("Speed", selection: Binding(get: { store.serviceTier }, set: { tier in Task { await store.setServiceTier(tier) } })) {
                    ForEach(store.serviceTiers, id: \.self) { option in
                        Text("\(option.title) · \(option.summary)").tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(!live)
            }
        }
    }
}

/// The model picker (from the model chip): the host's catalog in one section per provider,
/// searchable, with a check on the current model and each model's thinking levels under its name.
struct ModelPickerSheet<Settings: View>: View {
    let host: MobileHost?
    let current: String?
    /// The levels pi reports for the current model (the snapshot's), read as the sheet loads.
    let currentLevels: () -> [String]?
    let choose: (String) -> Void
    /// The thread's thinking level and speed, above the models.
    @ViewBuilder let settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var models: [String]?
    /// Each model's second line (`NativeModelChoices.thinkingLines`), derived once per catalog.
    @State private var thinking: [String: String] = [:]
    @State private var failure: String?
    @State private var sections: [NativeModelSection] = []

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    SHEmptyState(Text("Models unavailable"), message: failure)
                } else if models == nil {
                    SHBusyLabel("Loading models…")
                } else if sections.isEmpty {
                    SHEmptyState(Text("No models"), message: query.isEmpty ? "\(host?.name ?? "The host") lists no models." : "Nothing matches \u{201C}\(query)\u{201D}.")
                } else {
                    List {
                        // While searching, only the models.
                        if query.isEmpty { settings }
                        ForEach(sections) { section in
                            Section(section.title) {
                                ForEach(section.models) { model in
                                    Button {
                                        choose(model.id)
                                        dismiss()
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                                                Text(model.title).font(.sh(.code)).foregroundStyle(Color.sh.textPrimary)
                                                    .lineLimit(1).truncationMode(.middle)
                                                if let levels = model.thinking {
                                                    Text(levels).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                                                        .lineLimit(1).truncationMode(.tail)
                                                }
                                            }
                                            Spacer(minLength: SH.Space.m)
                                            if model.isCurrent {
                                                Image(systemName: "checkmark").foregroundStyle(Color.sh.running)
                                                    .accessibilityLabel("Current")
                                            }
                                        }
                                        .frame(minHeight: SH.Height.touch)
                                        .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel(model.id + (model.thinking.map { ", \($0)" } ?? ""))
                                    .accessibilityAddTraits(model.isCurrent ? .isSelected : [])
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.sh.bgWindow)
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
        .onChange(of: query) { _, _ in derive() }
    }

    private func derive() {
        sections = NativeModelChoices.sections(models ?? [], current: current, query: query, thinking: thinking)
    }

    private func adopt(_ listing: ModelListing, host: MobileHost) {
        models = listing.models
        thinking = NativeModelChoices.thinkingLines(listing, hostTakesAllLevels: host.supports(RemoteProtocol.thinkingLevelsCapability),
                                                    current: current, currentLevels: currentLevels())
        derive()
    }

    private func load() async {
        guard let host else { failure = "This host was forgotten."; return }
        if let cached = ComposerStates.shared.models(host: host.id, session: host.session) {
            adopt(cached, host: host)
            return
        }
        guard let client = host.connectedClient else { failure = "\(host.name) is offline."; return }
        do {
            let listing = try await client.listModels()
            ComposerStates.shared.setModels(listing, host: host.id, session: host.session)
            adopt(listing, host: host)
        } catch {
            failure = String(describing: error)
        }
    }
}

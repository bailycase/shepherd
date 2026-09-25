import SwiftUI
import PhotosUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The paperclip: picks up to the images a message still has room for from Photos, resized for
/// the send as they arrive (`ComposerState.attach`).
struct AttachButton: View {
    let state: ComposerState
    let enabled: Bool
    /// Drawn as the phone's round button beside the capsule, or as a chip in the iPad's row.
    var chip = false
    @State private var items: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $items, maxSelectionCount: max(1, state.room), matching: .images, photoLibrary: .shared()) {
            Image(systemName: "paperclip")
                .font(.nw(chip ? .ui : .headline, weight: .medium))
                .foregroundStyle(Color.nw.textSecondary)
                .frame(width: chip ? NWComposerMetrics.chipHeight : NW.Height.touch,
                       height: chip ? NWComposerMetrics.chipHeight : NW.Height.touch)
                .contentShape(Rectangle())
                .nwTouchTarget(height: chip ? NWComposerMetrics.chipHeight : NW.Height.touch,
                               width: chip ? NWComposerMetrics.chipHeight : NW.Height.touch)
        }
        .disabled(!enabled || state.room == 0)
        .accessibilityLabel("Attach images")
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            items = []
            Task {
                var loaded: [(data: Data, name: String)] = []
                for (index, item) in picked.enumerated() {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
                    loaded.append((data, picked.count == 1 ? "Photo.\(ext)" : "Photo \(index + 1).\(ext)"))
                }
                await state.attach(loaded)
            }
        }
    }
}

// The chips take their button style from the row: the Mac's composer chip in the iPad's card,
// a ghost button on the phone, whose chips grow with Dynamic Type.

/// The model chip: the current model in mono with a chevron; it opens the picker sheet when the
/// agent can change model, and is plain text otherwise.
struct ModelChip: View {
    let model: String?
    let canChange: Bool
    let open: () -> Void

    var body: some View {
        let title = model.map(NativeModelChoices.shortName) ?? "Model"
        Button(action: open) {
            HStack(spacing: NW.Space.s) {
                Text(title).font(.nw(.mono)).lineLimit(1).truncationMode(.middle)
                if canChange { NWChipChevron() }
            }
        }
        .disabled(!canChange)
        .accessibilityLabel("Model, \(model ?? title)")
        .accessibilityHint(canChange ? "Choose the agent's model" : "")
    }
}

/// The thinking chip: a menu of the levels pi offers the thread's model, checked at the current
/// level.
struct ThinkingChip: View {
    let level: String?
    let levels: [NativeThinkingLevel]
    let enabled: Bool
    let choose: (String) -> Void

    var body: some View {
        let title = level.map(NativeThinkingLevel.title) ?? "Default"
        Menu {
            Picker("Thinking", selection: Binding(get: { level ?? "" }, set: choose)) {
                ForEach(levels) { option in
                    Text(option.note.map { "\(option.title) · \($0)" } ?? option.title).tag(option.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: NW.Space.s) {
                Image(systemName: "lightbulb")
                Text("Thinking")
                Text(title).fontWeight(.medium).foregroundStyle(Color.nw.textPrimary)
                NWChipChevron()
            }
        }
        .disabled(!enabled)
        .accessibilityLabel("Thinking, \(title)")
    }
}

/// "/ commands": puts a slash in an empty field, which opens the command list.
struct CommandsChip: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: NW.Space.s) {
                Text("/").font(.nw(.mono))
                Text("commands")
            }
        }
        .accessibilityLabel("Slash commands")
    }
}

/// The model picker (from the model chip): the host's catalog in one section per provider,
/// searchable, with a check on the current model and each model's thinking levels under its name.
struct ModelPickerSheet: View {
    let host: MobileHost?
    let current: String?
    /// The levels pi reports for the current model (the snapshot's), read as the sheet loads.
    let currentLevels: () -> [String]?
    let choose: (String) -> Void
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
                    NWEmptyState(Text("Models unavailable"), message: failure)
                } else if models == nil {
                    ProgressView().progressViewStyle(NWSpinnerStyle())
                } else if sections.isEmpty {
                    NWEmptyState(Text("No models"), message: query.isEmpty ? "\(host?.name ?? "The host") lists no models." : "Nothing matches \u{201C}\(query)\u{201D}.")
                } else {
                    List {
                        ForEach(sections) { section in
                            Section(section.title) {
                                ForEach(section.models) { model in
                                    Button {
                                        choose(model.id)
                                        dismiss()
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                                                Text(model.title).font(.nw(.code)).foregroundStyle(Color.nw.textPrimary)
                                                    .lineLimit(1).truncationMode(.middle)
                                                if let levels = model.thinking {
                                                    Text(levels).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                                                        .lineLimit(1).truncationMode(.tail)
                                                }
                                            }
                                            Spacer(minLength: NW.Space.m)
                                            if model.isCurrent {
                                                Image(systemName: "checkmark").foregroundStyle(Color.nw.running)
                                                    .accessibilityLabel("Current")
                                            }
                                        }
                                        .frame(minHeight: NW.Height.touch)
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
            .background(Color.nw.bgWindow)
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

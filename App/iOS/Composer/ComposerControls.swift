import SwiftUI
import PhotosUI
import ShepherdCore
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
                .font(.sh(chip ? .ui : .headline, weight: .medium))
                .foregroundStyle(Color.sh.textSecondary)
                .frame(width: chip ? SHComposerMetrics.chipHeight : SH.Height.touch,
                       height: chip ? SHComposerMetrics.chipHeight : SH.Height.touch)
                .contentShape(Rectangle())
                .shTouchTarget(height: chip ? SHComposerMetrics.chipHeight : SH.Height.touch,
                               width: chip ? SHComposerMetrics.chipHeight : SH.Height.touch)
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
/// agent can change model, and is plain text otherwise. `short` draws the model's short name
/// (a design's chat, iPadDesign: "opus").
struct ModelChip: View {
    let model: String?
    let canChange: Bool
    var short = false
    let open: () -> Void

    var body: some View {
        let title = model.map(short ? NativeModelChoices.compactName : NativeModelChoices.shortName) ?? "Model"
        Button(action: open) {
            HStack(spacing: SH.Space.s) {
                Text(title).font(.sh(.mono)).lineLimit(1).truncationMode(.middle)
                if canChange { SHChipChevron() }
            }
        }
        .disabled(!canChange)
        .accessibilityLabel("Model, \(model ?? title)")
        .accessibilityHint(canChange ? "Choose the agent's model" : "")
    }
}

/// The thinking chip: a menu of the levels pi offers the thread's model, checked at the current
/// level. At the compact size (a design's chat) it shows the level without "Thinking".
struct ThinkingChip: View {
    let level: String?
    let levels: [NativeThinkingLevel]
    let enabled: Bool
    let choose: (String) -> Void
    @Environment(\.shComposerSize) private var size

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
            HStack(spacing: SH.Space.s) {
                Image(systemName: "lightbulb")
                if size.showsChipWords() { Text("Thinking") }
                Text(title).fontWeight(.medium).foregroundStyle(Color.sh.textPrimary)
                SHChipChevron()
            }
        }
        .disabled(!enabled)
        .accessibilityLabel("Thinking, \(title)")
    }
}

/// The speed chip: a menu of the tiers the host offers the thread's model (Standard, Fast), each
/// with what it does, checked at the current one; the bolt fills in `lantern` for a raised tier.
/// At the compact size (a design's chat) it shows the value without "Speed".
struct SpeedChip: View {
    let tier: ServiceTier
    let tiers: [ServiceTier]
    let enabled: Bool
    let choose: (ServiceTier) -> Void
    @Environment(\.shComposerSize) private var size

    var body: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { tier }, set: choose)) {
                ForEach(tiers, id: \.self) { option in
                    Text("\(option.title) · \(option.summary)").tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: SH.Space.s) {
                Image(systemName: tier == .standard ? "bolt" : "bolt.fill")
                    .foregroundStyle(tier == .standard ? Color.sh.textSecondary : Color.sh.lantern)
                if size.showsChipWords() { Text("Speed") }
                Text(tier.title).fontWeight(.medium).foregroundStyle(Color.sh.textPrimary)
                SHChipChevron()
            }
        }
        .disabled(!enabled)
        .accessibilityLabel("Speed: \(tier.title)")
    }
}

/// "/ commands": puts a slash in an empty field, which opens the command list.
struct CommandsChip: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: SH.Space.s) {
                Text("/").font(.sh(.mono))
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
                    SHEmptyState(Text("Models unavailable"), message: failure)
                } else if models == nil {
                    ProgressView().progressViewStyle(SHSpinnerStyle())
                } else if sections.isEmpty {
                    SHEmptyState(Text("No models"), message: query.isEmpty ? "\(host?.name ?? "The host") lists no models." : "Nothing matches \u{201C}\(query)\u{201D}.")
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

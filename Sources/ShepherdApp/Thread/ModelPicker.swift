import Foundation
import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// The model catalog as the picker shows it, derived once per catalog (off the main actor)
/// instead of on every keystroke: each model's short name, note, thinking line, provider, and
/// search key.
struct ModelCatalog: Sendable {
    struct Model: Sendable, Equatable {
        let id: String
        let provider: String
        /// "claude-opus-4-5" for "anthropic/claude-opus-4-5".
        let title: String
        let context: String?
        let reasoning: Bool
        /// The row's second line: the levels the model takes ("Off · Minimal · Low · Medium ·
        /// High", or "No thinking"; `NativeModelChoices.thinkingLines`).
        let thinking: String
        /// The id, lowercased: what a query matches.
        let key: String
    }

    static let empty = ModelCatalog([])

    /// Catalog order.
    let models: [Model]
    private let index: [String: Int]

    /// `levels` are the levels models.json configures, per model (`ModelListing.thinkingLevels`);
    /// a host without `thinking.levels.v1` (`hostTakesAllLevels` false) takes only Off to High.
    init(_ entries: [PiModelCatalog.Entry], levels: [String: [String]]? = nil, hostTakesAllLevels: Bool = true) {
        var listing = ModelListing(entries: entries, defaultModel: nil)
        listing.thinkingLevels = levels
        let lines = NativeModelChoices.thinkingLines(listing, hostTakesAllLevels: hostTakesAllLevels)
        models = entries.map {
            Model(id: $0.id, provider: $0.provider, title: nativeModelShortName($0.id), context: $0.context, reasoning: $0.reasoning,
                  thinking: lines[$0.id] ?? NativeThinkingLevel.line([]), key: $0.id.lowercased())
        }
        index = Dictionary(models.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var isEmpty: Bool { models.isEmpty }

    func model(_ id: String) -> Model? { index[id].map { models[$0] } }

    /// The picker's list for `query`: Recent (the `recent` ids that match, or all of them for no
    /// query, even ones the catalog lacks), then one section per provider in catalog order,
    /// without the recent models. Each row's second line lists the levels its model takes: pi's
    /// own for the `current` model when the thread reports them (`currentLevels`), else the
    /// catalog's.
    func list(query: String, recent: [String], current: String?, currentLevels: [String]? = nil) -> NWModelList {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let currentLine = currentLevels.flatMap { $0.isEmpty ? nil : NativeThinkingLevel.line($0) }
        func subtitle(_ id: String, catalog: String?) -> String? {
            id == current ? currentLine ?? catalog : catalog
        }
        func option(_ model: Model) -> NWModelOption {
            NWModelOption(id: model.id, title: model.title, subtitle: subtitle(model.id, catalog: model.thinking), note: model.context,
                          isCurrent: model.id == current)
        }
        var sections: [NWModelSection] = []
        let recentOptions = recent.compactMap { id -> NWModelOption? in
            if let model = model(id) { return q.isEmpty || model.key.contains(q) ? option(model) : nil }
            return q.isEmpty
                ? NWModelOption(id: id, title: nativeModelShortName(id), subtitle: subtitle(id, catalog: nil), isCurrent: id == current)
                : nil
        }
        if !recentOptions.isEmpty { sections.append(NWModelSection(title: "Recent", options: recentOptions)) }
        let recentIDs = Set(recent)
        var providers: [String] = []
        var byProvider: [String: [NWModelOption]] = [:]
        for model in models where !recentIDs.contains(model.id) && (q.isEmpty || model.key.contains(q)) {
            if byProvider[model.provider] == nil { providers.append(model.provider) }
            byProvider[model.provider, default: []].append(option(model))
        }
        for provider in providers { sections.append(NWModelSection(title: provider, options: byProvider[provider] ?? [])) }
        return NWModelList(sections: sections)
    }

    // MARK: This Mac's catalog

    @MainActor private static var local: ModelCatalog?
    @MainActor private static var loadingLocal: Task<ModelCatalog, Never>?

    /// `pi --list-models` on this Mac, asked once per process however many threads want it at
    /// once (every mounted composer does as the app opens), and derived off the main actor. A
    /// failed ask is not kept, so the next one tries again.
    @MainActor
    static func loadLocal() async -> ModelCatalog {
        if let local { return local }
        let task = loadingLocal ?? Task.detached(priority: .utility) {
            let entries = PiModelCatalog.entries()
            return ModelCatalog(entries, levels: ModelListing(entries: entries, defaultModel: nil, levelMaps: PiConfig.thinkingLevelMaps()).thinkingLevels)
        }
        loadingLocal = task
        let catalog = await task.value
        loadingLocal = nil
        if !catalog.isEmpty { local = catalog }
        return catalog
    }

    /// A catalog another host served, derived off the main actor.
    static func derive(_ listing: ModelListing, hostTakesAllLevels: Bool) async -> ModelCatalog {
        await Task.detached(priority: .userInitiated) {
            ModelCatalog(listing.entries, levels: listing.thinkingLevels, hostTakesAllLevels: hostTakesAllLevels)
        }.value
    }
}

/// An open model picker: its query, highlight, and list. Made when the picker opens (Recent read
/// then), and the list derived again only when the query or the catalog changes, never while
/// drawing.
@MainActor @Observable
final class ModelPickerState {
    var query = "" {
        didSet { if query != oldValue { rebuild() } }
    }
    var selection = 0
    private(set) var list: NWModelList
    private(set) var loading: Bool
    @ObservationIgnored private var catalog: ModelCatalog
    @ObservationIgnored private let recent: [String]
    @ObservationIgnored private let current: String?
    @ObservationIgnored private let currentLevels: [String]?

    /// `currentLevels`: the levels pi reports for the thread's `current` model (the snapshot's),
    /// nil from a host that does not say.
    init(catalog: ModelCatalog?, recent: [String], current: String?, currentLevels: [String]? = nil) {
        self.catalog = catalog ?? .empty
        self.recent = recent
        self.current = current
        self.currentLevels = currentLevels
        list = self.catalog.list(query: "", recent: recent, current: current, currentLevels: currentLevels)
        loading = self.catalog.isEmpty
    }

    /// The catalog arrived (or changed) while the picker was open.
    func update(_ catalog: ModelCatalog) {
        self.catalog = catalog
        rebuild()
    }

    private func rebuild() {
        list = catalog.list(query: query, recent: recent, current: current, currentLevels: currentLevels)
        loading = catalog.isEmpty
    }
}

/// The model picker over `NWModelPicker`: Recent (up to 4), then one section per provider, with
/// the picker's chord in its search row.
struct ModelPicker: View {
    @Bindable var state: ModelPickerState
    var maxHeight: CGFloat?
    let choose: (String) -> Void
    let close: () -> Void

    var body: some View {
        NWModelPicker(query: $state.query, list: state.list, loading: state.loading, selection: $state.selection, maxHeight: maxHeight,
                      shortcut: KeybindingsStore.shared.display(.modelPicker), onChoose: { choose($0.id) }, onClose: close)
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

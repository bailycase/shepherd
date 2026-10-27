import Foundation
import SwiftUI
import ShepherdCore
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
        /// The levels the model takes (pi's spellings; none without reasoning): what a Project's reasoning menu offers before its
        /// coordinator serves.
        let levels: [String]
        /// The id, lowercased: what a query matches.
        let key: String
        /// The model offers a raised service tier (Fast) on the host that listed it.
        let fast: Bool
    }

    static let empty = ModelCatalog([])

    /// Catalog order.
    let models: [Model]
    private let index: [String: Int]
    /// Short names two or more providers offer ("gpt-6-astra" from cpa and openai-codex): a row
    /// or chip for one of these names the provider too, or nothing tells them apart.
    private let ambiguous: Set<String>

    /// `levels` are the levels models.json configures, per model (`ModelListing.thinkingLevels`);
    /// a host without `thinking.levels.v1` (`hostTakesAllLevels` false) takes only Off to High.
    /// `serviceTiers` are the tiers the host offers each model (`ModelListing.serviceTiers`).
    init(_ entries: [PiModelCatalog.Entry], levels: [String: [String]]? = nil, serviceTiers: [String: [String]]? = nil,
         hostTakesAllLevels: Bool = true) {
        var listing = ModelListing(entries: entries, defaultModel: nil)
        listing.thinkingLevels = levels
        let levels = NativeModelChoices.thinkingLevels(listing, hostTakesAllLevels: hostTakesAllLevels)
        models = entries.map {
            Model(id: $0.id, provider: $0.provider, title: nativeModelShortName($0.id), context: $0.context, reasoning: $0.reasoning,
                  thinking: NativeThinkingLevel.line(levels[$0.id] ?? []), levels: levels[$0.id] ?? [], key: $0.id.lowercased(),
                  fast: (serviceTiers?[$0.id] ?? []).contains { $0 != ServiceTier.standard.rawValue })
        }
        index = Dictionary(models.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var providers: [String: Set<String>] = [:]
        for model in models { providers[model.title, default: []].insert(model.provider) }
        ambiguous = Set(providers.filter { $0.value.count > 1 }.keys)
    }

    var isEmpty: Bool { models.isEmpty }

    func model(_ id: String) -> Model? { index[id].map { models[$0] } }

    /// Whether another provider offers a model of the same short name.
    func isAmbiguous(_ id: String) -> Bool { ambiguous.contains(nativeModelShortName(id)) }

    /// The row's title where no provider header says which it is: the short name, or the whole id
    /// when another provider offers the same name.
    func title(_ id: String) -> String { isAmbiguous(id) ? id : nativeModelShortName(id) }

    /// The picker's list for `query`: Recent (the `recent` ids that match, or all of them for no
    /// query, even ones the catalog lacks), then one section per provider in catalog order,
    /// without the recent models. Each row's second line lists the levels its model takes: pi's
    /// own for the `current` model when the thread reports them (`currentLevels`), else the
    /// catalog's.
    func list(query: String, recent: [String], current: String?, currentLevels: [String]? = nil) -> SHModelList {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let currentLine = currentLevels.flatMap { $0.isEmpty ? nil : NativeThinkingLevel.line($0) }
        func subtitle(_ id: String, catalog: String?) -> String? {
            id == current ? currentLine ?? catalog : catalog
        }
        func option(_ model: Model) -> SHModelOption {
            SHModelOption(id: model.id, title: model.title, subtitle: subtitle(model.id, catalog: model.thinking), note: model.context,
                          isCurrent: model.id == current, fast: model.fast)
        }
        var sections: [SHModelSection] = []
        // Recent has no provider header: a name two providers offer is spelled out.
        let recentOptions = recent.compactMap { id -> SHModelOption? in
            if let model = model(id) {
                guard q.isEmpty || model.key.contains(q) else { return nil }
                var row = option(model)
                row.title = title(id)
                return row
            }
            return q.isEmpty
                ? SHModelOption(id: id, title: nativeModelShortName(id), subtitle: subtitle(id, catalog: nil), isCurrent: id == current)
                : nil
        }
        if !recentOptions.isEmpty { sections.append(SHModelSection(title: "Recent", options: recentOptions)) }
        let recentIDs = Set(recent)
        var providers: [String] = []
        var byProvider: [String: [SHModelOption]] = [:]
        for model in models where !recentIDs.contains(model.id) && (q.isEmpty || model.key.contains(q)) {
            if byProvider[model.provider] == nil { providers.append(model.provider) }
            byProvider[model.provider, default: []].append(option(model))
        }
        for provider in providers { sections.append(SHModelSection(title: provider, options: byProvider[provider] ?? [])) }
        return SHModelList(sections: sections)
    }

    /// Two quick choices for the settings popover. The current model stays even if unavailable;
    /// recent choices must still exist in the host's catalog. A model that offers a Fast tier
    /// carries the bolt: the current one by what the thread or draft says (`currentOffersFast`),
    /// the others by the catalog.
    static func settingsModels(catalog: ModelCatalog?, current: String?, recent: [String], currentOffersFast: Bool = false) -> [SHModelOption] {
        var ids = current.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        for id in recent where !ids.contains(id) && catalog?.model(id) != nil {
            guard ids.count < 2 else { break }
            ids.append(id)
        }
        return ids.map {
            let isCurrent = $0 == current
            return SHModelOption(id: $0, title: catalog?.title($0) ?? nativeModelShortName($0), isCurrent: isCurrent,
                                 fast: isCurrent ? currentOffersFast : catalog?.model($0)?.fast ?? false)
        }
    }

    // MARK: This Mac's catalog

    /// Coalesce simultaneous loads; PiModelCatalog owns persistence and invalidation. Keeping
    /// another permanent cache here would hide sign-ins and custom-provider changes.
    @MainActor private static var loadingLocal: [ObjectIdentifier: Task<ModelCatalog, Never>] = [:]

    /// Read the fingerprinted catalog and derive picker rows off the main actor.
    @MainActor
    static func loadLocal(from source: PiModelCatalog) async -> ModelCatalog {
        let key = ObjectIdentifier(source)
        let task = loadingLocal[key] ?? Task.detached(priority: .utility) {
            let entries = source.entriesOrConfigured()
            let listing = source.listing()
            return ModelCatalog(entries, levels: listing.thinkingLevels, serviceTiers: listing.serviceTiers)
        }
        loadingLocal[key] = task
        let catalog = await task.value
        loadingLocal[key] = nil
        return catalog
    }

    /// A catalog another host served, derived off the main actor.
    static func derive(_ listing: ModelListing, hostTakesAllLevels: Bool) async -> ModelCatalog {
        await Task.detached(priority: .userInitiated) {
            ModelCatalog(listing.entries, levels: listing.thinkingLevels, serviceTiers: listing.serviceTiers, hostTakesAllLevels: hostTakesAllLevels)
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
    private(set) var list: SHModelList
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

/// The model picker over `SHModelPicker`: Recent (up to 4), then one section per provider, with
/// the picker's chord in its search row. Equal while it shows the same picker in the same room:
/// its query, highlight and list reach it through the state's observation, so a composer redraw
/// for something else (the field losing focus to the search) leaves its list alone.
struct ModelPicker: View, Equatable {
    @Bindable var state: ModelPickerState
    var maxHeight: CGFloat?
    let choose: (String) -> Void
    let close: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.state === b.state && a.maxHeight == b.maxHeight }

    var body: some View {
        SHModelPicker(query: $state.query, list: state.list, loading: state.loading, selection: $state.selection, maxHeight: maxHeight,
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

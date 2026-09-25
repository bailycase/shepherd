import Foundation
import SwiftUI
import ShepherdUI
import ShepherdSessions

/// The model catalog as the picker shows it, derived once per catalog (off the main actor)
/// instead of on every keystroke: each model's short name, note, provider, and search key.
struct ModelCatalog: Sendable {
    struct Model: Sendable, Equatable {
        let id: String
        let provider: String
        /// "claude-opus-4-5" for "anthropic/claude-opus-4-5".
        let title: String
        let context: String?
        let reasoning: Bool
        /// The id, lowercased: what a query matches.
        let key: String
    }

    static let empty = ModelCatalog([])

    /// Catalog order.
    let models: [Model]
    private let index: [String: Int]

    init(_ entries: [PiModelCatalog.Entry]) {
        models = entries.map {
            Model(id: $0.id, provider: $0.provider, title: nativeModelShortName($0.id), context: $0.context, reasoning: $0.reasoning,
                  key: $0.id.lowercased())
        }
        index = Dictionary(models.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var isEmpty: Bool { models.isEmpty }

    func model(_ id: String) -> Model? { index[id].map { models[$0] } }

    /// The picker's list for `query`: Recent (the `recent` ids that match, or all of them for no
    /// query, even ones the catalog lacks), then one section per provider in catalog order,
    /// without the recent models. Each row's second line says what the board's does: the current
    /// model, where and when a recent one was used (`usage`), or whether a model thinks.
    func list(query: String, recent: [String], current: String?, usage: [String: RecentModels.Item] = [:],
              now: Date = Date()) -> NWModelList {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func subtitle(_ id: String, reasoning: Bool?) -> String? {
            Self.subtitle(id: id, current: current, used: usage[id], reasoning: reasoning, now: now)
        }
        func option(_ model: Model) -> NWModelOption {
            NWModelOption(id: model.id, title: model.title, subtitle: subtitle(model.id, reasoning: model.reasoning), note: model.context,
                          isCurrent: model.id == current)
        }
        var sections: [NWModelSection] = []
        let recentOptions = recent.compactMap { id -> NWModelOption? in
            if let model = model(id) { return q.isEmpty || model.key.contains(q) ? option(model) : nil }
            return q.isEmpty
                ? NWModelOption(id: id, title: nativeModelShortName(id), subtitle: subtitle(id, reasoning: nil), isCurrent: id == current)
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

    /// A row's second line (ModelPicker board): "Current · this thread", "Used 2h ago in
    /// “Plan”", or, for a model neither current nor used, whether it takes a thinking level.
    static func subtitle(id: String, current: String?, used: RecentModels.Item?, reasoning: Bool?, now: Date) -> String? {
        if id == current { return "Current · this thread" }
        if let used {
            let ago = "Used " + relativeAge(now.timeIntervalSince(used.at))
            return used.thread.map { "\(ago) in “\($0)”" } ?? ago
        }
        return reasoning.map { $0 ? "With thinking" : "No thinking" }
    }

    /// "just now", "5m ago", "2h ago", "3d ago".
    static func relativeAge(_ seconds: TimeInterval) -> String {
        switch max(0, seconds) {
        case ..<60: "just now"
        case ..<3600: "\(Int(seconds / 60))m ago"
        case ..<86_400: "\(Int(seconds / 3600))h ago"
        default: "\(Int(seconds / 86_400))d ago"
        }
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
        let task = loadingLocal ?? Task.detached(priority: .utility) { ModelCatalog(PiModelCatalog.entries()) }
        loadingLocal = task
        let catalog = await task.value
        loadingLocal = nil
        if !catalog.isEmpty { local = catalog }
        return catalog
    }

    /// A catalog another host served, derived off the main actor.
    static func derive(_ entries: [PiModelCatalog.Entry]) async -> ModelCatalog {
        await Task.detached(priority: .userInitiated) { ModelCatalog(entries) }.value
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
    @ObservationIgnored private let usage: [String: RecentModels.Item]
    @ObservationIgnored private let current: String?
    @ObservationIgnored private let opened = Date()

    /// `recent` also says where and when each was used (`RecentModels.load()`).
    convenience init(catalog: ModelCatalog?, recent: [RecentModels.Item], current: String?) {
        self.init(catalog: catalog, recent: recent.map(\.id), current: current,
                  usage: Dictionary(recent.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    init(catalog: ModelCatalog?, recent: [String], current: String?, usage: [String: RecentModels.Item] = [:]) {
        self.catalog = catalog ?? .empty
        self.recent = recent
        self.usage = usage
        self.current = current
        list = self.catalog.list(query: "", recent: recent, current: current, usage: usage, now: opened)
        loading = self.catalog.isEmpty
    }

    /// The catalog arrived (or changed) while the picker was open.
    func update(_ catalog: ModelCatalog) {
        self.catalog = catalog
        rebuild()
    }

    private func rebuild() {
        list = catalog.list(query: query, recent: recent, current: current, usage: usage, now: opened)
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

import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The ⌘K palette (Composer board, `.shCommandPalette`): a 620pt card 18% from the top over the
/// scrim, capped to the window. A 44pt search row with All · Commands · Agents scopes, then
/// results under mono caps headers — Commands, This thread, Subagents, and Agents/Spaces once
/// there is a query. Rows show an icon, the label, dim context, and the real shortcut.
///
/// Queries of 3+ characters also search agents' session transcripts in the background
/// (bounded tail scan, debounced), so a thread is findable by remembered conversation text;
/// those rows show a dim `…snippet…` line.
struct CommandPaletteView: View {
    var vm: ShepherdViewModel

    var body: some View {
        PaletteCard(
            items: vm.paletteItems,
            run: { vm.runPaletteItem($0) },
            close: { vm.showCommandPalette = false },
            contentSearch: { query, existing in
                let targets = vm.paletteSearchTargets
                let root = vm.server.pi.sessionsRoot
                let matches = await PaletteContentSearch.search(query: query, agents: targets, sessionsRoot: root)
                guard !Task.isCancelled else { return [] }
                let local = vm.paletteContentRows(matches: matches, excluding: existing)
                return local + (await vm.remoteContentRows(query: query, excluding: existing))
            }
        )
    }
}

/// The palette itself, independent of the view model so it renders in tests.
struct PaletteCard: View {
    let items: [PaletteItem]
    let run: (PaletteItem) -> Void
    let close: () -> Void
    /// Transcript search: rows for agents whose conversation matched (excluding ids already shown).
    var contentSearch: ((String, Set<String>) async -> [PaletteItem])?
    var initialQuery = ""
    private let probe: PaletteDerivationProbe?
    @State private var query = ""
    @State private var scope: PaletteItem.Scope = .all
    /// The highlighted row: ↑↓ and hover move it.
    @State private var highlight: PaletteHighlight
    @State private var contentRows: [PaletteItem] = []
    @State private var contentSearchTask: Task<Void, Never>?
    /// A transcript search is pending or running: the empty list says so instead of "No matches".
    @State private var searching = false
    /// Filtered once per query, scope, items or transcript matches; hover and the arrow keys
    /// only move the highlight.
    @State private var results = PaletteResults()
    @FocusState private var fieldFocused: Bool
    @Environment(\.shPaletteMaxListHeight) private var maxListHeight

    /// `highlight` lets a test move the highlight as ↑↓ and hover do.
    init(items: [PaletteItem], run: @escaping (PaletteItem) -> Void, close: @escaping () -> Void,
         contentSearch: ((String, Set<String>) async -> [PaletteItem])? = nil, initialQuery: String = "",
         highlight: PaletteHighlight? = nil) {
        self.init(items: items, run: run, close: close, contentSearch: contentSearch,
                  initialQuery: initialQuery, highlight: highlight, probe: nil)
    }

    init(items: [PaletteItem], run: @escaping (PaletteItem) -> Void, close: @escaping () -> Void,
         contentSearch: ((String, Set<String>) async -> [PaletteItem])? = nil, initialQuery: String = "",
         highlight: PaletteHighlight? = nil, probe: PaletteDerivationProbe?) {
        self.items = items
        self.run = run
        self.close = close
        self.contentSearch = contentSearch
        self.initialQuery = initialQuery
        self.probe = probe
        #if DEBUG
        probe?.cardInitializations += 1
        #endif
        _highlight = State(initialValue: highlight ?? PaletteHighlight())
        // A cheap seed: only the instance SwiftUI retains derives results, synchronously on
        // first read. ImageRenderer/first paint stays populated, without waiting for onAppear.
        _results = State(initialValue: PaletteResults(items: items, query: initialQuery, scope: .all, contentRows: [], probe: probe))
    }

    var body: some View {
        SHPaletteCard {
            SHPaletteSearchRow("Search commands, agents, subagents…", text: $query, focus: $fieldFocused, submit: runSelected) {
                SHSegmentedPicker("Scope", selection: $scope, options: PaletteItem.Scope.allCases.map { ($0, $0.title) }, size: .s)
                    .shHelp("Switch scope", shortcut: "⇥")
            }
        } results: {
            resultsList
        }
        // Rows arrive, leave, and reorder as the query or scope changes, and the card follows
        // their height; moving the highlight (↑↓, hover) changes no row, so it lands at once.
        .shAnimation(.list, value: results.layout)
        .onAppear {
            query = initialQuery
            fieldFocused = true
            #if DEBUG
            probe?.setQuery = { query = $0 }
            probe?.setScope = { scope = $0 }
            probe?.submit = runSelected
            #endif
        }
        .onDisappear {
            contentSearchTask?.cancel()
            contentSearchTask = nil
            #if DEBUG
            probe?.setQuery = nil
            probe?.setScope = nil
            probe?.submit = nil
            #endif
        }
        .onChange(of: query) {
            highlight.move(to: 0)
            scheduleContentSearch()
            refreshResults()
        }
        .onChange(of: scope) {
            highlight.move(to: 0)
            refreshResults()
        }
        .onChange(of: contentRows) { refreshResults() }
        // The retained seed supplies the first results from these items.
        .onChange(of: items) { refreshResults() }
        .onKeyPress(.upArrow) {
            highlight.move(to: max(0, highlight.index - 1))
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlight.move(to: min(max(0, results.rows.count - 1), highlight.index + 1))
            return .handled
        }
        .onKeyPress(.tab) {
            let all = PaletteItem.Scope.allCases
            scope = all[((all.firstIndex(of: scope) ?? 0) + 1) % all.count]
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    // MARK: Results

    private var resultsList: some View {
        #if DEBUG
        let _ = recordProbe()
        #endif
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Lazy: a query can match every agent and subagent, and only the rows on screen
                // are built. The card still hugs a short list: the stack's height is exact once
                // every row is realized, and past the cap the list scrolls.
                LazyVStack(alignment: .leading, spacing: 0) {
                    let highlighted = highlight.index
                    ForEach(results.entries) { entry in
                        PaletteEntryRow(entry: entry, highlighted: entry.index == highlighted, run: run,
                                        hover: { highlight.move(to: $0) })
                            .equatable()
                            .shTransition(.list)
                    }
                    if results.rows.isEmpty {
                        Text(Self.emptyText(query: query, searching: searching))
                            .font(Font.sh(.caption))
                            .foregroundStyle(Color.sh.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: SHPaletteMetrics.sectionHeight * 2)
                            .shTransition(.content)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlight.index) {
                if results.rows.indices.contains(highlight.index) { proxy.scrollTo(results.rows[highlight.index].id) }
            }
        }
    }

    private func refreshResults() {
        results = PaletteResults(items: items, query: query, scope: scope, contentRows: contentRows, probe: probe).following(results)
    }

    #if DEBUG
    private func recordProbe() {
        guard let probe else { return }
        probe.renders += 1
        if results.rows.isEmpty { probe.emptyRenders += 1 }
        if probe.firstRows == nil { probe.firstRows = results.rows; probe.firstLayout = results.layout }
        probe.rows = results.rows
        probe.layout = results.layout
        probe.query = query
        probe.scope = scope
        probe.highlight = highlight.index
        probe.searching = searching
    }
    #endif

    private func runSelected() {
        guard results.rows.indices.contains(highlight.index) else { return }
        run(results.rows[highlight.index])
    }

    // MARK: Content search (debounced, off-main)

    private func scheduleContentSearch() {
        contentSearchTask?.cancel()
        contentRows = []
        searching = false
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let contentSearch, trimmed.count >= PaletteContentSearch.minQueryLength else { return }
        let existing = Set(PaletteSearch.filter(items, query: trimmed, probe: probe).filter { $0.section == .agents }.map(\.id))
        searching = true
        contentSearchTask = Task {
            defer { if !Task.isCancelled { searching = false } }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let rows = await contentSearch(trimmed, existing)
            guard !Task.isCancelled else { return }
            contentRows = rows
        }
    }

    /// "Nothing here yet" with no query, "Searching conversations…" while transcripts are still
    /// being read, "No matches" once everything has answered.
    static func emptyText(query: String, searching: Bool) -> String {
        if query.isEmpty { return "Nothing here yet" }
        return searching ? "Searching conversations…" : "No matches"
    }
}

/// Opt-in, card-local diagnostics. No global recorder and no observable writes during rendering.
/// The callbacks drive the same bindings/submit path as the controls, without posting input.
final class PaletteDerivationProbe {
    #if DEBUG
    var cardInitializations = 0
    var derivations = 0
    var searches = 0
    var rankedItems = 0
    var renders = 0
    var emptyRenders = 0
    var firstRows: [PaletteItem]?
    var firstLayout: Int?
    var rows: [PaletteItem] = []
    var layout = 0
    var query = ""
    var scope: PaletteItem.Scope = .all
    var highlight = 0
    var searching = false
    var setQuery: (@MainActor (String) -> Void)?
    var setScope: (@MainActor (PaletteItem.Scope) -> Void)?
    var submit: (@MainActor () -> Void)?
    #endif
}

/// The results list for one query, scope, item list and set of transcript matches: the rows in
/// order and the list's entries, snippets already split around their match. Built when one of
/// those inputs changes, never on hover or selection.
struct PaletteResults {
    // Deliberately nonobservable: memoizing a pure result during a view read publishes nothing.
    // This is palette-local, not a cache across queries. Replacing results replaces the payload.
    private final class Content {
        typealias Value = (rows: [PaletteItem], entries: [PaletteEntry])
        private var build: (() -> Value)?
        lazy var value: Value = {
            let result = build?() ?? ([], [])
            build = nil // Release the source items/closure once the result exists.
            return result
        }()
        init(_ build: @escaping () -> Value) { self.build = build }
    }

    private let content: Content
    var rows: [PaletteItem] { content.value.rows }
    var entries: [PaletteEntry] { content.value.entries }
    /// Counts the changes to which rows the list shows and in what order: the key the list's
    /// motion watches, so a render never compares every row's id.
    private(set) var layout = 0

    init() { content = Content { ([], []) } }

    init(items: [PaletteItem], query: String, scope: PaletteItem.Scope, contentRows: [PaletteItem]) {
        self.init(items: items, query: query, scope: scope, contentRows: contentRows, probe: nil)
    }

    init(items: [PaletteItem], query: String, scope: PaletteItem.Scope, contentRows: [PaletteItem],
         probe: PaletteDerivationProbe?) {
        content = Content {
            #if DEBUG
            probe?.derivations += 1
            #endif
            let rows = PaletteSearch.filter(items, query: query, scope: scope, probe: probe) + (scope == .commands ? [] : contentRows)
            return (rows, PaletteEntry.entries(rows, highlighting: query))
        }
    }

    /// These results replacing `previous`: the same layout count while the same rows show.
    func following(_ previous: PaletteResults) -> PaletteResults {
        var next = self
        let same = entries.count == previous.entries.count && entries.map(\.id) == previous.entries.map(\.id)
        next.layout = same ? previous.layout : previous.layout + 1
        return next
    }
}

/// The palette's highlighted row, as an index into its results.
@MainActor @Observable
final class PaletteHighlight {
    private(set) var index = 0

    init(index: Int = 0) {
        self.index = index
    }

    /// Moves the highlight; a move to where it is already changes nothing.
    func move(to index: Int) {
        if self.index != index { self.index = index }
    }
}

/// A transcript match's `…snippet…`, split around the first occurrence of the query.
struct PaletteSnippet: Equatable {
    var before: String
    var match = ""
    var after = ""

    init(_ snippet: String, term: String) {
        let term = term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, let range = snippet.range(of: term, options: .caseInsensitive) else {
            before = snippet
            return
        }
        before = String(snippet[..<range.lowerBound])
        match = String(snippet[range])
        after = String(snippet[range.upperBound...])
    }
}

/// One line of the results list: a section header or a result, each a single lazy-stack view
/// with a stable id (a result's own id, so `scrollTo` finds it).
enum PaletteEntry: Identifiable, Equatable {
    case header(PaletteItem.Section)
    case row(index: Int, item: PaletteItem, snippet: PaletteSnippet?)

    var id: String {
        switch self {
        case .header(let section): "section.\(section.rawValue)"
        case .row(_, let item, _): item.id
        }
    }

    /// A result's place in the rows (what the highlight points at); nil for a header.
    var index: Int? {
        if case .row(let index, _, _) = self { return index }
        return nil
    }

    /// Headers go before the first row of each section; `index` is the row's place in `rows`.
    /// A row with a transcript snippet carries it split around `query`.
    static func entries(_ rows: [PaletteItem], highlighting query: String = "") -> [PaletteEntry] {
        var entries: [PaletteEntry] = []
        for (index, item) in rows.enumerated() {
            if index == 0 || rows[index - 1].section != item.section { entries.append(.header(item.section)) }
            entries.append(.row(index: index, item: item, snippet: item.contentSnippet.map { PaletteSnippet($0, term: query) }))
        }
        return entries
    }
}

/// One line of the results, always a single view (a lazy stack's fast path: rows off screen are
/// never built). Equal while its entry and highlight are, so moving the highlight redraws the
/// two rows it leaves and lands on.
private struct PaletteEntryRow: View, Equatable {
    let entry: PaletteEntry
    let highlighted: Bool
    let run: (PaletteItem) -> Void
    let hover: (Int) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.highlighted == rhs.highlighted
    }

    var body: some View {
        VStack(spacing: 0) {
            switch entry {
            case .header(let section):
                SHPaletteSectionHeader(section.title)
            case .row(let index, let item, let snippet):
                PaletteRow(item: item, selected: highlighted, snippet: snippet) { run(item) }
                    .onHover { if $0 { hover(index) } }
            }
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool
    /// The transcript snippet, with the matched term to emphasize.
    let snippet: PaletteSnippet?
    let action: () -> Void

    var body: some View {
        SHPaletteRow(item.title, systemImage: item.icon, context: item.subtitle, shortcut: item.shortcut,
                     highlighted: selected, iconColor: iconColor, action: action) {
            if let snippet {
                snippetText(snippet)
                    .font(Font.sh(.caption))
                    .lineLimit(1)
                    .padding(.leading, SHPaletteMetrics.titleInset)
                    .padding(.bottom, SH.Space.xs)
            }
        }
    }

    /// Subagent rows wear their run state's color; otherwise the row decides.
    private var iconColor: Color? {
        switch item.kind {
        case .child(_, let child), .remoteChild(_, _, let child):
            AgentState(nativeSubagentState(child)).color
        default:
            nil
        }
    }

    /// Snippet with the matched term emphasized; the rest stays dim.
    private func snippetText(_ snippet: PaletteSnippet) -> Text {
        let before = Text(snippet.before).foregroundStyle(Color.sh.textTertiary)
        guard !snippet.match.isEmpty else { return before }
        let match = Text(snippet.match).foregroundStyle(Color.sh.textPrimary).bold()
        let after = Text(snippet.after).foregroundStyle(Color.sh.textTertiary)
        return Text("\(before)\(match)\(after)")
    }
}

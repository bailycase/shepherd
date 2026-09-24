import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The ⌘K palette (Composer board, `.nwCommandPalette`): a 620pt card 18% from the top over the
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
                let matches = await Task.detached(priority: .userInitiated) {
                    PaletteContentSearch.search(query: query, agents: targets)
                }.value
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
    @State private var query = ""
    @State private var scope: PaletteItem.Scope = .all
    /// The highlighted row: ↑↓ and hover move it.
    @State private var highlight: PaletteHighlight
    @State private var contentRows: [PaletteItem] = []
    @State private var contentSearchTask: Task<Void, Never>?
    /// Filtered once per query, scope, items or transcript matches; hover and the arrow keys
    /// only move the highlight.
    @State private var results = PaletteResults()
    @FocusState private var fieldFocused: Bool
    @Environment(\.nwPaletteMaxListHeight) private var maxListHeight

    /// `highlight` lets a test move the highlight as ↑↓ and hover do.
    init(items: [PaletteItem], run: @escaping (PaletteItem) -> Void, close: @escaping () -> Void,
         contentSearch: ((String, Set<String>) async -> [PaletteItem])? = nil, initialQuery: String = "",
         highlight: PaletteHighlight? = nil) {
        self.items = items
        self.run = run
        self.close = close
        self.contentSearch = contentSearch
        self.initialQuery = initialQuery
        _highlight = State(initialValue: highlight ?? PaletteHighlight())
        // The first results are there as the card appears, so opening never animates the list.
        _results = State(initialValue: PaletteResults(items: items, query: initialQuery, scope: .all, contentRows: []))
    }

    var body: some View {
        NWPaletteCard {
            NWPaletteSearchRow("Search commands, agents, subagents…", text: $query, focus: $fieldFocused, submit: runSelected) {
                NWSegmentedPicker("Scope", selection: $scope, options: PaletteItem.Scope.allCases.map { ($0, $0.title) }, size: .s)
                    .nwHelp("Switch scope", shortcut: "⇥")
            }
        } results: {
            resultsList
        }
        // Rows arrive, leave, and reorder as the query or scope changes, and the card follows
        // their height; moving the highlight (↑↓, hover) changes no row, so it lands at once.
        .nwAnimation(.list, value: results.entries.map(\.id))
        .onAppear {
            query = initialQuery
            fieldFocused = true
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
        .onChange(of: items, initial: true) { refreshResults() }
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
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Eager: the card hugs its results up to the cap, which needs their real height
                // (a lazy stack reports only what it has realized). The list stays short.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(results.entries) { entry in
                        switch entry {
                        case .header(let section):
                            NWPaletteSectionHeader(section.title)
                                .nwTransition(.list)
                        case .row(let index, let item, let snippet):
                            PaletteRow(item: item, selected: index == highlight.index, snippet: snippet) { run(item) }
                                .onHover { if $0 { highlight.move(to: index) } }
                                .nwTransition(.list)
                        }
                    }
                    if results.rows.isEmpty {
                        Text(query.isEmpty ? "Nothing here yet" : "No matches")
                            .font(Font.nw(.caption))
                            .foregroundStyle(Color.nw.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: NWPaletteMetrics.sectionHeight * 2)
                            .nwTransition(.content)
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
        results = PaletteResults(items: items, query: query, scope: scope, contentRows: contentRows)
    }

    private func runSelected() {
        guard results.rows.indices.contains(highlight.index) else { return }
        run(results.rows[highlight.index])
    }

    // MARK: Content search (debounced, off-main)

    private func scheduleContentSearch() {
        contentSearchTask?.cancel()
        contentRows = []
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let contentSearch, trimmed.count >= PaletteContentSearch.minQueryLength else { return }
        let existing = Set(PaletteSearch.filter(items, query: trimmed).filter { $0.section == .agents }.map(\.id))
        contentSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let rows = await contentSearch(trimmed, existing)
            guard !Task.isCancelled else { return }
            contentRows = rows
        }
    }
}

/// The results list for one query, scope, item list and set of transcript matches: the rows in
/// order and the list's entries, snippets already split around their match. Built when one of
/// those inputs changes, never on hover or selection.
struct PaletteResults {
    var rows: [PaletteItem] = []
    var entries: [PaletteEntry] = []

    init() {}

    init(items: [PaletteItem], query: String, scope: PaletteItem.Scope, contentRows: [PaletteItem]) {
        rows = PaletteSearch.filter(items, query: query, scope: scope) + (scope == .commands ? [] : contentRows)
        entries = PaletteEntry.entries(rows, highlighting: query)
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
enum PaletteEntry: Identifiable {
    case header(PaletteItem.Section)
    case row(index: Int, item: PaletteItem, snippet: PaletteSnippet?)

    var id: String {
        switch self {
        case .header(let section): "section.\(section.rawValue)"
        case .row(_, let item, _): item.id
        }
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

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool
    /// The transcript snippet, with the matched term to emphasize.
    let snippet: PaletteSnippet?
    let action: () -> Void

    var body: some View {
        NWPaletteRow(item.title, systemImage: item.icon, context: item.subtitle, shortcut: item.shortcut,
                     highlighted: selected, iconColor: iconColor, action: action) {
            if let snippet {
                snippetText(snippet)
                    .font(Font.nw(.caption))
                    .lineLimit(1)
                    .padding(.leading, NWPaletteMetrics.titleInset)
                    .padding(.bottom, NW.Space.xs)
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
        let before = Text(snippet.before).foregroundStyle(Color.nw.textTertiary)
        guard !snippet.match.isEmpty else { return before }
        let match = Text(snippet.match).foregroundStyle(Color.nw.textPrimary).bold()
        let after = Text(snippet.after).foregroundStyle(Color.nw.textTertiary)
        return Text("\(before)\(match)\(after)")
    }
}

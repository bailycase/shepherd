import SwiftUI
import ShepherdDesign
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The ⌘K palette (spec §12): a 640pt card 120pt from the top over a scrim. A 56pt search row
/// with All · Commands · Agents scope pills, then results grouped under caps headers —
/// Commands, This thread, Subagents, and Agents/Spaces once there is a query. Rows show
/// a stroke icon, the label, dim context, and the real shortcut as keycaps.
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
    @State private var selectedIndex = 0
    @State private var contentRows: [PaletteItem] = []
    @State private var contentSearchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private var results: [PaletteItem] {
        PaletteSearch.filter(items, query: query, scope: scope) + (scope == .commands ? [] : contentRows)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            Tokens.border.frame(height: 1)
            resultsList
        }
        .frame(width: Metrics.paletteWidth)
        .background(Tokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.xxl))
        .overlay { RoundedRectangle(cornerRadius: Radius.xxl).strokeBorder(Tokens.borderStrong, lineWidth: 1) }
        .shadow(color: Tokens.menuShadow, radius: 32, y: 16)
        .onAppear {
            query = initialQuery
            fieldFocused = true
        }
        .onChange(of: query) {
            selectedIndex = 0
            scheduleContentSearch()
        }
        .onChange(of: scope) { selectedIndex = 0 }
        .onKeyPress(.upArrow) {
            selectedIndex = max(0, selectedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedIndex = min(max(0, results.count - 1), selectedIndex + 1)
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

    // MARK: Search

    private var searchRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Tokens.textTertiary)
            TextField("Search commands, agents, subagents…", text: $query)
                .textFieldStyle(.plain)
                .font(Fonts.sans(16))
                .foregroundStyle(Tokens.text)
                .focused($fieldFocused)
                .onSubmit(runSelected)
            HStack(spacing: 2) {
                ForEach(PaletteItem.Scope.allCases, id: \.self) { option in
                    Button { scope = option } label: {
                        Text(option.title)
                            .font(Fonts.sans(12.5, option == scope ? .semibold : .regular))
                            .foregroundStyle(option == scope ? Tokens.primaryLabel : Tokens.textSecondary)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(option == scope ? Tokens.primaryFill : .clear, in: RoundedRectangle(cornerRadius: Radius.sm))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == scope ? .isSelected : [])
                }
            }
            .help("⇥ switches scope")
        }
        .padding(.horizontal, 18)
        .frame(height: Metrics.paletteSearchHeight)
    }

    // MARK: Results

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let rows = results
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || rows[index - 1].section != item.section {
                            Text(item.section.title.uppercased())
                                .font(Fonts.sectionSmall)
                                .tracking(0.6)
                                .foregroundStyle(Tokens.textMuted)
                                .padding(.horizontal, 12)
                                .padding(.top, index == 0 ? 8 : 12)
                                .padding(.bottom, 4)
                        }
                        PaletteRow(item: item, selected: index == selectedIndex,
                                   highlightTerm: item.contentSnippet != nil ? query : nil) { run(item) }
                            .id(item.id)
                            .onHover { if $0 { selectedIndex = index } }
                    }
                    if rows.isEmpty {
                        Text(query.isEmpty ? "Nothing here yet" : "No matches")
                            .font(Fonts.caption)
                            .foregroundStyle(Tokens.textMuted)
                            .frame(maxWidth: .infinity)
                            .frame(height: Metrics.paletteRowHeight)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: Metrics.paletteRowHeight * 14)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selectedIndex) {
                if results.indices.contains(selectedIndex) { proxy.scrollTo(results[selectedIndex].id) }
            }
        }
    }

    private func runSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        run(results[selectedIndex])
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

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool
    /// Query term to emphasize inside the content snippet.
    var highlightTerm: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(iconColor)
                        .frame(width: 18)
                    Text(item.title)
                        .font(Fonts.bodySmall)
                        .foregroundStyle(Tokens.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(Fonts.description)
                            .foregroundStyle(Tokens.textMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 12)
                    if let shortcut = item.shortcut { Keycaps(chord: shortcut) }
                }
                if let snippet = item.contentSnippet {
                    snippetText(snippet)
                        .font(Fonts.caption)
                        .lineLimit(1)
                        .padding(.leading, 28)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: Metrics.paletteRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Tokens.accentBg : .clear, in: RoundedRectangle(cornerRadius: Radius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Subagent rows wear their run state's color; the highlighted row's icon turns accent.
    private var iconColor: Color {
        switch item.kind {
        case .child(_, let child), .remoteChild(_, _, let child):
            SubagentStyle.color(nativeSubagentState(child))
        default:
            selected ? Tokens.accent : Tokens.textTertiary
        }
    }

    /// Snippet with the matched term emphasized; the rest stays dim.
    private func snippetText(_ snippet: String) -> Text {
        guard let term = highlightTerm?.trimmingCharacters(in: .whitespaces), !term.isEmpty,
              let range = snippet.range(of: term, options: .caseInsensitive) else {
            return Text(snippet).foregroundStyle(Tokens.textMuted)
        }
        let before = Text(snippet[snippet.startIndex..<range.lowerBound]).foregroundStyle(Tokens.textMuted)
        let match = Text(snippet[range]).foregroundStyle(Tokens.text).bold()
        let after = Text(snippet[range.upperBound...]).foregroundStyle(Tokens.textMuted)
        return Text("\(before)\(match)\(after)")
    }
}

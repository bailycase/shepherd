import SwiftUI
import ShepherdCore
import ShepherdProtocol

/// The ⌘K palette, drawn to the design mock: floating over the workspace,
/// `>` prompt with a dim "commands" tag, sectioned rows (commands · threads ·
/// shells · spaces · subagents) with trailing keycaps, `⏎ select · esc` footer.
///
/// Draggable by its prompt row; the offset from the top-center anchor
/// persists in UserDefaults, so the palette reopens where the user left it
/// across resizes (the anchor scales with the window, the offset does not).
///
/// Queries of 3+ characters also search agents' session transcripts in the
/// background (bounded tail scan, debounced), so a thread is findable by
/// remembered conversation text; those rows show a dim `…snippet…` line.
struct CommandPaletteView: View {
    var vm: ShepherdViewModel
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool
    @State private var contentRows: [PaletteItem] = []
    @State private var contentSearchTask: Task<Void, Never>?
    @AppStorage("shepherd.palette.offsetX") private var offsetX = 0.0
    @AppStorage("shepherd.palette.offsetY") private var offsetY = 0.0
    @State private var dragStart: CGSize?

    private var results: [PaletteItem] {
        // Fuzzy (content) matches trail everything in their own section.
        PaletteSearch.filter(vm.paletteItems, query: query) + contentRows
    }

    var body: some View {
        VStack(spacing: 0) {
            promptRow
            Rectangle().fill(Tokens.separator).frame(height: 1)
            resultsList
            Rectangle().fill(Tokens.separator).frame(height: 1)
            footer
        }
        .frame(width: 460)
        .background(Tokens.paletteBg)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Tokens.chipBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .offset(x: offsetX, y: offsetY)
        .onAppear { fieldFocused = true }
        .onChange(of: query) {
            selectedIndex = 0
            scheduleContentSearch()
            vm.paletteVisibleRows = results
        }
        .onChange(of: contentRows.count) { vm.paletteVisibleRows = results }
        .onAppear { vm.paletteVisibleRows = results }
        .onDisappear {
            contentSearchTask?.cancel()
            vm.paletteVisibleRows = []
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(0, selectedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedIndex = min(max(0, results.count - 1), selectedIndex + 1)
            return .handled
        }
        .onKeyPress(.escape) {
            vm.showCommandPalette = false
            return .handled
        }
        // ⌘digit quick-pick is routed through the menu-bar shortcuts (they
        // fire before local key handlers); see runPaletteQuickPick.
    }

    // MARK: Prompt (also the drag handle)

    private var promptRow: some View {
        HStack(spacing: 8) {
            Text(">")
                .font(Fonts.mono(13))
                .foregroundStyle(Tokens.focusAccent)
            TextField("", text: $query)
                .textFieldStyle(.plain)
                .font(Fonts.mono(13))
                .foregroundStyle(Tokens.textPrimary)
                .focused($fieldFocused)
                .onSubmit(runSelected)
            Text("commands")
                .font(Fonts.mono(10.5))
                .foregroundStyle(Tokens.textDim)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    let base = dragStart ?? CGSize(width: offsetX, height: offsetY)
                    dragStart = base
                    offsetX = base.width + value.translation.width
                    offsetY = base.height + value.translation.height
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) {
            // Double-click the handle to reset to center.
            offsetX = 0
            offsetY = 0
        }
    }

    // MARK: Results

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    let rows = results
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || rows[index - 1].section != item.section {
                            PaletteSectionHeader(title: item.section.title)
                        }
                        PaletteRow(
                            item: item,
                            selected: index == selectedIndex,
                            highlightTerm: item.contentSnippet != nil ? query : nil,
                            // Hold ⌘: the first nine rows advertise their
                            // instant pick, mirroring the sidebar's ⌘1–9.
                            quickPick: vm.paletteModifierHeld && index < 9 ? "⌘\(index + 1)" : nil
                        ) {
                            vm.runPaletteItem(item)
                        }
                        .id(item.id)
                    }
                    if rows.isEmpty {
                        Text("no matches")
                            .font(Fonts.mono(11))
                            .foregroundStyle(Tokens.textDim)
                            .frame(height: 30)
                    }
                }
            }
            .frame(maxHeight: 10 * 30)
            .onChange(of: selectedIndex) {
                if results.indices.contains(selectedIndex) {
                    proxy.scrollTo(results[selectedIndex].id)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("⏎ select")
                .font(Fonts.mono(10.5))
                .foregroundStyle(Tokens.textHint)
            Spacer()
            Text("esc")
                .font(Fonts.mono(10.5))
                .foregroundStyle(Tokens.textHint)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    private func runSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        vm.runPaletteItem(results[selectedIndex])
    }

    // MARK: Content search (debounced, off-main)

    private func scheduleContentSearch() {
        contentSearchTask?.cancel()
        contentRows = []
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= PaletteContentSearch.minQueryLength else { return }
        let targets = vm.paletteSearchTargets
        let existing = Set(
            PaletteSearch.filter(vm.paletteItems, query: query)
                .filter { $0.section == .threads }
                .map(\.id)
        )
        contentSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                PaletteContentSearch.search(query: trimmed, agents: targets)
            }.value
            guard !Task.isCancelled else { return }
            contentRows = vm.paletteContentRows(matches: matches, excluding: existing)
        }
    }
}

private struct PaletteSectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(Fonts.mono(9.5, .semibold))
                .tracking(0.74)
                .foregroundStyle(Tokens.textDim)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 7)
        .padding(.bottom, 3)
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool
    /// Query term to emphasize inside the content snippet.
    var highlightTerm: String?
    /// ⌘-held pick hint ("⌘3"); shown in place of the item's own shortcut.
    var quickPick: String?
    let action: () -> Void
    @State private var hovering = false

    /// Snippet with the matched term brightened; the rest stays dim.
    private func snippetText(_ snippet: String) -> Text {
        guard let term = highlightTerm?.trimmingCharacters(in: .whitespaces),
              !term.isEmpty,
              let range = snippet.range(of: term, options: .caseInsensitive) else {
            return Text(snippet).foregroundStyle(Tokens.textDim)
        }
        return Text(snippet[snippet.startIndex..<range.lowerBound]).foregroundStyle(Tokens.textDim)
            + Text(snippet[range]).foregroundStyle(Tokens.textPrimary).bold()
            + Text(snippet[range.upperBound...]).foregroundStyle(Tokens.textDim)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(Fonts.mono(12, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Tokens.textPrimary : Tokens.textSecondary)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(Tokens.textDim)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if let quickPick {
                    Text(quickPick)
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(Tokens.textTertiary)
                        .transition(.opacity)
                } else if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(Tokens.textMetadata)
                }
            }
            if let snippet = item.contentSnippet {
                snippetText(snippet)
                    .font(Fonts.mono(10))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Tokens.rowSelection : hovering ? Tokens.rowHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

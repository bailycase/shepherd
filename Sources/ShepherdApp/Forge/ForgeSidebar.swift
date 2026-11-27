import AppKit
import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSidebar

// MARK: The destination's list

/// The sidebar while Issues & PRs is on screen (PRReview, IssueReview, PRReviewEmpty,
/// PRReviewTeam): back, the title, the repository picker and More; the Issues | Pull requests
/// switch; Search or paste a link; then the sections, one lazy list.
struct ForgeSidebarPanel: View {
    var vm: ShepherdViewModel

    var body: some View {
        let store = vm.forgeStore
        VStack(alignment: .leading, spacing: 0) {
            ForgeSidebarHeader(vm: vm, store: store)
            ForgeKindSwitch(store: store)
                .padding(.horizontal, AppLayout.forgeSidebarControlInset)
                .padding(.top, SH.Space.m)
            ForgeSearchField(store: store)
                .padding(.horizontal, AppLayout.forgeSidebarControlInset)
                .padding(.top, SH.Space.m)
            ForgeFilterBar(store: store)
                .padding(.horizontal, SH.Space.s)
                .padding(.top, SH.Space.s)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.items.isEmpty, !store.loadingKinds.isEmpty || store.searching {
                        SHLoadingRows().padding(.top, SH.Space.l)
                    }
                    ForEach(store.items) { item in
                        ForgeListItemView(item: item, open: { ref in Task { await store.open(ref) } },
                                          toggle: { id in Task { await store.toggleSection(id) } },
                                          more: { Task { await store.loadBrowse(more: true) } })
                            .equatable()
                    }
                }
                .padding(.bottom, SH.Space.m)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, AppLayout.sidebarPadding)
    }
}

/// The board's one row (back, title, repository, More) while it fits; in a narrower sidebar, or
/// at a larger text size, the repository and More take their own row under the title.
private struct ForgeSidebarHeader: View {
    var vm: ShepherdViewModel
    let store: ForgeStore
    @State private var newIssue = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SH.Space.xs) {
                back
                title
                Spacer(minLength: SH.Space.s)
                repository.fixedSize()
                more
            }
            // More acts on the repository (Refresh, Open on GitHub), so it moves down beside it and
            // the title keeps its whole width at the larger text size.
            VStack(alignment: .leading, spacing: SH.Space.s) {
                HStack(spacing: SH.Space.xs) {
                    back
                    title
                }
                HStack(spacing: SH.Space.xs) {
                    repository
                    more
                }
            }
        }
        .padding(.leading, SH.Space.xs)
        .padding(.trailing, SH.Space.xs)
        .frame(minHeight: AppLayout.forgeSidebarHeaderHeight)
        .sheet(isPresented: $newIssue) { ForgeNewIssueSheet(store: store) { newIssue = false } }
    }

    private var back: some View {
        Button { vm.leaveForge() } label: { Image(systemName: "chevron.left") }
            .buttonStyle(.shIcon(size: SH.Height.controlS))
            .help("Back to threads")
            .accessibilityLabel("Back to threads")
    }

    private var title: some View {
        Text("Issues & PRs")
            .font(.sh(.body, weight: .semibold))
            .foregroundStyle(Color.sh.textPrimary)
            .lineLimit(1)
            .layoutPriority(1)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var repository: some View {
        if !store.repos.isEmpty {
            // SHPopupMenu always sizes to its value; the stacked row needs a label that fills it.
            Menu {
                Button("All repositories") { Task { await store.selectRepo(nil) } }
                Divider()
                ForEach(store.repos) { repo in
                    Button(repo.nameWithOwner) { Task { await store.selectRepo(repo.nameWithOwner) } }
                }
            } label: {
                ForgeMenuLabel(title: store.repo == nil ? "All" : store.repoName, mono: store.repo != nil)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            // A native menu button names itself by its tooltip.
            .help("Repository: \(store.repo ?? "All repositories")")
            .accessibilityLabel("Repository")
            .accessibilityValue(store.repo ?? "All repositories")
        }
    }

    private var more: some View {
        Menu {
            Button("New Issue…") { newIssue = true }.disabled(store.repos.isEmpty)
            Button("Refresh") { Task { await store.refresh() } }
            if let repo = store.repo, let url = URL(string: "https://github.com/\(repo)") {
                Button("Open \(store.repoName) on GitHub") { NSWorkspace.shared.open(url) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.shIcon(size: SH.Height.controlS))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }
}

/// Issues | Pull requests, each with its count: the sidebar's own wide segmented track. A narrow
/// sidebar shortens "Pull requests" to "PRs" rather than wrapping or clipping it.
private struct ForgeKindSwitch: View {
    @Bindable var store: ForgeStore

    var body: some View {
        ViewThatFits(in: .horizontal) {
            track(pullRequests: "Pull requests")
            track(pullRequests: "PRs")
        }
    }

    private func track(pullRequests: String) -> some View {
        HStack(spacing: SH.Space.xxs) {
            segment(.issue, "Issues", spoken: "Issues")
            segment(.pullRequest, pullRequests, spoken: "Pull requests")
        }
        .padding(SH.Space.xxs)
        .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .frame(height: AppLayout.forgeSwitchHeight)
    }

    private func segment(_ kind: ForgeKind, _ title: String, spoken: String) -> some View {
        let selected = store.kind == kind
        let count = store.counts[kind]
        let shape = RoundedRectangle(cornerRadius: SH.Radius.s)
        return Button { store.kind = kind } label: {
            HStack(spacing: SH.Space.s) {
                Text(title).font(.sh(.ui, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.sh.textPrimary : Color.sh.textSecondary)
                if let count { Text("\(count)").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary) }
            }
            .fixedSize()
            .padding(.horizontal, SH.Space.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { if selected { Color.clear.shLift(shape) } }
            .contentShape(Rectangle())
            .shFocusRing(radius: SH.Radius.s)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(spoken), \($0)" } ?? spoken)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A menu's words and its small chevron (the boards' `.gch-menu`, `.gch-repo`).
struct ForgeMenuLabel: View {
    let title: String
    var mono = false
    var dim = true
    var weight: Font.Weight = .regular

    var body: some View {
        HStack(spacing: SH.Space.xs) {
            Text(title)
                .font(mono ? .shMono(SHTextStyle.caption.size) : .sh(.ui, weight: weight))
                .foregroundStyle(dim ? Color.sh.textSecondary : Color.sh.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.shSans(AppLayout.forgeChevron, .semibold))
                .foregroundStyle(Color.sh.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SH.Space.s)
        .frame(height: SH.Height.controlS)
        .contentShape(Rectangle())
    }
}

private struct ForgeSearchField: View {
    @Bindable var store: ForgeStore

    private static let full = "Search or paste a link"

    /// The board's placeholder while the field can show all of it; a narrower field (or a larger
    /// text size) says "Search" rather than cutting the words off. The hidden copy is what's measured.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            ZStack {
                Text(Self.full).font(.sh(.ui)).padding(.horizontal, AppLayout.forgeSearchChrome).fixedSize().hidden()
                field(Self.full)
            }
            field("Search")
        }
        .help("Search issues and pull requests, or paste a GitHub link")
        .onSubmit { Task { await store.submitSearch() } }
    }

    private func field(_ placeholder: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
        return HStack(spacing: SH.Space.m) {
            Image(systemName: "magnifyingglass")
                .font(.shSans(SHDesignsHomeMetrics.filterGlyph, .medium))
                .foregroundStyle(Color.sh.textTertiary)
                .accessibilityHidden(true)
            TextField("", text: $store.query, prompt: Text(placeholder).foregroundStyle(Color.sh.textTertiary))
                .textFieldStyle(.plain)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(Color.sh.textPrimary)
                .tint(Color.sh.lantern)
                .focused($focused)
                .accessibilityLabel(Self.full)
            if !store.query.isEmpty {
                Button { store.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.shSans(SHDesignsHomeMetrics.filterGlyph)).foregroundStyle(Color.sh.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, AppLayout.forgeSearchPadding)
        .frame(height: SH.Height.controlM)
        .background(Color.sh.bgHover, in: shape)
        .overlay { Color.clear.shFocusRing(focused, radius: SH.Radius.m).allowsHitTesting(false) }
    }

    @FocusState private var focused: Bool
}

/// One element of the list, redrawn only when its values change.
private struct ForgeListItemView: View, Equatable {
    let item: ForgeListItem
    let open: (ForgeItemRef) -> Void
    let toggle: (ForgeSectionID) -> Void
    let more: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.item == b.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch item {
            case .header(_, let title, let count, let section):
                SHSidebarSectionHeader(title, count: count, isExpanded: true) { if let section { toggle(section) } }
                    .disabled(section == nil)
            case .row(let row):
                ForgeListRowView(row: row) { open(row.ref) }
            case .more(let id, let title, let loading):
                Button { toggle(id) } label: {
                    HStack(spacing: SH.Space.s) {
                        Text(title).shShimmer(active: loading)
                        Spacer(minLength: SH.Space.xs)
                        if !loading {
                            Image(systemName: "chevron.right").font(.shSans(AppLayout.forgeChevron, .semibold))
                        }
                    }
                    .font(.sh(.caption, weight: .medium))
                    .foregroundStyle(Color.sh.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, SH.Space.m)
                .frame(height: SH.Height.controlM)
                .padding(.top, SH.Space.l)
                .accessibilityLabel("\(title), \(loading ? "loading" : "show")")
            case .loadMore(let loading):
                Button(action: more) {
                    HStack(spacing: SH.Space.s) {
                        Text("Load more").shShimmer(active: loading)
                    }
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(Color.sh.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(loading)
                .padding(.horizontal, SH.Space.m)
                .padding(.vertical, SH.Space.m)
                .onAppear { if !loading { more() } }
            case .empty(let title, let detail):
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    Text(title).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                    Text(detail).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, SH.Space.m)
                .padding(.top, AppLayout.forgeSectionTop + SH.Space.m)
                .padding(.bottom, SH.Space.l)
            case .message(let text):
                Text(text).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    .padding(.horizontal, SH.Space.m)
                    .padding(.top, AppLayout.forgeSectionTop)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A pull request's or issue's row (the boards' `.gch-fr`): its title (two lines at most) over
/// where, who and when, with how it stands at the trailing edge ("Changes", "Passed", "Draft").
private struct ForgeListRowView: View {
    let row: ForgeRow
    let open: () -> Void

    var body: some View {
        let sh = Color.sh
        Button(action: open) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(row.title)
                    .shText(.ui)
                    .fontWeight(row.selected ? .medium : .regular)
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: SH.Space.m) {
                    Text(row.byline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.word).lineLimit(1).fixedSize().foregroundStyle(wordColor)
                }
                .shText(.caption)
                .foregroundStyle(sh.textTertiary)
            }
            .padding(.horizontal, SH.Space.m)
            .padding(.top, SH.Space.s)
            .padding(.bottom, AppLayout.forgeRowBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.shRow(selected: row.selected, radius: SH.Radius.m))
        .accessibilityLabel("\(row.title), #\(row.ref.number), \(row.word), \(row.byline)")
        .accessibilityAddTraits(row.selected ? .isSelected : [])
        .contextMenu {
            Button("Open on GitHub") { ShepherdViewModel.openForgeURL(row.ref) }
            Button("Copy Link") { ShepherdViewModel.copyForgeLink(row.ref) }
        }
    }

    private var wordColor: Color {
        switch row.wordTone {
        case .attention: Color.sh.lanternText
        case .failed: Color.sh.failed
        case .secondary: Color.sh.textSecondary
        case .quiet: Color.sh.textTertiary
        }
    }
}

// MARK: Pinned (PRSidebarPinned)

/// A pin's row: opens the item in Issues & PRs; its menu unpins it; resting the pointer on it
/// shows what it is waiting on.
struct SidebarForgePinRow: View {
    var vm: ShepherdViewModel
    let pin: SidebarForgePin
    @State private var preview = false
    @State private var hover: Task<Void, Never>?

    var body: some View {
        SHSidebarRow(pin.title, leading: .glyph(ForgeSymbol.kind(pin.ref.kind), attention: pin.tagTone == .attention),
                     accessory: .text(pin.tag, tone: pin.tagTone == .failed ? .attention : pin.tagTone?.agentState))
            .help(pin.title)
            .sidebarTapRow { preview = false; vm.openForgeItem(pin.ref) }
            .onHover { inside in
                hover?.cancel()
                guard inside else { preview = false; return }
                hover = Task {
                    try? await Task.sleep(for: AppLayout.forgePinPreviewDelay)
                    if !Task.isCancelled { preview = true }
                }
            }
            .popover(isPresented: $preview, arrowEdge: .trailing) { SidebarForgePinPreview(pin: pin) }
            .accessibilityLabel("\(pin.title), \(pin.place), \(pin.tag)")
            .contextMenu {
                Button("Open in Issues & PRs") { vm.openForgeItem(pin.ref) }
                Button("Open on GitHub") { ShepherdViewModel.openForgeURL(pin.ref) }
                Button("Copy Link") { ShepherdViewModel.copyForgeLink(pin.ref) }
                Divider()
                Button("Unpin") { vm.unpinForgeItem(pin.ref, title: pin.title) }
            }
    }
}

/// The hover preview (PRSidebarPinned, the boards' `.gch-pin`): the state chip and place, the title, what it waits
/// on, and how to act on it.
struct SidebarForgePinPreview: View {
    let pin: SidebarForgePin

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.m) {
                if let badge = pin.badge { ForgeStateTag(label: badge.label, tone: badge.tone, plain: true) }
                Text(pin.place).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary)
            }
            Text(pin.title).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, SH.Space.s)
            ForEach(pin.lines, id: \.text) { line in
                HStack(spacing: SH.Space.s) {
                    Group {
                        if let symbol = line.symbol ?? (line.text.hasPrefix("Thread:") ? ForgeSymbol.comment : nil) {
                            Image(systemName: symbol).font(.sh(.caption))
                        } else {
                            ForgeDot(tone: line.tone)
                        }
                    }
                    .frame(width: AppLayout.forgeAvatarSize - SH.Space.xxs)
                    Text(line.text).font(.sh(.ui, weight: .regular))
                }
                .foregroundStyle(line.symbol == "xmark" ? Color.sh.failed : Color.sh.textSecondary)
                .padding(.top, SH.Space.s)
            }
            Text("Click to open · right-click to unpin")
                .font(.sh(.caption))
                .foregroundStyle(Color.sh.textTertiary)
                .padding(.top, SH.Space.m + SH.Space.xxs)
                .padding(.bottom, SH.Space.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { SHHairline() }
                .padding(.top, SH.Space.m + SH.Space.xxs)
        }
        .padding(.horizontal, AppLayout.forgeBannerSide)
        .padding(.top, SH.Space.l)
        .padding(.bottom, SH.Space.m + SH.Space.xxs)
        .frame(width: AppLayout.forgePinPreviewWidth, alignment: .leading)
        .background(Color.sh.bgRaised)
    }
}

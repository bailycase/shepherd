import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Issues & PRs (MobileIPList, MobileIssueList, MobilePRStates; iPadIPReview, iPadIssue,
/// iPadPRStates; DuoBookPR, DuoClosedIPList): the title with the repository picker, Issues | Pull
/// requests, the search field (a pasted link opens its item), then the list's sections. iPhone
/// pushes an item; iPad shows the chosen one beside the list, and half open the list ends at the
/// fold. An older host says to update the Mac.
struct ForgeListScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VerticalBars { verticalBars in content(verticalBars: verticalBars) }
    }

    @ViewBuilder private func content(verticalBars: Bool) -> some View {
        let store = ForgeStore.of(hosts)
        let pad = sizeClass == .regular
        Group {
            if pad {
                ForgeSplit(store: store, verticalBars: verticalBars)
            } else {
                ForgeListColumn(store: store, chosen: nil, controlsInBar: true) { ForgeHooks.open($0, store: store, navigator: navigator) }
            }
        }
        .background(Color.sh.bgWindow)
        .task(id: store.sessionsKey) { await store.loadRepos() }
        .task(id: store.listKey(.issue)) { await store.loadLists() }
        .task(id: store.browseID) { await store.loadBrowse() }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Issues & PRs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        // iPad draws its own heads over the list and the item (iPadIPReview); where the bars run
        // down the side (iPhone Duo) Back and ••• stay the system's.
        .toolbar(pad && !verticalBars ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if verticalBars {
                // Down the side (DuoClosedIPList) the bar holds Back and •••: the repository, New issue and Refresh are in it.
                ToolbarOverflowMenu {
                    ForgeRepoMenuItems(store: store)
                    ForgeNewIssueButton(store: store, inMenu: true)
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await store.loadRepos(); await store.loadLists() }
                    }
                }
            } else if !pad {
                // The repository and New issue in the bar's own capsule (MobileIPList).
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ForgeRepoPicker(store: store)
                    ForgeNewIssueButton(store: store)
                }
            }
        }
    }
}

/// The list column: its head, the switch, the field, and the sections.
struct ForgeListColumn: View {
    let store: ForgeStore
    /// The row the iPad shows beside the list.
    let chosen: ForgeItemKey?
    /// The repository and New issue are the screen's bar's; otherwise the column's head draws them.
    var controlsInBar = false
    let open: (ForgeItemKey) -> Void
    /// Back, where the column stands alone under a hidden bar (an iPad window too narrow for the
    /// item beside the list).
    var back: (() -> Void)? = nil
    @State private var query = ""
    @FocusState private var searching: Bool

    var body: some View {
        let kind = Binding(get: { store.kind }, set: { kind in
            store.kind = kind
            store.clearSearch()
            query = ""
        })
        @Bindable var store = store
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                head
                ReviewSegmented(selection: kind, options: [
                    .init(value: .issue, title: "Issues", note: store.list(.issue)?.value.map { "\($0.count)" }),
                    .init(value: .pullRequest, title: "Pull requests", note: store.list(.pullRequest)?.value.map { "\($0.count)" }),
                ])
                SHTouchSearchField("Search or paste a link", text: $query, focus: $searching) {
                    Task { if let key = await store.submit(query) { query = ""; open(key) } }
                }
                .onChange(of: query) { _, text in if text.isEmpty { store.clearSearch() } }
                if store.canBrowse { ForgeFilterBar(store: store) }
                ForgeListBody(store: store, chosen: chosen, plain: !controlsInBar, open: open)
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await store.loadRepos()
            await store.loadLists()
            await store.loadBrowse()
        }
        .sheet(isPresented: $store.composingIssue) { ForgeNewIssueSheet(store: store, opened: open) }
    }

    /// The title (MobileIPList's 28pt); on iPad, with Back and the capsule of the repository and New issue.
    private var head: some View {
        HStack(spacing: SH.Space.m) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.sh(.headline))
                        .foregroundStyle(Color.sh.textPrimary)
                        .frame(width: SH.Height.touch, height: SH.Height.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            Text("Issues & PRs")
                .font(.shSans(controlsInBar ? MobileLayout.forgeListTitle : MobileLayout.touchTitleFont, .bold))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: SH.Space.m)
            if !controlsInBar {
                HStack(spacing: 0) {
                    ForgeRepoPicker(store: store)
                    ForgeNewIssueButton(store: store)
                }
                .padding(.horizontal, SH.Space.xs)
                .glassEffect(.regular, in: Capsule())
            }
        }
        .padding(.horizontal, SH.Space.xs)
    }
}

/// New issue: the capsule's second button.
struct ForgeNewIssueButton: View {
    let store: ForgeStore
    /// In a menu it is a titled item; in the bar, its glyph.
    var inMenu = false

    var body: some View {
        if store.browseHost != nil {
            let button = Button("New issue", systemImage: "square.and.pencil") { store.composingIssue = true }
                .tint(Color.sh.textPrimary)
                .disabled(store.repos.isEmpty)
            if inMenu { button } else { button.labelStyle(.iconOnly) }
        }
    }
}

/// What the list holds now: why there is nothing, a search's results, or the sections.
private struct ForgeListBody: View {
    let store: ForgeStore
    let chosen: ForgeItemKey?
    /// iPad's list: rows on the page with a rule between them, the chosen one filled, not cards.
    let plain: Bool
    let open: (ForgeItemKey) -> Void

    var body: some View {
        if store.repos.isEmpty {
            if store.reposLoading {
                SHLoadingRows().frame(height: MobileLayout.rowHeight * 2)
            } else if let error = store.reposError {
                ForgeErrorState(error: error) { Task { await store.loadRepos() } }
            } else if !store.olderHosts.isEmpty, store.servingHosts.isEmpty {
                SHEmptyState(Text("Update Shepherd on the Mac"),
                             message: "\(store.olderHosts.joined(separator: ", ")) runs a Shepherd from before Issues & PRs. Update it to see its issues and pull requests here.")
                    .frame(maxWidth: .infinity).padding(.top, SH.Space.xxl)
            } else if store.servingHosts.isEmpty {
                SHEmptyState(Text("No host connected"), message: "Connect to a Mac running Shepherd to see its repositories' issues and pull requests.")
                    .frame(maxWidth: .infinity).padding(.top, SH.Space.xxl)
            } else {
                SHEmptyState(Text("No GitHub repositories"),
                             message: "Add a space whose origin is on GitHub, on the Mac, and its issues and pull requests show here.")
                    .frame(maxWidth: .infinity).padding(.top, SH.Space.xxl)
            }
        } else if let results = store.results {
            if let model = results.value {
                if model.sections.allSatisfy(\.rows.isEmpty) {
                    Text(store.filter.text.isEmpty && store.resultsQuery.isEmpty ? "Nothing matches these filters." : "No matches.")
                        .shText(.caption).foregroundStyle(Color.sh.textTertiary).padding(.horizontal, SH.Space.xs)
                } else {
                    sections(model, emptyClosed: false)
                }
                if store.resultsNext != nil {
                    Button { Task { await store.loadBrowse(more: true) } } label: {
                        HStack(spacing: SH.Space.s) {
                            Text("Load more").shShimmer(active: store.loadingMore)
                        }
                        .font(.sh(.ui, weight: .medium))
                        .foregroundStyle(Color.sh.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: SH.Height.touch)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.loadingMore)
                    .onAppear { Task { await store.loadBrowse(more: true) } }
                }
            } else if let error = results.error {
                ForgeErrorState(error: error) {}
            } else {
                SHLoadingRows().frame(height: MobileLayout.rowHeight * 2)
            }
        } else if let load = store.list(store.kind) {
            if let model = load.value {
                if model.isEmpty, !model.sections.contains(where: { $0.id == .closed && $0.loaded && !$0.rows.isEmpty }) {
                    ForgeNothingWaiting(kind: store.kind, repoName: store.allRepos ? "any repository" : store.repo?.repo.name ?? "") {
                        Task { await store.expand(.closed) }
                    }
                } else {
                    sections(model, emptyClosed: true)
                }
            } else if let error = load.error {
                ForgeErrorState(error: error) { Task { await store.loadList(store.kind) } }
            } else {
                SHLoadingRows().frame(height: MobileLayout.rowHeight * 2)
            }
        } else {
            SHLoadingRows().frame(height: MobileLayout.rowHeight * 2)
        }
        if let failure = store.failure {
            SHBanner(.failed, title: failure) {
                Button("OK") { store.failure = nil }.buttonStyle(.sh(.secondary))
            }
        }
    }

    @ViewBuilder private func sections(_ model: ForgeListModel, emptyClosed: Bool) -> some View {
        ForEach(model.sections) { section in
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                if section.loaded {
                    if !section.rows.isEmpty || section.id.loadsOnDemand {
                        if section.id.loadsOnDemand {
                            Button { store.collapse(section.id) } label: {
                                header(section, symbol: "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Hides this section")
                        } else {
                            header(section, symbol: nil)
                        }
                        if section.rows.isEmpty {
                            Text("Nothing here").shText(.caption).foregroundStyle(Color.sh.textTertiary).padding(.horizontal, SH.Space.xs)
                        } else if plain {
                            LazyVStack(spacing: 0) {
                                ForEach(section.rows) { row in
                                    VStack(spacing: 0) {
                                        if row.id != section.rows.first?.id { ReviewRowRule() }
                                        Button { open(row.key) } label: {
                                            ForgeRowView(row: row, selected: row.key == chosen, chevron: false).equatable()
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        } else {
                            ReviewLazyCard(section.rows) { row in
                                Button { open(row.key) } label: {
                                    ForgeRowView(row: row, selected: false).equatable()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else if emptyClosed {
                    // Collapsed until opened: Needs my team's review, Closed.
                    Button { Task { await store.expand(section.id) } } label: {
                        header(section, symbol: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows this section")
                }
            }
        }
    }

    private func header(_ section: ForgeSectionRows, symbol: String?) -> some View {
        HStack(spacing: SH.Space.s) {
            ReviewSectionHead(title: section.title, count: section.loaded ? "\(section.rows.count)" : nil)
            if let symbol {
                Image(systemName: symbol).font(.shSans(MobileLayout.touchDetailFont, .medium)).foregroundStyle(Color.sh.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        // A section that opens and closes is a full target; a plain head keeps the boards' rhythm.
        .frame(minHeight: symbol == nil ? nil : SH.Height.touch, alignment: .bottom)
        .contentShape(Rectangle())
    }
}

/// An empty list (MobilePRStates' "List, nothing waiting"): the words in a card, Show closed under.
private struct ForgeNothingWaiting: View {
    let kind: ForgeKind
    let repoName: String
    let showClosed: () -> Void

    var body: some View {
        VStack(spacing: SH.Space.l) {
            VStack(spacing: SH.Space.s) {
                Text(ForgePresentation.emptyTitle(kind))
                    .font(.shSans(MobileLayout.touchBodyFont, .semibold)).foregroundStyle(Color.sh.textPrimary)
                Text(ForgePresentation.emptyDetail(kind, repoName: repoName))
                    .font(.shSans(MobileLayout.touchDetailFont + 1)).lineSpacing(SH.Space.xxs).foregroundStyle(Color.sh.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SH.Space.xl)
            .padding(.vertical, SH.Space.xxl)
            .shCard(radius: MobileLayout.touchCardRadius, lift: true)
            .accessibilityElement(children: .combine)
            Button("Show closed", action: showClosed)
                .buttonStyle(.shLink(color: Color.sh.textPrimary, font: .shSans(MobileLayout.touchBodyFont, .medium)))
                .frame(minHeight: SH.Height.touch)
        }
        .padding(.top, SH.Space.s)
    }
}

/// iPad: the list beside the chosen item; with a pull request's file open, the pull request beside
/// its diff (iPadPRChanges). Too narrow for both: the list alone, its rows pushing the item.
private struct ForgeSplit: View {
    let store: ForgeStore
    let verticalBars: Bool
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let current = Self.current(store)
        let file = store.padFile
        Group {
            if let current, let file, current.ref.kind == .pullRequest {
                HStack(spacing: 0) {
                    ForgePullRequestContent(key: current, layout: .pad(verticalBars: verticalBars), openFile: { store.padFile = $0 })
                        .frame(width: MobileLayout.forgeDetailBesideDiffWidth)
                    SHHairline(.vertical)
                    ForgeDiffPane(key: current, path: file, choose: { store.padFile = $0 }) { store.padFile = nil }
                }
            } else {
                PadListDetail(listWidth: MobileLayout.forgeListWidth) {
                    ForgeListColumn(store: store, chosen: current, controlsInBar: verticalBars) { store.choose($0) }
                } detail: {
                    if let current {
                        ForgeItemContent(key: current, layout: .pad(verticalBars: verticalBars), openFile: { store.padFile = $0 })
                            .onAppear { store.reveal = nil }
                    } else {
                        ForgePadHead(title: "Issues & PRs", subtitle: nil, verticalBars: verticalBars) { EmptyView() }
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                } single: {
                    ForgeListColumn(store: store, chosen: nil, controlsInBar: verticalBars, open: { push($0) },
                                    back: verticalBars ? nil : { navigator.close(.forge(.list)) })
                        .task(id: store.reveal) {
                            guard let key = store.reveal else { return }
                            store.reveal = nil
                            push(key)
                        }
                }
            }
        }
        // A diff beside the pull request takes the whole window: the sidebar steps aside
        // (iPadPRChanges; half open it does anyway, DuoBookPR, `PadShell`).
        .onChange(of: file != nil, initial: true) { _, open in navigator.padForgeDiff = open }
        .onDisappear { navigator.padForgeDiff = false }
    }

    private func push(_ key: ForgeItemKey) {
        navigator.open(.forge(key.ref.kind == .pullRequest ? .pullRequest(host: key.host, ref: key.ref) : .issue(host: key.host, ref: key.ref)))
    }

    /// The chosen item, else the first row of the list on show.
    static func current(_ store: ForgeStore) -> ForgeItemKey? {
        if let chosen = store.chosen { return chosen }
        let model = store.browsing ? store.results?.value : store.list(store.kind)?.value
        return model?.sections.lazy.flatMap(\.rows).first?.key
    }
}

/// The item beside the list: a pull request or an issue.
struct ForgeItemContent: View {
    let key: ForgeItemKey
    let layout: ForgeDetailLayout
    var openFile: (String) -> Void = { _ in }

    var body: some View {
        if key.ref.kind == .pullRequest {
            ForgePullRequestContent(key: key, layout: layout, openFile: openFile)
        } else {
            ForgeIssueContent(key: key, layout: layout)
        }
    }
}

/// How a detail is framed: the phone's screen under its bar, or the iPad's column with its own
/// head (Back, the title, •••) where the bars don't run down the side.
enum ForgeDetailLayout: Equatable {
    case phone(verticalBars: Bool)
    case pad(verticalBars: Bool)

    var isPad: Bool { if case .pad = self { true } else { false } }
    var verticalBars: Bool {
        switch self {
        case .phone(let vertical), .pad(let vertical): vertical
        }
    }
}

/// The iPad detail's head (iPadIPReview): Back, "#31" over "payments · Open", and the item's menu
/// in a glass circle. Where the bars run down the side (iPhone Duo) Back and ••• are the bar's, and
/// the head is only the title (DuoBookPR).
struct ForgePadHead<Items: View>: View {
    let title: String
    let subtitle: String?
    let verticalBars: Bool
    @ViewBuilder let menu: () -> Items
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        HStack(spacing: SH.Space.m) {
            if !verticalBars {
                Button { navigator.close(.forge(.list)) } label: {
                    Image(systemName: "chevron.left")
                        .font(.sh(.headline))
                        .foregroundStyle(Color.sh.textPrimary)
                        .frame(width: SH.Height.touch, height: SH.Height.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            ForgeTitle(title: title, subtitle: subtitle, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !verticalBars {
                Menu { menu() } label: {
                    Image(systemName: "ellipsis")
                        .font(.sh(.headline))
                        .foregroundStyle(Color.sh.textPrimary)
                        .frame(width: SH.Height.touch, height: SH.Height.touch)
                        .contentShape(Circle())
                }
                .glassEffect(.regular, in: Circle())
                .accessibilityLabel("More")
            }
        }
        .padding(.horizontal, SH.Space.s)
        .frame(minHeight: SH.Height.touch + SH.Space.m)
        .background(Color.sh.bgWindow)
    }
}

/// "#31" over "payments · Open".
struct ForgeTitle: View {
    let title: String
    let subtitle: String?
    var alignment: HorizontalAlignment = .center

    var body: some View {
        VStack(alignment: alignment, spacing: SH.Space.xxs) {
            Text(title).font(.shBar(.title)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.shBar(.caption)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

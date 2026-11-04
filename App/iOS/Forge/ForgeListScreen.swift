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
                ForgeListColumn(store: store, chosen: nil) { ForgeHooks.open($0, store: store, navigator: navigator) }
            }
        }
        .background(Color.sh.bgWindow)
        .task(id: store.sessionsKey) { await store.loadRepos() }
        .task(id: store.repo?.id) { await store.loadLists() }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Issues & PRs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        // iPad draws its own heads over the list and the item (iPadIPReview); where the bars run
        // down the side (iPhone Duo) Back and ••• stay the system's.
        .toolbar(pad && !verticalBars ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if !pad || verticalBars {
                ToolbarOverflowMenu {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await store.loadRepos(); await store.loadLists() }
                    }
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
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
                        .font(.sh(.display))
                        .foregroundStyle(Color.sh.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: SH.Space.m)
                    ForgeRepoPicker(store: store)
                }
                ForgeSegmented(selection: kind, options: [
                    .init(value: .issue, title: "Issues", count: store.list(.issue)?.value?.count),
                    .init(value: .pullRequest, title: "Pull requests", count: store.list(.pullRequest)?.value?.count),
                ])
                SHTouchSearchField("Search or paste a link", text: $query, focus: $searching) {
                    Task { if let key = await store.submit(query) { query = ""; open(key) } }
                }
                .onChange(of: query) { _, text in if text.isEmpty { store.clearSearch() } }
                ForgeListBody(store: store, chosen: chosen, open: open)
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await store.loadRepos()
            await store.loadLists()
        }
    }
}

/// What the list holds now: why there is nothing, a search's results, or the sections.
private struct ForgeListBody: View {
    let store: ForgeStore
    let chosen: ForgeItemKey?
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
                sections(model, emptyClosed: false)
            } else if let error = results.error {
                ForgeErrorState(error: error) {}
            } else {
                SHLoadingRows().frame(height: MobileLayout.rowHeight * 2)
            }
        } else if let load = store.list(store.kind) {
            if let model = load.value {
                if model.isEmpty, !model.sections.contains(where: { $0.id == .closed && $0.loaded && !$0.rows.isEmpty }) {
                    ForgeNothingWaiting(kind: store.kind, repoName: store.repo?.repo.name ?? "") {
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
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
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
                        } else {
                            SHLazyListCard(section.rows) { row in
                                Button { open(row.key) } label: {
                                    ForgeRowView(row: row, selected: row.key == chosen).equatable()
                                }
                                .buttonStyle(.shRow(radius: 0))
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
            SHListHeader(section.title, count: section.loaded ? section.rows.count : nil, style: .sidebar)
            if let symbol {
                Image(systemName: symbol).font(.sh(.micro, weight: .semibold)).foregroundStyle(Color.sh.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        // A section that opens and closes is a full target; a plain head keeps the boards' rhythm.
        .frame(minHeight: symbol == nil ? nil : SH.Height.touch, alignment: .bottom)
        .contentShape(Rectangle())
    }
}

/// An empty list (MobilePRStates' "List, nothing waiting"): the glyph, the words, Show closed.
private struct ForgeNothingWaiting: View {
    let kind: ForgeKind
    let repoName: String
    let showClosed: () -> Void

    var body: some View {
        VStack(spacing: SH.Space.m) {
            Image(systemName: kind == .pullRequest ? ForgeGlyph.pullRequest : ForgeGlyph.issue)
                .font(.sh(.display, weight: .regular))
                .foregroundStyle(Color.sh.textTertiary)
                .accessibilityHidden(true)
            Text(ForgePresentation.emptyTitle(kind)).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
            Text(ForgePresentation.emptyDetail(kind, repoName: repoName))
                .shText(.caption).foregroundStyle(Color.sh.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show closed", action: showClosed).buttonStyle(.sh(.secondary))
                .padding(.top, SH.Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, SH.Space.xxl)
        .padding(.horizontal, SH.Space.l)
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
                    ForgeListColumn(store: store, chosen: current) { store.choose($0) }
                } detail: {
                    if let current {
                        ForgeItemContent(key: current, layout: .pad(verticalBars: verticalBars), openFile: { store.padFile = $0 })
                            .onAppear { store.reveal = nil }
                    } else {
                        ForgePadHead(title: "Issues & PRs", subtitle: nil, verticalBars: verticalBars) { EmptyView() }
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                } single: {
                    ForgeListColumn(store: store, chosen: nil, open: { push($0) },
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
        return store.list(store.kind)?.value?.sections.lazy.flatMap(\.rows).first?.key
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

/// The iPad detail's head (iPadIPReview): Back, "#31" over "payments · Open", and the item's
/// menu. Where the bars run down the side (iPhone Duo) Back and ••• are the bar's, and the head is
/// only the centred title (DuoBookPR).
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
            ForgeTitle(title: title, subtitle: subtitle)
                .frame(maxWidth: .infinity)
            if !verticalBars {
                Menu { menu() } label: {
                    Image(systemName: "ellipsis")
                        .font(.sh(.headline))
                        .foregroundStyle(Color.sh.textPrimary)
                        .frame(width: SH.Height.touch, height: SH.Height.touch)
                        .contentShape(Rectangle())
                }
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

    var body: some View {
        VStack(spacing: SH.Space.xxs) {
            Text(title).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

import AppKit
import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// MARK: The destination's list

/// The sidebar while Issues & PRs is on screen (PRReview, IssueReview, PRReviewEmpty,
/// PRReviewTeam): back, the title, the repository picker and More; the Issues | Pull requests
/// switch; Search or paste a link; then the sections, one lazy list.
struct ForgeSidebarPanel: View {
    var vm: ShepherdViewModel

    var body: some View {
        let store = vm.forgeStore
        VStack(alignment: .leading, spacing: SH.Space.m) {
            ForgeSidebarHeader(vm: vm, store: store)
            ForgeKindSwitch(store: store)
            ForgeSearchField(store: store)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.items.isEmpty, !store.loadingKinds.isEmpty || store.searching {
                        SHLoadingRows().padding(.top, SH.Space.l)
                    }
                    ForEach(store.items) { item in
                        ForgeListItemView(item: item, open: { ref in Task { await store.open(ref) } },
                                          toggle: { id in Task { await store.toggleSection(id) } })
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

private struct ForgeSidebarHeader: View {
    var vm: ShepherdViewModel
    let store: ForgeStore

    var body: some View {
        HStack(spacing: SH.Space.s) {
            Button { vm.leaveForge() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.shIcon(size: SH.Height.controlS))
                .help("Back")
                .accessibilityLabel("Back")
            Text("Issues & PRs")
                .font(.sh(.title))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: SH.Space.xs)
            if !store.repos.isEmpty {
                SHPopupMenu(store.repoName, mono: true, minWidth: 0) {
                    ForEach(store.repos) { repo in
                        Button(repo.nameWithOwner) { Task { await store.selectRepo(repo.nameWithOwner) } }
                    }
                }
                .accessibilityLabel("Repository")
            }
            Menu {
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
        .frame(height: AppLayout.forgeSidebarHeaderHeight)
    }
}

/// Issues | Pull requests, each with its count: the sidebar's own wide segmented track.
private struct ForgeKindSwitch: View {
    @Bindable var store: ForgeStore

    var body: some View {
        HStack(spacing: SH.Space.xxs) {
            segment(.issue, "Issues")
            segment(.pullRequest, "Pull requests")
        }
        .padding(SH.Space.xxs)
        .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.s)
        .frame(height: AppLayout.forgeSwitchHeight)
    }

    private func segment(_ kind: ForgeKind, _ title: String) -> some View {
        let selected = store.kind == kind
        let count = store.counts[kind]
        return Button { store.kind = kind } label: {
            HStack(spacing: SH.Space.s) {
                Text(title).font(.sh(.ui, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.sh.textPrimary : Color.sh.textSecondary)
                if let count { Text("\(count)").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? Color.sh.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .contentShape(Rectangle())
            .shFocusRing(radius: SH.Radius.xs)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ForgeSearchField: View {
    @Bindable var store: ForgeStore

    var body: some View {
        SHSearchField("Search or paste a link", text: $store.query)
            .onSubmit { Task { await store.submitSearch() } }
    }
}

/// One element of the list, redrawn only when its values change.
private struct ForgeListItemView: View, Equatable {
    let item: ForgeListItem
    let open: (ForgeItemRef) -> Void
    let toggle: (ForgeSectionID) -> Void

    static func == (a: Self, b: Self) -> Bool { a.item == b.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch item {
            case .header(_, let title, let count, let section):
                Button { if let section { toggle(section) } } label: {
                    HStack(spacing: SH.Space.s) {
                        Text(title).foregroundStyle(Color.sh.textTertiary)
                        Text("\(count)").foregroundStyle(Color.sh.textTertiary)
                        if section != nil { Image(systemName: "chevron.down").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary) }
                    }
                    .font(.sh(.ui, weight: .regular))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(section == nil)
                .padding(.horizontal, SH.Space.m)
                .padding(.top, AppLayout.forgeSectionTop)
                .padding(.bottom, SH.Space.s)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("\(title), \(count)")
            case .row(let row):
                ForgeListRowView(row: row) { open(row.ref) }
            case .more(let id, let title, let loading):
                Button { toggle(id) } label: {
                    HStack(spacing: SH.Space.s) {
                        Text(title)
                        if loading {
                            ProgressView().progressViewStyle(.shSpinner(size: SH.Space.l))
                        } else {
                            Image(systemName: "chevron.right").font(.sh(.micro))
                        }
                    }
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(Color.sh.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, SH.Space.m)
                .padding(.top, AppLayout.forgeSectionTop)
                .padding(.bottom, SH.Space.s)
                .accessibilityLabel("\(title), \(loading ? "loading" : "show")")
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

/// A pull request's or issue's row: its title (two lines at most) over the author and age, its
/// dot at the trailing edge.
private struct ForgeListRowView: View {
    let row: ForgeRow
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: SH.Space.m) {
                VStack(alignment: .leading, spacing: AppLayout.forgeRowGap) {
                    Text(row.title)
                        .font(.sh(.ui, weight: .regular))
                        .foregroundStyle(Color.sh.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: SH.Space.s) {
                        ForgeAvatar(login: row.author, you: row.viewerIsAuthor, size: AppLayout.forgeRowAvatar)
                        Text(row.byline).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: SH.Space.xs)
                ForgeDot(tone: row.tone).padding(.top, SH.Space.s)
            }
            .padding(.horizontal, SH.Space.m)
            .padding(.vertical, AppLayout.forgeRowVertical)
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
}

// MARK: Pinned (PRSidebarPinned)

/// A pin in the main sidebar's Pinned: its kind's glyph, title and one word, and the preview its
/// hover shows.
struct SidebarForgePin: Equatable, Identifiable {
    /// A preview line: a glyph (nil draws a dot) and its words.
    struct Line: Equatable {
        let symbol: String?
        let text: String
        let tone: ForgeTone
    }

    let ref: ForgeItemRef
    let title: String
    let tag: String
    let tagTone: ForgeTone?
    /// "Open", "Merged": nil until the host could read it.
    let badge: (label: String, tone: ForgeTone)?
    let lines: [Line]

    var id: ForgeItemRef { ref }
    /// "payments #31".
    var place: String { "\(ref.repoName) #\(ref.number)" }

    static func == (a: Self, b: Self) -> Bool {
        a.ref == b.ref && a.title == b.title && a.tag == b.tag && a.tagTone == b.tagTone && a.badge?.label == b.badge?.label
            && a.badge?.tone == b.badge?.tone && a.lines == b.lines
    }

    init(_ item: ForgePinnedItem, viewer: String?) {
        ref = item.pin.ref
        title = item.title
        let tag = ForgePresentation.pinnedTag(item, viewer: viewer)
        self.tag = tag.label
        tagTone = tag.tone
        var lines: [Line] = []
        if let pull = item.pullRequest {
            badge = ForgePresentation.badge(pull.state)
            switch pull.reviewDecision {
            case .changesRequested?: lines.append(Line(symbol: ForgeSymbol.comment, text: "Changes requested", tone: .failed))
            case .approved?: lines.append(Line(symbol: "checkmark", text: "Approved", tone: .done))
            case .reviewRequired?: lines.append(Line(symbol: ForgeSymbol.comment, text: "Waiting on review", tone: .idle))
            case nil: break
            }
            switch pull.checks {
            case .failing: lines.append(Line(symbol: "xmark", text: "Checks failing", tone: .failed))
            case .running: lines.append(Line(symbol: nil, text: "Checks running", tone: .running))
            case .passed: lines.append(Line(symbol: "checkmark", text: "Checks passed", tone: .done))
            case .none: break
            }
            if let thread = pull.thread { lines.append(Line(symbol: nil, text: "Thread: \(thread.title)", tone: thread.running ? .running : .idle)) }
        } else if let issue = item.issue {
            badge = ForgePresentation.badge(issue.state)
            lines.append(Line(symbol: nil, text: ForgePresentation.label(issue.progress), tone: ForgePresentation.tone(issue.progress)))
            if let thread = issue.thread { lines.append(Line(symbol: nil, text: "Thread: \(thread.title)", tone: thread.running ? .running : .idle)) }
        } else {
            badge = nil
        }
        self.lines = lines
    }
}

/// A pin's row: opens the item in Issues & PRs; its menu unpins it; resting the pointer on it
/// shows what it is waiting on.
struct SidebarForgePinRow: View {
    var vm: ShepherdViewModel
    let pin: SidebarForgePin
    @State private var preview = false
    @State private var hover: Task<Void, Never>?

    var body: some View {
        SHSidebarRow(pin.title, leading: .glyph(ForgeSymbol.kind(pin.ref.kind), attention: pin.tagTone == .attention),
                     accessory: .text(pin.tag, tone: pin.tagTone?.agentState))
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

/// The hover preview (PRSidebarPinned): the state tag and place, the title, what it waits on,
/// and how to act on it.
private struct SidebarForgePinPreview: View {
    let pin: SidebarForgePin

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                if let badge = pin.badge { ForgeStateTag(label: badge.label, tone: badge.tone) }
                Text(pin.place).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
            }
            Text(pin.title).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: SH.Space.s) {
                ForEach(pin.lines, id: \.text) { line in
                    HStack(spacing: SH.Space.m) {
                        Group {
                            if let symbol = line.symbol {
                                Image(systemName: symbol).font(.sh(.caption)).foregroundStyle(line.tone.color)
                            } else {
                                ForgeDot(tone: line.tone)
                            }
                        }
                        .frame(width: AppLayout.forgeRowAvatar)
                        Text(line.text).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                    }
                }
            }
            Text("Click to open · right-click to unpin").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
        }
        .padding(SH.Space.l)
        .frame(width: AppLayout.forgePinPreviewWidth, alignment: .leading)
        .background(Color.sh.bgRaised)
    }
}

import AppKit
import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Issues & PRs in the main column: the picked pull request's or issue's page, else why there is
/// none (PRReviewEmpty, gh missing or signed out), with a banner for a refused change or a sent brief.
struct ForgeDestination: View {
    var vm: ShepherdViewModel
    var chrome = PageHeaderChrome()

    var body: some View {
        let _ = SHRenderProbe.tick("page.forge")
        let store = vm.forgeStore
        VStack(spacing: 0) {
            if let ref = store.selection {
                if ref.kind == .pullRequest {
                    ForgePullRequestPage(vm: vm, store: store, chrome: chrome)
                } else {
                    ForgeIssuePage(vm: vm, store: store, chrome: chrome)
                }
            } else {
                ForgeHeaderBar(chrome: chrome, back: vm.leaveForge) { EmptyView() } trailing: { EmptyView() }
                ForgeBanners(vm: vm, store: store)
                ForgeEmptyPage(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.sh.bgWindow)
    }
}

/// The page's header: the tabs or the item's place leading, its actions trailing. Narrow headers
/// stack their controls; while the sidebar is not docked, show sidebar and return actions.
struct ForgeHeaderBar<Leading: View, Trailing: View>: View {
    let chrome: PageHeaderChrome
    var back: (() -> Void)? = nil
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SH.Space.m) {
                sidebarButton
                leading()
                Spacer(minLength: SH.Space.m)
                trailing()
            }
            VStack(alignment: .leading, spacing: SH.Space.m) {
                HStack(spacing: SH.Space.m) {
                    sidebarButton
                    leading()
                    Spacer(minLength: 0)
                }
                trailing()
            }
            .padding(.vertical, SH.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, SH.Space.l + chrome.leadingInset)
        .padding(.trailing, SH.Space.l)
        .frame(minHeight: SHPageMetrics.headerHeight)
        .frame(maxWidth: .infinity)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .bottom) { SHHairline() }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    @ViewBuilder private var sidebarButton: some View {
        if let show = chrome.showSidebar {
            Button(action: show) { Image(systemName: "sidebar.left") }
                .buttonStyle(.shIcon)
                .shHelp("Show sidebar", shortcut: KeybindingsStore.shared.display(.toggleSidebar))
                .accessibilityLabel("Show sidebar")
            if let back {
                Button(action: back) { Label("Back to threads", systemImage: "chevron.left") }
                    .buttonStyle(.sh(.ghost, size: .s))
                    .accessibilityLabel("Back to threads")
            }
        }
    }
}

/// Pin, Copy link and Open on GitHub: the header's three circles.
struct ForgeItemButtons: View {
    let store: ForgeStore
    let ref: ForgeItemRef
    var pins = true

    var body: some View {
        HStack(spacing: SH.Space.xxs) {
            if pins {
                let pinned = store.isPinned(ref)
                Button { Task { await store.togglePin() } } label: { Image(systemName: pinned ? "pin.slash" : SHGlyph.pin.symbolName) }
                    .buttonStyle(.shIcon(isOn: pinned))
                    .help(pinned ? "Unpin from the sidebar" : "Pin to the sidebar")
                    .accessibilityLabel(pinned ? "Unpin" : "Pin")
            }
            Button { ShepherdViewModel.copyForgeLink(ref) } label: { Image(systemName: ForgeSymbol.link) }
                .buttonStyle(.shIcon)
                .help("Copy link")
                .accessibilityLabel("Copy link")
            Button { ShepherdViewModel.openForgeURL(ref) } label: { Image(systemName: ForgeSymbol.external) }
                .buttonStyle(.shIcon)
                .help("Open on GitHub")
                .accessibilityLabel("Open on GitHub")
        }
    }
}

/// Nothing picked: why, and the way on (PRReviewEmpty). gh missing or signed out says how to fix it.
struct ForgeEmptyPage: View {
    let store: ForgeStore

    var body: some View {
        VStack {
            Spacer()
            if let error = store.error {
                SHEmptyState(Text(Self.title(error)), message: error.message, showsMark: false) {
                    if error.code == .ghMissing, let url = URL(string: "https://cli.github.com") {
                        Button("Get the GitHub CLI") { NSWorkspace.shared.open(url) }.buttonStyle(.sh(.secondary))
                    }
                    Button("Try again") { Task { await store.refresh() } }.buttonStyle(.sh(.secondary))
                }
            } else if store.reposLoaded, store.repos.isEmpty {
                empty(Text("No GitHub repositories here"),
                      "Add a space whose origin is on GitHub, or paste a link to open a pull request or issue.", showClosed: false)
            } else if !store.loadingKinds.isEmpty || !store.reposLoaded {
                ProgressView().progressViewStyle(.shSpinner())
            } else {
                let noun = store.kind == .pullRequest ? "pull requests" : "issues"
                empty(Text("No open \(noun) in \(store.repoName)"),
                      store.kind == .pullRequest
                        ? "Paste a link to open one from another repository, or let a thread open one when its work is ready."
                        : "Paste a link to open one from another repository.", showClosed: true)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func empty(_ title: Text, _ message: String, showClosed: Bool) -> some View {
        VStack(spacing: SH.Space.m) {
            Image(systemName: ForgeSymbol.kind(store.kind)).font(.sh(.display)).foregroundStyle(Color.sh.textTertiary)
                .accessibilityHidden(true)
            SHEmptyState(title, message: message, showsMark: false) {
                Button("Paste a link") { Task { await store.pasteLink() } }.buttonStyle(.sh(.secondary))
                if showClosed {
                    Button("Show closed") { Task { await store.toggleSection(.closed) } }.buttonStyle(.sh(.secondary))
                }
            }
        }
    }

    static func title(_ error: ForgeError) -> String {
        switch error.code {
        case .ghMissing: "The GitHub CLI isn't installed"
        case .signedOut: "gh isn't signed in"
        case .rateLimited: "GitHub is rate limiting gh"
        case .timedOut, .unreachable: "Couldn't reach GitHub"
        default: "Couldn't read GitHub"
        }
    }
}

/// A refused change or a brief that went to a thread, below even a wrapped page header.
struct ForgeBanners: View {
    var vm: ShepherdViewModel
    @Bindable var store: ForgeStore

    var body: some View {
        VStack(spacing: SH.Space.s) {
            if let error = store.actionError {
                SHBanner(.failed, title: ForgeEmptyPage.title(error), message: error.message) {
                    Button("Dismiss") { store.actionError = nil }.buttonStyle(.sh(.ghost, size: .s))
                }
            }
            if let notice = store.notice {
                SHBanner(.done, title: notice.text) {
                    if let id = notice.agentID {
                        Button("Open thread") { store.notice = nil; vm.selectAgent(id) }.buttonStyle(.sh(.secondary, size: .s))
                    }
                    Button("Dismiss") { store.notice = nil }.buttonStyle(.sh(.ghost, size: .s))
                }
            }
        }
        .frame(maxWidth: AppLayout.forgeContentWidth)
        .shAnimation(.content, value: store.notice)
        .shAnimation(.content, value: store.actionError)
    }
}

/// The loading page (PRReviewLoading): the title's and body's bars, and what it fetches.
struct ForgeLoadingPage: View {
    let number: Int

    var body: some View {
        ForgeColumns {
            VStack(alignment: .leading, spacing: SH.Space.l) {
                bar(0.18, AppLayout.forgeSkeletonBar + SH.Space.s)
                bar(0.7, AppLayout.forgeSkeletonTitle)
                bar(0.44, AppLayout.forgeSkeletonBar)
                bar(1, AppLayout.forgeSkeletonBar).padding(.top, SH.Space.xxl)
                bar(0.92, AppLayout.forgeSkeletonBar)
                bar(0.7, AppLayout.forgeSkeletonBar)
                Text("Fetching #\(number) from GitHub…").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).padding(.top, SH.Space.l)
            }
        } rail: {
            VStack(alignment: .leading, spacing: SH.Space.l) {
                bar(0.3, AppLayout.forgeSkeletonBar)
                bar(0.77, AppLayout.forgeSkeletonBar)
                bar(0.62, AppLayout.forgeSkeletonBar)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .shShimmer()
        .accessibilityElement()
        .accessibilityLabel("Fetching #\(number) from GitHub")
    }

    private func bar(_ fraction: CGFloat, _ height: CGFloat) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: SH.Radius.xs).fill(Color.sh.bgSelected).frame(width: geo.size.width * fraction)
        }
        .frame(height: height)
    }
}

/// A page that couldn't be read: why, and Try again.
struct ForgeDetailError: View {
    let error: ForgeError
    let retry: () -> Void

    var body: some View {
        VStack {
            Spacer()
            SHEmptyState(Text(ForgeEmptyPage.title(error)), message: error.message, showsMark: false) {
                Button("Try again", action: retry).buttonStyle(.sh(.secondary))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// The page's two columns: the reading column and the rail, centered, scrolling together.
struct ForgeColumns<Content: View, Rail: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let rail: () -> Rail

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= AppLayout.forgeTwoColumnMinWidth
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: AppLayout.forgeColumnGap))
                              : AnyLayout(VStackLayout(alignment: .leading, spacing: AppLayout.forgeColumnGap))
            ScrollView(.vertical) {
                layout {
                    VStack(alignment: .leading, spacing: 0, content: content)
                        .frame(maxWidth: AppLayout.forgeContentWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: SH.Space.l, content: rail)
                        .frame(width: wide ? AppLayout.forgeRailWidth : nil, alignment: .leading)
                        .frame(maxWidth: wide ? nil : AppLayout.forgeContentWidth, alignment: .leading)
                }
                .padding(.top, AppLayout.forgeTopPadding)
                .padding(.bottom, AppLayout.forgeBottomPadding)
                .padding(.horizontal, SH.Space.xxl)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The page's title, with its pencil: Return saves the new one, Escape keeps the old.
struct ForgeTitle: View {
    let title: String
    let editable: Bool
    let save: (String) async -> Bool
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        if let current = draft {
            TextField("Title", text: Binding(get: { current }, set: { draft = $0 }))
                .textFieldStyle(.plain)
                .font(.sh(.display))
                .foregroundStyle(Color.sh.textPrimary)
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit {
                    let next = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !next.isEmpty, next != title else { draft = nil; return }
                    Task { if await save(next) { draft = nil } }
                }
                .onExitCommand { draft = nil }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Text(title)
                    .font(.sh(.display))
                    .foregroundStyle(Color.sh.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if editable {
                    Button { draft = title } label: { Image(systemName: ForgeSymbol.edit) }
                        .buttonStyle(.shIcon(size: SH.Height.controlS))
                        .help("Edit title")
                        .accessibilityLabel("Edit title")
                }
            }
        }
    }
}

/// A rail section: its caption (and an optional trailing word), its rows, a hairline under it.
struct ForgeRailSection<Content: View>: View {
    let title: String
    var divider = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            ForgeCaption(title)
            content()
            if divider { SHHairline().padding(.top, SH.Space.s) }
        }
    }
}

/// "M mara opened 1h ago · head → base".
struct ForgeByline: View {
    let author: String
    let you: Bool
    let verb: String?
    let age: String
    var branches: (head: String, base: String)? = nil

    var body: some View {
        HStack(spacing: SH.Space.s) {
            ForgeAvatar(login: author, you: you)
            Text(author).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
            Text([verb, age].compactMap { $0 }.joined(separator: " ")).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            if let branches {
                Text("·").foregroundStyle(Color.sh.textTertiary)
                Text(branches.head).font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary)
                Text(branches.base).font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Activity: its header with the filter, and one card per event.
struct ForgeActivity: View {
    @Bindable var store: ForgeStore
    let events: [ForgeEvent]
    let viewer: String?
    let kind: ForgeKind

    var body: some View {
        let shown = store.commentsOnly ? events.filter { ForgeActivityRow.words($0) != nil } : events
        let now = store.now()
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack {
                Text("Activity").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary).accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Picker("Show", selection: $store.commentsOnly) {
                        Text("All Activity").tag(false)
                        Text("Comments and Reviews").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(store.commentsOnly ? "Comments" : "All activity", systemImage: ForgeSymbol.filter)
                }
                .menuStyle(.button)
                .buttonStyle(.sh(.ghost, size: .s))
                .menuIndicator(.hidden)
                .fixedSize()
            }
            LazyVStack(alignment: .leading, spacing: SH.Space.m) {
                ForEach(shown) { event in
                    ForgeActivityRow(event: event, viewer: viewer, kind: kind, now: now).equatable()
                }
            }
        }
    }
}

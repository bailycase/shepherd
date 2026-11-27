import AppKit
import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSidebar

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
        // The boards' window padding: the page sits inside the 8pt the sidebar's card leaves.
        .padding([.top, .trailing, .bottom], AppLayout.toolbarTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.sh.bgWindow)
    }
}

/// The page's header (the boards' `.gch-ptb`): 44pt, no rule, the tabs or the item's place leading, its
/// actions trailing. Narrow headers stack their controls; while the sidebar is not docked, show
/// sidebar and return actions.
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
        .padding(.leading, (chrome.showSidebar == nil ? SHToolbarMetrics.leadingPadding : SH.Space.xxl) + chrome.leadingInset)
        .padding(.trailing, SHToolbarMetrics.trailingPadding)
        .frame(minHeight: SHToolbarMetrics.height)
        .frame(maxWidth: .infinity)
        .background(Color.sh.bgWindow)
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
        if let error = store.error {
            ForgeEmptyBlock(title: Self.title(error), message: error.message) {
                if error.code == .ghMissing, let url = URL(string: "https://cli.github.com") {
                    Button("Get the GitHub CLI") { NSWorkspace.shared.open(url) }.buttonStyle(.shLink(color: Color.sh.textPrimary, font: ForgeEmptyLink.font))
                }
                Button("Try again") { Task { await store.refresh() } }.buttonStyle(.shLink(color: Color.sh.textSecondary, font: .sh(.ui, weight: .regular)))
            }
        } else if !store.loadingKinds.isEmpty || !store.reposLoaded {
            SHBusyLabel("Loading…", font: .sh(.ui))
                .padding(.leading, AppLayout.forgePageLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            let noun = store.kind == .pullRequest ? "pull requests" : "issues"
            ForgeEmptyBlock(title: store.repo == nil ? "No open \(noun) waiting on you" : "No open \(noun) in \(store.repoName)",
                            message: store.kind == .pullRequest
                                ? "Paste a link to open one from another repository, or let a thread open one when its work is ready."
                                : "Paste a link to open one from another repository.") {
                Button("Paste a link") { Task { await store.pasteLink() } }.buttonStyle(.shLink(color: Color.sh.textPrimary, font: ForgeEmptyLink.font))
                Button("Show closed") { Task { await store.toggleSection(.closed) } }.buttonStyle(.shLink(color: Color.sh.textSecondary, font: .sh(.ui, weight: .regular)))
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
                SHBanner(.failed, title: store.actionTitle ?? ForgeEmptyPage.title(error), message: error.message) {
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
        .padding(.horizontal, SH.Space.l)
        .padding(.top, store.actionError == nil && store.notice == nil ? 0 : SH.Space.m)
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
            RoundedRectangle(cornerRadius: SH.Radius.s).fill(Color.sh.bgHover).frame(width: geo.size.width * fraction)
        }
        .frame(height: height)
    }
}

/// A page that couldn't be read: why, and Try again.
struct ForgeDetailError: View {
    let error: ForgeError
    let retry: () -> Void

    var body: some View {
        ForgeEmptyBlock(title: ForgeEmptyPage.title(error), message: error.message) {
            Button("Try again", action: retry).buttonStyle(.shLink(color: Color.sh.textSecondary, font: .sh(.ui, weight: .regular)))
        }
    }
}

/// The main link of an empty page.
enum ForgeEmptyLink {
    @MainActor static var font: Font { .sh(.ui, weight: .medium) }
}

/// An empty or error page's words (the boards' `.gch-empb`): left-aligned 28pt in, a little above the
/// middle; the title in 15 semibold, its words in `textSecondary`, then plain-word links.
struct ForgeEmptyBlock<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.shSans(AppLayout.forgeEmptyTitleSize, .semibold))
                .foregroundStyle(Color.sh.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .shText(.ui)
                .foregroundStyle(Color.sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, SH.Space.s)
            HStack(spacing: AppLayout.forgeEmptyActionGap, content: actions)
                .padding(.top, SH.Space.xl - SH.Space.xxs)
        }
        .frame(width: AppLayout.forgeEmptyWidth, alignment: .leading)
        .padding(.horizontal, AppLayout.forgePageLeading)
        .padding(.bottom, AppLayout.forgeEmptyBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The page's two columns (the boards' `.gch-cols`): the reading column from the leading edge, up to 720
/// wide, and the rail (272) at the trailing edge, scrolling together. Narrower, the rail goes under the
/// column. The page fades into the window under where the dock floats.
struct ForgeColumns<Content: View, Rail: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let rail: () -> Rail

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= AppLayout.forgeTwoColumnMinWidth
            ScrollView(.vertical) {
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: AppLayout.forgeColumnGap) {
                            reading
                            Spacer(minLength: 0)
                            railColumn.frame(width: AppLayout.forgeRailWidth).padding(.top, AppLayout.forgeRailTop)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: AppLayout.forgeColumnGap) {
                            reading
                            railColumn.frame(maxWidth: AppLayout.forgeContentWidth, alignment: .leading)
                        }
                    }
                }
                .padding(.top, AppLayout.forgeTopPadding)
                .padding(.bottom, AppLayout.forgeBottomPadding)
                .padding(.leading, AppLayout.forgePageLeading)
                .padding(.trailing, AppLayout.forgePageTrailing)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Color.sh.bgWindow, location: 0.7)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: AppLayout.forgeFadeHeight)
                    .allowsHitTesting(false)
            }
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: AppLayout.forgeContentWidth, alignment: .leading)
    }

    private var railColumn: some View {
        VStack(alignment: .leading, spacing: 0, content: rail)
    }
}

/// The page's title, with its pencil: Return saves the new one, Escape keeps the old.
struct ForgeTitle: View {
    let title: String
    let editable: Bool
    /// The pane draws no pencil (GXPanePR): a double click edits the title there.
    var pencil = true
    var font: Font = .shSans(AppLayout.forgeTitleSize, .semibold)
    var tracking: CGFloat = AppLayout.forgeTitleTracking
    var lineSpacing: CGFloat = 0
    let save: (String) async -> Bool
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        if let current = draft {
            TextField("Title", text: Binding(get: { current }, set: { draft = $0 }))
                .textFieldStyle(.plain)
                .font(font)
                .tracking(tracking)
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
                    .font(font)
                    .tracking(tracking)
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(Color.sh.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .onTapGesture(count: 2) { if editable { draft = title } }
                if editable, pencil {
                    Button { draft = title } label: { Image(systemName: ForgeSymbol.edit) }
                        .buttonStyle(.shIcon(size: SH.Height.controlS))
                        .foregroundStyle(Color.sh.textTertiary)
                        .help("Edit title")
                        .accessibilityLabel("Edit title")
                }
            }
        }
    }
}

/// A rail section (the boards' `.gch-rs`): its caption (and an optional edit menu) in `caption`, its
/// rows, a hairline 14 under it and 14 more before the next.
struct ForgeRailSection<Content: View, Accessory: View>: View {
    let title: String
    var divider = true
    @ViewBuilder let content: () -> Content
    /// Trailing the caption: an edit menu.
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.s) {
                ForgeCaption(title)
                Spacer(minLength: SH.Space.s)
                accessory()
            }
            .frame(height: AppLayout.forgeRailHead)
            .padding(.bottom, SH.Space.xs)
            content()
        }
        .padding(.bottom, divider ? AppLayout.forgeRailGap : 0)
        .overlay(alignment: .bottom) { if divider { SHHairline() } }
        .padding(.bottom, divider ? AppLayout.forgeRailGap : 0)
    }
}

extension ForgeRailSection where Accessory == EmptyView {
    init(title: String, divider: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, divider: divider, content: content, accessory: { EmptyView() })
    }
}

/// An item's labels (`.gch-lbl`): their names in a line of words.
struct ForgeLabelsLine: View {
    let labels: [ForgeLabel]

    var body: some View {
        Text(labels.isEmpty ? "None yet" : labels.map(\.name).joined(separator: ", "))
            .font(.sh(.ui, weight: .regular))
            .foregroundStyle(labels.isEmpty ? Color.sh.textTertiary : Color.sh.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: AppLayout.forgeRailHead, alignment: .leading)
    }
}

/// "M baily opened this 2h ago, agent/refund-events into main" (`.gch-by`).
struct ForgeByline: View {
    let author: String
    let you: Bool
    let verb: String?
    let age: String
    var branches: (head: String, base: String)? = nil

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            ForgeAvatar(login: author, you: you)
            (Text(author).fontWeight(.medium).foregroundStyle(sh.textPrimary)
                + Text(" " + [verb, age].compactMap { $0 }.joined(separator: " ")).foregroundStyle(sh.textSecondary)
                + Text(branches == nil ? "" : ", ").foregroundStyle(sh.textSecondary)
                + Text(branches?.head ?? "").font(.shMono(SHTextStyle.caption.size)).foregroundStyle(sh.textSecondary)
                + Text(branches == nil ? "" : " into ").foregroundStyle(sh.textSecondary)
                + Text(branches?.base ?? "").font(.shMono(SHTextStyle.caption.size)).foregroundStyle(sh.textSecondary))
                .font(.sh(.ui, weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Activity: its header with the filter, and one row per event. On the page the header (the boards' `.gch-acth`) has a
/// line over it and rows run one under another; the pane's are cards.
struct ForgeActivity: View {
    @Bindable var store: ForgeStore
    let events: [ForgeEvent]
    let viewer: String?
    let kind: ForgeKind
    /// Reviews show their line comments (the side pane's PRPane).
    var lineComments = false
    /// Drawn for the side pane (GXPanePR): plain event rows, outlined words.
    var pane = false

    var body: some View {
        let shown = store.commentsOnly ? events.filter { ForgeActivityRow.words($0) != nil } : events
        let now = store.now()
        VStack(alignment: .leading, spacing: pane ? SH.Space.m : 0) {
            HStack {
                Text("Activity")
                    .font(pane ? .sh(.headline) : .sh(.body, weight: .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                filter
            }
            .padding(.top, pane ? 0 : AppLayout.forgeActivityHeadTop)
            .overlay(alignment: .top) { if !pane { SHHairline() } }
            .padding(.top, pane ? 0 : AppLayout.forgeActivityTop)
            .padding(.bottom, pane ? 0 : SH.Space.s)
            LazyVStack(alignment: .leading, spacing: pane ? SH.Space.xxs : 0) {
                ForEach(shown) { event in
                    ForgeActivityRow(event: event, viewer: viewer, kind: kind, now: now, lineComments: lineComments || !pane, pane: pane).equatable()
                }
            }
        }
    }

    @ViewBuilder private var filter: some View {
        let menu = Menu {
            Picker("Show", selection: $store.commentsOnly) {
                Text("All Activity").tag(false)
                Text("Comments and Reviews").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            if pane {
                Label(store.commentsOnly ? "Comments" : "All activity", systemImage: ForgeSymbol.filter)
            } else {
                ForgeMenuLabel(title: store.commentsOnly ? "Comments" : "All activity")
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        if pane {
            menu.buttonStyle(.sh(.ghost, size: .s))
        } else {
            menu.buttonStyle(.plain)
        }
    }
}

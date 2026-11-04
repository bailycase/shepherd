import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// Issues & PRs' sidebar list and store, over a stub transport: sections in order, each item once,
/// folded on-demand sections, the empty list, search and pasted links, pins.
@MainActor
struct ForgeStoreTests {
    static let repo = "acme/payments"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func pull(_ number: Int, _ title: String = "PR", checks: ForgeChecksState = .none, team: String? = nil) -> PullRequestSummary {
        PullRequestSummary(ref: ForgeItemRef(kind: .pullRequest, repo: repo, number: number), title: title, author: "baily",
                           updatedAt: now.addingTimeInterval(-7_200), state: .open, checks: checks, headRef: "h", baseRef: "main", team: team)
    }

    static func list(_ sections: [ForgeSection]) -> ForgeList {
        ForgeList(kind: .pullRequest, repo: repo, viewer: "baily", sections: sections)
    }

    static func items(_ list: ForgeList?, open: Set<ForgeSectionID> = [], results: ForgeList? = nil,
                      selection: ForgeItemRef? = nil) -> [ForgeListItem] {
        ForgeStore.items(list: list, kind: .pullRequest, open: open, loading: [], results: results, query: "q", selection: selection,
                         repoName: "payments", now: now)
    }

    @Test func sectionsListEachItemOnceAndFoldOnDemandSections() {
        let list = Self.list([
            ForgeSection(id: .authored, pullRequests: [Self.pull(31, checks: .failing), Self.pull(30)]),
            ForgeSection(id: .reviewRequested, pullRequests: [Self.pull(31), Self.pull(29)]),
        ])
        let items = Self.items(list, selection: ForgeItemRef(kind: .pullRequest, repo: Self.repo, number: 30))
        #expect(items.map(\.id) == ["header.authored", "pullRequest:acme/payments#31", "pullRequest:acme/payments#30",
                                    "header.reviewRequested", "pullRequest:acme/payments#29", "more.teamReview", "more.closed"])
        guard case .header(_, let title, let count, _) = items[3], case .row(let failing) = items[1], case .row(let picked) = items[2] else {
            Issue.record("unexpected items"); return
        }
        #expect(title == "Needs my review" && count == 1)
        #expect(failing.tone == .failed && failing.byline == "baily · 2h" && failing.viewerIsAuthor)
        #expect(picked.selected && !failing.selected)
        #expect(ForgeStore.count(list) == 3)
    }

    @Test func anOpenedTeamSectionNamesItsTeamAndCanFoldAgain() {
        let list = Self.list([ForgeSection(id: .authored, pullRequests: [Self.pull(31)]),
                              ForgeSection(id: .teamReview, pullRequests: [Self.pull(24, team: "ledger")])])
        let items = Self.items(list, open: [.teamReview])
        #expect(items.contains(.header(id: "teamReview", title: "Needs my team's review · ledger", count: 1, section: .teamReview)))
        #expect(!items.contains { $0.id == "more.teamReview" })
        // The team's rows don't count toward the switch.
        #expect(ForgeStore.count(list) == 1)
    }

    @Test func anEmptyListSaysSoAboveItsOnDemandSections() {
        let items = Self.items(Self.list([ForgeSection(id: .authored)]))
        #expect(items.map(\.id) == ["empty", "more.teamReview", "more.closed"])
        #expect(items.first == .empty(title: "Nothing waiting",
                                      detail: "No pull requests you wrote, need to review, or that an agent opened in payments."))
    }

    @Test func searchResultsReplaceTheSections() {
        let results = Self.list([ForgeSection(id: .results, pullRequests: [Self.pull(12)])])
        #expect(Self.items(Self.list([]), results: results).map(\.id) == ["header.results", "pullRequest:acme/payments#12"])
        #expect(Self.items(Self.list([]), results: Self.list([])) == [.message("No matches for “q”")])
    }

    @Test func mergingAnOnDemandSectionKeepsTheListsOrder() {
        let list = Self.list([ForgeSection(id: .authored), ForgeSection(id: .closed)])
        let merged = ForgeStore.merging(ForgeSection(id: .teamReview), into: list, kind: .pullRequest, repo: Self.repo)
        #expect(merged.sections.map(\.id) == [.authored, .teamReview, .closed])
    }

    @Test func aPastedLinkOpensItsItemAndOtherWordsSearch() async {
        var seen: [RemoteForgeRequest] = []
        let store = ForgeStore { request in
            seen.append(request)
            switch request {
            case .repos: return .success(.repos([ForgeRepo(nameWithOwner: Self.repo, path: "/tmp/payments")]))
            case .list(let kind, _, _): return .success(.list(ForgeList(kind: kind, repo: Self.repo, sections: [])))
            case .search: return .success(.list(Self.list([ForgeSection(id: .results, pullRequests: [Self.pull(7)])])))
            case .sidebar: return .failure(.signedOut)
            case .issue: return .failure(ForgeError(.notFound, "No issue 34."))
            default: return .success(.ok)
            }
        }
        await store.start()
        #expect(store.repo == Self.repo && store.path(of: Self.repo) == "/tmp/payments")

        store.query = "refund"
        await store.submitSearch()
        #expect(seen.last == .search(kind: .pullRequest, repo: Self.repo, query: "refund"))
        #expect(store.items.map(\.id) == ["header.results", "pullRequest:acme/payments#7"])

        store.query = "https://github.com/acme/payments/issues/34#issuecomment-1"
        await store.submitSearch()
        #expect(store.selection == ForgeItemRef(kind: .issue, repo: Self.repo, number: 34))
        #expect(store.kind == .issue && store.query.isEmpty)
        #expect(store.detailError?.code == .notFound)
    }

    @Test func listFailuresReadAsTheirFix() async {
        let store = ForgeStore { _ in .failure(.ghMissing) }
        await store.start()
        #expect(store.error == .ghMissing)
        #expect(ForgeEmptyPage.title(.ghMissing) == "The GitHub CLI isn't installed")
    }

    @Test func pinningKeepsTheNeedsYouCount() async {
        let ref = ForgeItemRef(kind: .pullRequest, repo: Self.repo, number: 31)
        let pin = ForgePinnedItem(pin: ForgePin(ref: ref, title: "Add refund events", pinnedAt: Self.now))
        let store = ForgeStore { request in
            switch request {
            case .sidebar: .success(.sidebar(ForgeSidebar(pins: [], needsYou: 3)))
            case .setPinned: .success(.sidebar(ForgeSidebar(pins: [pin], needsYou: 0)))
            default: .failure(.ghMissing)
            }
        }
        await store.loadSidebar()
        await store.perform(.setPinned(ref: ref, title: "Add refund events", pinned: true))
        #expect(store.isPinned(ref) && store.sidebar?.needsYou == 3)
    }

    @Test func aPinsPreviewSaysWhatItWaitsOn() {
        var pull = Self.pull(31, "Add refund events", checks: .failing)
        pull.reviewDecision = .changesRequested
        pull.thread = ForgeThreadLink(agentID: AgentID(), title: "Add refund events", running: true)
        let item = ForgePinnedItem(pin: ForgePin(ref: pull.ref, title: "old", pinnedAt: Self.now), pullRequest: pull)
        let row = SidebarForgePin(item, viewer: "baily")
        #expect(row.title == "Add refund events" && row.tag == "changes" && row.tagTone == .failed && row.place == "payments #31")
        #expect(row.badge?.label == "Open")
        #expect(row.lines.map(\.text) == ["Changes requested", "Checks failing", "Thread: Add refund events"])
        // A pin the host couldn't read shows its number and nothing else.
        let unread = SidebarForgePin(ForgePinnedItem(pin: ForgePin(ref: pull.ref, title: "old", pinnedAt: Self.now)), viewer: nil)
        #expect(unread.tag == "#31" && unread.badge == nil && unread.lines.isEmpty && unread.title == "old")
    }

    @Test func pinnedForgeItemsJoinPinnedUnderOneHeader() {
        let ref = ForgeItemRef(kind: .issue, repo: Self.repo, number: 34)
        let pin = SidebarForgePin(ForgePinnedItem(pin: ForgePin(ref: ref, title: "Partial refunds", pinnedAt: Self.now)), viewer: nil)
        let items = SidebarLists().items(collapsed: [], showsProjects: false, forgePins: [pin])
        #expect(items == [.header(.pinned, count: 1, collapsed: false), .forgePin(pin)])
        #expect(SidebarLists().items(collapsed: [.pinned], showsProjects: false, forgePins: [pin]) == [.header(.pinned, count: 1, collapsed: true)])
    }

    @Test func theDestinationRowCountsWhatNeedsYou() {
        let rows = SidebarDerivation.destinations(shown: .forge, newThreadChord: "⌘N", forge: 3)
        let forge = try? #require(rows.last)
        #expect(forge?.title == "Issues & PRs" && forge?.selected == true && forge?.trailing == .count(3))
        #expect(forge.map(SidebarDerivation.accessibilityLabel) == "Issues & PRs, 3 need you")
    }
}

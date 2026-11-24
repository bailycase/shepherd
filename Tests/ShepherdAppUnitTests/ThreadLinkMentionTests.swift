import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The composer's @ picker linking a thread (ThreadLinkA): "Link a thread" lists the threads whose title holds what was typed, most
/// recently active first, the first one selected; choosing one puts its Markdown link in the message. And the table every chip and
/// row is drawn from, as the hosts' agents give it.
@Suite("Thread link mentions")
@MainActor
struct ThreadLinkMentionTests {
    static let pg = SHThreadLink(id: "pg17", title: "Migrate orders to Postgres 17", state: .running, location: "This Mac",
                                 project: "orders-db", activeAt: 300)
    static let pool = SHThreadLink(id: "pool", title: "Postgres pool sizing", state: .done, location: "This Mac",
                                   project: "payments-api", activeAt: 200)
    static let postcss = SHThreadLink(id: "postcss", title: "Upgrade PostCSS", state: .idle, host: "mini", location: "mini",
                                      project: "web", activeAt: 100)
    static let retention = SHThreadLink(id: "retention", title: "Pick a retention window", state: .attention, location: "This Mac",
                                        project: "orders-db", activeAt: 400)
    static let design = SHThreadLink(id: "design", title: "Postgres dashboard", state: .running, location: "This Mac", activeAt: 500,
                                     pickable: false)
    static let threads = [postcss, pool, retention, design, pg]

    @Test func typedWordsListTheMatchingThreadsMostRecentFirstWithTheFirstSelected() throws {
        var state = MentionPickerState()
        state.update(draft: "Before you touch the orders tables, check @post", catalog: nil, threads: Self.threads, designs: false)
        let section = try #require(state.content.sections.first)
        #expect(state.content.sections.count == 1)
        #expect(section.title == "Link a thread" && section.caption && section.trailing == "@post")
        #expect(section.rows.map(\.title) == ["Migrate orders to Postgres 17", "Postgres pool sizing", "Upgrade PostCSS"],
                "a design's chat is not offered, and the thread that doesn't match is left out")
        #expect(section.rows.map(\.subtitle) == ["orders-db", "payments-api", "web · mini"])
        #expect(section.rows.map(\.state) == [.running, .done, .idle])
        #expect(section.rows.allSatisfy { $0.kind == .thread && $0.matched == ["post"] })
        #expect(state.highlighted == section.rows.first?.id)
        #expect(state.content.empty == nil)
    }

    @Test func choosingAThreadPutsItsLinkInTheMessage() throws {
        var state = MentionPickerState()
        state.update(draft: "check @post", catalog: nil, threads: Self.threads, designs: false)
        let row = try #require(state.highlightedRow)
        #expect(state.choose(row) == .link(draft: "check [Migrate orders to Postgres 17](shepherd-thread://pg17) "))
        #expect(!state.isOpen, "the picker closes")
    }

    /// The thread being written in never offers to link itself, whatever its id's case.
    @Test func theComposersOwnThreadIsLeftOut() {
        var state = MentionPickerState()
        state.update(draft: "@post", catalog: nil, threads: Self.threads, excluding: "PG17", designs: false)
        #expect(state.content.rows.map(\.title) == ["Postgres pool sizing", "Upgrade PostCSS"])
        #expect(state.highlighted == MentionPickerContent.threadRowID("pool"), "the first row left is selected")
        state.update(draft: "@", catalog: DesignReferenceThreadTests.catalog, stage: .rows, threads: [Self.pg], excluding: "pg17")
        #expect(state.content.sections.map(\.title) == ["Designs"], "its own thread alone lists no section")
        state.update(draft: "@migrate", catalog: nil, threads: [Self.pg], excluding: "pg17", designs: false)
        #expect(state.content.rows.isEmpty && state.content.empty == .nothingMatches(query: "migrate", searched: MentionPickerContent.threadsSearched))
    }

    @Test func aBareAtListsTheMostRecentThreadsUpToTheLimit() {
        var state = MentionPickerState()
        let many = (0..<10).map { SHThreadLink(id: "t\($0)", title: "Thread \($0)", state: .idle, location: "This Mac", activeAt: Double($0)) }
        state.update(draft: "@", catalog: nil, threads: many, designs: false)
        #expect(state.content.rows.map(\.title) == ["Thread 9", "Thread 8", "Thread 7", "Thread 6", "Thread 5", "Thread 4"])
        #expect(state.content.sections.first?.trailing == nil, "nothing typed, nothing echoed")
    }

    @Test func nothingMatchingSaysWhatItSearched() {
        var state = MentionPickerState()
        state.update(draft: "@pricng", catalog: nil, threads: Self.threads, designs: false)
        #expect(state.content.rows.isEmpty)
        #expect(state.content.empty == .nothingMatches(query: "pricng", searched: MentionPickerContent.threadsSearched))
        #expect(state.highlighted == nil)
    }

    /// With designs too, the threads come first; a design search that found nothing gives way to the threads it found.
    @Test func threadsLeadTheDesignsAndOutliveAnEmptyDesignSearch() {
        var state = MentionPickerState()
        state.update(draft: "@", catalog: DesignReferenceThreadTests.catalog, stage: .rows, threads: [Self.pg])
        #expect(state.content.sections.map(\.title) == ["Link a thread", "Designs"])
        #expect(state.highlighted == MentionPickerContent.threadRowID("pg17"))
        state.update(draft: "@migrate", catalog: DesignReferenceThreadTests.catalog, stage: .rows, threads: [Self.pg])
        #expect(state.content.sections.map(\.title) == ["Link a thread"])
        #expect(state.content.empty == nil)
    }

    /// Inside a design the picker lists its boards alone.
    @Test func noThreadsInsideADesign() throws {
        var state = MentionPickerState()
        state.update(draft: "@", catalog: DesignReferenceThreadTests.catalog, stage: .rows, threads: [Self.pg])
        let design = try #require(state.content.rows.first { $0.kind == .design })
        guard case .drill(let draft)? = state.choose(design) else { Issue.record("a design drills in"); return }
        state.update(draft: draft, catalog: DesignReferenceThreadTests.catalog, stage: .rows, threads: [Self.pg])
        #expect(!state.content.rows.contains { $0.kind == .thread })
    }

    /// The table: each agent's current title and status, where it runs, its project and branch, and the line the host keeps.
    @Test func theTableIsTheHostsAgents() throws {
        let web = Space(id: SpaceID(rawValue: "web"), name: "web", path: "/p/web")
        let runs = Space(id: SpaceID(rawValue: "runs"), name: "Automations", path: "/p/runs", hidden: true)
        var working = Agent(id: AgentID(rawValue: "a"), name: "Speed up checkout CI", spaceID: web.id, tabID: TabID(rawValue: "a"), status: .working)
        working.checkout = AgentCheckout(branch: "agent/checkout-ci", changedFiles: 2)
        var asking = Agent(id: AgentID(rawValue: "b"), name: "Pick a retention window", spaceID: web.id, tabID: TabID(rawValue: "b"), status: .blocked)
        asking.waitingOn = "30 or 90 days?\nThe migration drops partitions."
        var failed = Agent(id: AgentID(rawValue: "c"), name: "Broken", spaceID: web.id, tabID: TabID(rawValue: "c"))
        failed.lastFailure = "Model not signed in"
        let run = Agent(id: AgentID(rawValue: "d"), name: "Nightly run", spaceID: runs.id, tabID: TabID(rawValue: "d"))
        let remote = Agent(id: AgentID(rawValue: "e"), name: "Fix flaky payment test", spaceID: web.id, tabID: TabID(rawValue: "e"), status: .done,
                           worktreeBranch: "agent/flaky")
        let since = Date(timeIntervalSince1970: 1_000)
        let links = ThreadLinkTable.links([
            .init(state: ShepherdState(spaces: [web, runs], agents: [working, asking, failed, run]), tag: nil, location: ThreadLinkTable.thisMac,
                  statusSince: [working.id: since]),
            .init(state: ShepherdState(spaces: [web], agents: [remote]), tag: "mini", location: "mini"),
        ])
        let byID = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0) })
        let a = try #require(byID["a"])
        #expect(a.state == .running && a.host == nil && a.location == "This Mac" && a.place == "web · agent/checkout-ci" && a.since == since)
        #expect(a.progress == nil, "no line is kept for a working thread")
        #expect(byID["b"]?.state == .attention && byID["b"]?.progress == "30 or 90 days?")
        #expect(byID["c"]?.state == .failed && byID["c"]?.progress == "Model not signed in")
        #expect(byID["d"]?.pickable == false, "an automation's run resolves but isn't offered")
        let e = try #require(byID["e"])
        #expect(e.state == .done && e.host == "mini" && e.location == "mini" && e.branch == "agent/flaky")
    }
}

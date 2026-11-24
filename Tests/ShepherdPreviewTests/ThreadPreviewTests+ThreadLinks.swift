import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Thread links (ThreadLinkA): the agent names other threads in its reply and each is a chip with its status and current title
/// (and its Mac's tag when it runs on another); resting on one opens its peek; "@" in the composer offers "Link a thread". The
/// table is derived as the app derives it (`ThreadLinkTable`), from hosts' agents.
extension ThreadPreviewTests {
    static let linkSize = CGSize(width: 1180, height: 760)
    static let pgThread = "3f9c2a1e-6b1d-4c3e-9a51-0c7d1e2f4a10"
    static let retentionThread = "5b7d0c2e-1f3a-4e6b-8d9c-2a4f6e8b0d13"
    static let flakyThread = "9a0b1c2d-3e4f-4a5b-8c6d-7e8f9a0b1c2d"

    /// This Mac's threads and the mini's, as their hosts report them.
    static func linkTable() -> SHThreadLinks {
        let orders = Space(id: SpaceID(rawValue: "orders"), name: "orders-db", path: "~/Developer/orders-db")
        let payments = Space(id: SpaceID(rawValue: "payments"), name: "payments-api", path: "~/Developer/payments-api")
        let web = Space(id: SpaceID(rawValue: "web"), name: "web", path: "~/Developer/web")
        var pg = Agent(id: AgentID(rawValue: pgThread), name: "Migrate orders to Postgres 17", spaceID: orders.id, tabID: TabID(rawValue: "pg"),
                       status: .working, worktreeBranch: "agent/pg17-orders")
        pg.lastActiveAt = 900
        var retention = Agent(id: AgentID(rawValue: retentionThread), name: "Pick a retention window", spaceID: orders.id,
                              tabID: TabID(rawValue: "retention"), status: .blocked)
        retention.waitingOn = "Keep 30 or 90 days of orders history? Migration 0042 drops the old partitions based on the answer."
        retention.lastActiveAt = 800
        var pool = Agent(id: AgentID(rawValue: "pool"), name: "Postgres pool sizing", spaceID: payments.id, tabID: TabID(rawValue: "pool"),
                         status: .done)
        pool.lastActiveAt = 700
        var flaky = Agent(id: AgentID(rawValue: flakyThread), name: "Fix flaky payment test", spaceID: payments.id,
                          tabID: TabID(rawValue: "flaky"), status: .working)
        flaky.lastActiveAt = 600
        var postcss = Agent(id: AgentID(rawValue: "postcss"), name: "Upgrade PostCSS", spaceID: web.id, tabID: TabID(rawValue: "postcss"))
        postcss.lastActiveAt = 500
        let links = ThreadLinkTable.links([
            .init(state: ShepherdState(spaces: [orders, payments], agents: [pg, retention, pool]), tag: nil, location: ThreadLinkTable.thisMac,
                  statusSince: [pg.id: Date().addingTimeInterval(-18 * 60)]),
            .init(state: ShepherdState(spaces: [payments, web], agents: [flaky, postcss]), tag: "mini", location: "mini"),
        ])
        return SHThreadLinks(links)
    }

    /// The board's conversation: the person asks about the Postgres thread; the reply names three threads, and one it names is gone.
    static var linkSnapshot: NativeThreadSnapshot { linkSnapshot() }

    /// `ask` is the person's message, as typed (or as the @ picker wrote it).
    static func linkSnapshot(ask: String = "Before you touch the orders tables, check what the Postgres thread is doing. "
                             + "I don't want two migrations fighting.", reply: Bool = true) -> NativeThreadSnapshot {
        var snapshot = Threads.empty
        let start = Date().timeIntervalSince1970 * 1000 - 120_000
        snapshot.messages = [
            NativeThreadMessage(entryID: "u0", role: "user", blocks: [.init(kind: .text, text: ask)], timestamp: start),
            NativeThreadMessage(entryID: "a0", role: "assistant", blocks: [.init(kind: .text, text: """
                [the Postgres thread](shepherd-thread://\(pgThread)) is rewriting `orders` and `order_items` right now, in migration 0042. \
                The checkout suite only reads those tables, so the shards I'm adding don't conflict. I'll rebase on its branch once it lands.

                One thing blocks both of us: [retention](shepherd-thread://\(retentionThread)) is waiting on you to choose 30 or 90 days, \
                and 0042 drops the old partitions based on that answer.

                [flaky test](shepherd-thread://\(flakyThread)) is still running on the mini. I'll pull its fix into this branch when it \
                finishes. [The old vacuum thread](shepherd-thread://\(UUID().uuidString.lowercased())) is gone, so its link is just words.
                """)], timestamp: start + 60_000),
        ]
        if !reply { snapshot.messages.removeLast() }
        return snapshot
    }

    private func renderLinks(_ surface: String, snapshot: NativeThreadSnapshot = linkSnapshot, draft: String = "",
                             peek: String? = nil) async throws {
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        let store = fixture.store
        let links = Self.linkTable()
        try await Preview.render(surface, size: Self.linkSize, ready: {
            guard store.ready, !store.rows.isEmpty else { return false }
            if store.draft != draft, !draft.isEmpty { store.draft = draft }
            return true
        }) {
            fixture.thread(title: "Speed up checkout CI", workingDirectory: "~/Developer/payments-api")
                .environment(\.shThreadLinks, links)
                .environment(\.shThreadLinkPeekOpen, peek)
        }
    }

    /// ThreadLinkA · none: the reply's chips, the mini's with its tag; a link to a thread that went is plain words.
    @Test func threadLinkChips() async throws {
        try await renderLinks("thread-link-chips")
    }

    /// ThreadLinkA · peek, from what the host keeps of a working thread: no progress line, so no box.
    @Test func threadLinkPeek() async throws {
        try await renderLinks("thread-link-peek", peek: Self.pgThread)
    }

    /// The peek of a thread that asks you: its question is the box's line.
    @Test func threadLinkPeekAsking() async throws {
        try await renderLinks("thread-link-peek-asking", peek: Self.retentionThread)
    }

    /// ThreadLinkA · mention: "@post" lists the threads it matches, the first selected.
    @Test func threadLinkMention() async throws {
        try await renderLinks("thread-link-mention", draft: "Before you touch the orders tables, check @post")
    }

    /// The message the @ picker wrote, sent: its thread links are chips (the gone one its words), the rest as typed, `**` included.
    @Test func threadLinkBubble() async throws {
        let pg = SHThreadLinks.markdown(title: "Migrate orders to Postgres 17", id: Self.pgThread)
        let ask = "Before you touch the orders tables, check what \(pg) is doing, and whether "
            + "[Fix flaky payment test](shepherd-thread://\(Self.flakyThread)) on the mini still needs them. I **don't** want two "
            + "migrations fighting. [vacuum](shepherd-thread://\(UUID().uuidString.lowercased())) is gone."
        try await renderLinks("thread-link-bubble", snapshot: Self.linkSnapshot(ask: ask))
    }

    /// The bubble's chip, its peek open.
    @Test func threadLinkBubblePeek() async throws {
        let ask = "Check what \(SHThreadLinks.markdown(title: "Migrate orders to Postgres 17", id: Self.pgThread)) is doing first."
        try await renderLinks("thread-link-bubble-peek", snapshot: Self.linkSnapshot(ask: ask, reply: false), peek: Self.pgThread)
    }
}

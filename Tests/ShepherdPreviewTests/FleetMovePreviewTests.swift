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

/// Move a thread to another Mac (FleetMove board), in light and dark, through the real derivations and views: the menu, the confirmation, the
/// queued line, the progress card and the moved thread. Fixture Macs and made-up names only.
@Suite("Fleet move previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL)"))
@MainActor
struct FleetMovePreviewTests {
    typealias P = FleetPagePreviewTests
    static let repo = "github.com/acme/acme-web"
    static let agent = AgentID(rawValue: "checkout-1")
    static let size = CGSize(width: 1000, height: 640)
    static var utc: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }

    /// The conversation of the board: the ask, the work, and a swift test still running (or stopped for the move).
    static func snapshot(moved: Bool, running: Bool) -> NativeThreadSnapshot {
        let move = moved ? #"""
        ,{"entryID":"m","role":"custom","customType":"shepherd.move","blocks":[{"kind":"text","text":"Moved to Mac mini · 14:02 · branch perf/checkout-ci, 3 uncommitted files"}],"truncated":false,"timestamp":1758830600000}
        """# : ""
        let json = #"""
        {"piSessionID":"fixture","generation":"g","revision":1,"running":\#(running),"model":"anthropic/claude-opus-4-5","thinking":"high",
         "supportedActions":["send","abort","answer","setModel","setThinking","sendImages"],"dialogsSupported":true,"dialogs":[],"commands":[],
         "messages":[
          {"entryID":"u","role":"user","blocks":[{"kind":"text","text":"Checkout CI takes 14 minutes. Find what's slow and cut it, without dropping any test."}],"truncated":false,"timestamp":1758830400000},
          {"entryID":"a","role":"assistant","blocks":[{"kind":"text","text":"Two thirds of the time is the integration suite rebuilding its fixtures for every file. Caching them per run should bring it under 6 minutes."}],"truncated":false},
          {"entryID":"t1","role":"toolResult","toolName":"bash","toolCallID":"c1","status":"\#(running ? "running" : "aborted")","argumentsText":"{\"command\":\"swift test --filter CheckoutIntegration\"}","blocks":[{"kind":"text","text":"Building…"}],"truncated":false,"timestamp":1758830500000}
          \#(move)],
         "widgets":[],"provisional":[],"clipped":false,"stats":{"contextTokens":60000,"contextWindow":200000,"contextPercent":30,"totalTokens":1600000}}
        """#
        return try! JSONDecoder().decode(NativeThreadSnapshot.self, from: Data(json.utf8))
    }

    static func snapshotWithRepo() -> FleetSnapshot {
        var snapshot = P.snapshot
        for index in snapshot.macs.indices where snapshot.macs[index].hostID != P.studio { snapshot.macs[index].readiness?.repoKeys = [repo] }
        return snapshot
    }

    static func header(_ chip: FleetMoveChip? = nil, busy: Bool = false, host: UUID = P.here, movedFrom: MovedFrom? = nil) -> FleetMoveHeader {
        let menu = FleetMoveMenu.make(snapshot: snapshotWithRepo(), currentHostID: host, repoKey: repo, repoName: "acme-web", weight: { _ in .normal },
                                      locale: Locale(identifier: "en_GB"), calendar: utc)!
        return FleetMoveHeader(chip: chip ?? FleetMoveChip.make(host: menu.here.name, tone: menu.here.tone, movedFrom: movedFrom, thisFleetID: P.here,
                                                                locale: Locale(identifier: "en_GB"), calendar: utc),
                               menu: menu, busy: busy)
    }

    static func record(_ state: FleetDispatchState, _ stage: FleetMoveStage) -> FleetDispatchRecord {
        var record = FleetDispatchRecord(kind: .move, parentAgentID: agent, parentHostID: P.here, parentHostName: "MacBook Pro", targetHostID: P.mini,
                                         targetHostName: "Mac mini", state: state, title: "Speed up checkout CI", task: "", repoKey: repo,
                                         move: FleetMoveInfo(agentID: agent, stage: stage, sessionID: "s1", whenDone: state == .waitingTurn, messages: 412,
                                                             transcriptBytes: 1_800_000, uncommittedFiles: 3, unpushedCommits: 1), createdAt: 100)
        record.snapshotBytes = 46_000
        return record
    }

    /// The thread as the board draws it: header with the chip, the card, the conversation.
    func thread(_ fixture: ThreadFixture, header: FleetMoveHeader, card: FleetMoveCard? = nil, working: Bool = false) -> some View {
        var surface = FleetThreadSurface(cards: [], parent: Self.agent, actions: FleetThreadActions())
        surface.move = card
        return VStack(spacing: 0) {
            ThreadHeader(store: fixture.store, project: "acme-web", title: "Speed up checkout CI", move: header, moveWorking: working, moveTo: { _, _ in })
            ThreadView(store: fixture.store, active: true, isFocused: false, request: fixture.request, commandKey: "preview", agentName: "Speed up checkout CI",
                       workingDirectory: "~/Developer/acme-web", inspectSubagent: nil, review: { _ in })
        }
        .background(Color.sh.bgWindow)
        .environment(\.threadCommands, fixture.commands)
        .environment(\.fleetThread, surface)
    }

    func popover<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().shPopover().padding(.top, SH.Space.xl + SH.Space.xxl).padding(.leading, SH.Space.xxxl * 4)
    }

    @Test func theMenuListsTheMacsWithRoomAndANote() async throws {
        let header = Self.header()
        #expect(header.menu.targets[0].note == "Most room · has acme-web · 3 working" && header.menu.targets[1].note.hasPrefix("Asleep since "))
        let fixture = ThreadFixture(Self.snapshot(moved: false, running: true))
        defer { fixture.store.stop() }
        try await Preview.renderMatrix("fleet-move-menu", size: Self.size, ready: { fixture.store.ready }) {
            thread(fixture, header: header, working: true)
                .overlay(alignment: .topLeading) { popover { FleetMoveMenuView(menu: header.menu) { _ in } } }
        }
    }

    @Test func movingWhileACommandRunsAsksFirst() async throws {
        let header = Self.header()
        let fixture = ThreadFixture(Self.snapshot(moved: false, running: true))
        defer { fixture.store.stop() }
        var call = NativeActivityCall(NativeThreadMessage(entryID: "t1", role: "toolResult", blocks: [], toolName: "bash", toolCallID: "c1",
                                                          argumentsText: #"{"command":"swift test --filter CheckoutIntegration"}"#, status: "running"))
        call.startedAt = Date().timeIntervalSince1970 * 1000 - 120_000
        let facts = FleetMoveConfirm.make(running: call, host: "Mac mini")
        #expect(facts.title == "It’s running a command" && facts.message.contains("for 2 minutes"))
        try await Preview.renderMatrix("fleet-move-confirm", size: Self.size, ready: { fixture.store.ready }) {
            thread(fixture, header: header, working: true)
                .overlay(alignment: .topLeading) { popover { FleetMoveConfirmView(host: "Mac mini", facts: facts, whenDone: {}, now: {}) } }
        }
    }

    @Test func aMoveWaitingForTheTurnIsALineWithCancel() async throws {
        let card = try #require(FleetMoveCard.make(Self.record(.waitingTurn, .waitingTurn)))
        let fixture = ThreadFixture(Self.snapshot(moved: false, running: true))
        defer { fixture.store.stop() }
        try await Preview.renderMatrix("fleet-move-queued", size: Self.size, ready: { fixture.store.ready }) {
            thread(fixture, header: Self.header(busy: true), card: card, working: true)
        }
    }

    @Test func aMoveInFlightShowsItsFourSteps() async throws {
        let card = try #require(FleetMoveCard.make(Self.record(.preparing, .worktree)))
        #expect(card.steps.map(\.mark) == [.done, .done, .current, .later])
        let fixture = ThreadFixture(Self.snapshot(moved: false, running: false))
        defer { fixture.store.stop() }
        try await Preview.renderMatrix("fleet-move-moving", size: Self.size, ready: { fixture.store.ready }) {
            thread(fixture, header: Self.header(busy: true), card: card)
        }
    }

    @Test func aMoveThatFailedSaysItAndTheThreadIsStillHere() async throws {
        var record = Self.record(.failed, .worktree)
        record.failure = FleetDispatchCode.peerGone
        let card = try #require(FleetMoveCard.make(record))
        let fixture = ThreadFixture(Self.snapshot(moved: false, running: false))
        defer { fixture.store.stop() }
        try await Preview.renderMatrix("fleet-move-failed", size: Self.size, ready: { fixture.store.ready }) {
            thread(fixture, header: Self.header(), card: card)
        }
    }

    @Test func theMovedThreadSaysWhereItCameFromAndDrawsTheDivider() async throws {
        let from = MovedFrom(hostID: P.here, hostName: "MacBook Pro", at: 1_789_999_320_000, moveID: UUID(), branch: "perf/checkout-ci", uncommittedFiles: 3)
        let header = Self.header(host: P.mini, movedFrom: from)
        #expect(header.chip.text == "Mac mini" && header.chip.movedFrom?.hasPrefix("moved from This Mac · ") == true)
        let fixture = ThreadFixture(Self.snapshot(moved: true, running: false))
        defer { fixture.store.stop() }
        try await Preview.renderMatrix("fleet-move-moved", size: Self.size, ready: { fixture.store.ready }) {
            thread(fixture, header: header)
        }
    }
}

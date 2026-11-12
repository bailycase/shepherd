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

/// Slice 4d: the thread surfaces of a dispatch, in light and dark (FleetDispatch, FleetRemote, FleetNewThread, FleetSidebar, FleetStates, FleetA),
/// through the real derivations and views. Fixture Macs and made-up names only.
@Suite("Fleet dispatch previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL)"))
@MainActor
struct FleetDispatchPreviewTests {
    typealias P = FleetPagePreviewTests
    static let sender = AgentID(rawValue: "sender-1")
    static let toolCall = "call_1"
    static let senderTitle = "Speed up checkout CI"

    static var context: FleetCardContext { FleetCardContext(snapshot: P.snapshot, cap: 3, locale: Locale(identifier: "en_US")) }

    static func record(_ state: FleetDispatchState, title: String = "Fix flaky payment test", target: UUID? = P.mini, host: String? = "Mac mini",
                       kind: FleetDispatchRecord.Kind = .agentDispatch, reasons: [FleetPlacementReason] = [FleetPlacementReason(.localIneligible, skip: "cpu"), FleetPlacementReason(.mostRoom, ratio: 3.4)],
                       failure: String? = nil, id: UUID? = nil, at: Double = 100) -> FleetDispatchRecord {
        var record = FleetDispatchRecord(
            id: id ?? UUID(), kind: kind, parentAgentID: kind == .userThread ? nil : sender, parentHostID: P.here, parentHostName: "MacBook Pro",
            parentTitle: kind == .userThread ? "" : senderTitle, targetHostID: target, targetHostName: host, state: state, failure: failure, title: title,
            task: "Fix the flaky payment test.", repoKey: "github.com/acme/payments-api", commitSHA: "4e1c9a2" + String(repeating: "0", count: 33),
            branch: "fleet/fix-flaky-payment", reasonCodes: reasons, remoteAgentID: [.running, .done].contains(state) ? AgentID(rawValue: "mini-1") : nil, createdAt: at)
        record.updatedAt = at
        return record
    }

    static func surface(_ records: [FleetDispatchRecord], sentBy: FleetSentBy? = nil, goesBack: Bool = false) -> FleetThreadSurface {
        let cards = FleetDispatchPresentation.cards(records, in: context)
        return FleetThreadSurface(sentBy: sentBy, goesBack: goesBack, cards: cards, parent: sender, actions: FleetThreadActions())
    }

    // MARK: FleetDispatch: the parent thread

    /// The thread that sent work: the dispatch card where its `fleet_dispatch` call is, then (once the thread finished) the result it got back.
    static func parentSnapshot(done: Bool) -> NativeThreadSnapshot {
        let result = done ? #"""
        ,{"entryID":"u2","role":"user","blocks":[{"kind":"text","text":"[from: Fix flaky payment test on Mac mini, an agent, not the user. Reply with agent_send only if this asks for a reply.] Result from Fix flaky payment test on Mac mini:\nFixed: the test raced the clock. It now waits on the fake clock instead of sleeping, so it passes 200 runs in a row. Changed `PaymentRetryTests` and `FakeClock`.\n\nBranch fleet/fix-flaky-payment: 2 commits ahead of the start, pushed to origin, 3 files changed (+41 -9)."}],"truncated":false,"timestamp":1758831060000}
        """# : ""
        let json = #"""
        {"piSessionID":"fixture","generation":"g","revision":1,"running":false,"model":"anthropic/claude-opus-4-5","thinking":"high",
         "supportedActions":["send","abort","answer","setModel","setThinking","sendImages"],"dialogsSupported":true,"dialogs":[],"commands":[],
         "messages":[
          {"entryID":"u","role":"user","blocks":[{"kind":"text","text":"Checkout CI takes 14 minutes. Find out why and speed it up. Hand the flaky payment test to another Mac so it doesn't block you."}],"truncated":false,"timestamp":1758830400000},
          {"entryID":"a","role":"assistant","blocks":[{"kind":"text","text":"The slow part is the serial test run. I'll split the suites, and send the flaky payment test to another Mac to fix in parallel."}],"truncated":false},
          {"entryID":"t1","role":"toolResult","toolName":"fleet_dispatch","toolCallID":"call_1","status":"complete","argumentsText":"{\"task\":\"Fix the flaky payment test.\",\"title\":\"Fix flaky payment test\"}","blocks":[{"kind":"text","text":"Sent to Mac mini."}],"truncated":false},
          {"entryID":"a2","role":"assistant","blocks":[{"kind":"text","text":"It's running on Mac mini. I'll carry on with the suite split here and read its result when it arrives."}],"truncated":false}
          \#(result)],
         "widgets":[],"provisional":[],"clipped":false,"stats":{"contextTokens":60000,"contextWindow":200000,"contextPercent":30,"totalTokens":1600000}}
        """#
        return try! JSONDecoder().decode(NativeThreadSnapshot.self, from: Data(json.utf8))
    }

    @Test func dispatchCardsInTheParentThread() async throws {
        let id = try #require(FleetDispatchID.forToolCall(Self.toolCall, agent: Self.sender))
        for (name, state, done) in [("fleet4d-dispatch-working", FleetDispatchState.running, false), ("fleet4d-dispatch-result", .done, true)] {
            let fixture = ThreadFixture(Self.parentSnapshot(done: done))
            defer { fixture.store.stop() }
            let surface = Self.surface([Self.record(state, id: id)])
            try await Preview.renderMatrix(name, size: CGSize(width: 1000, height: 820), ready: { fixture.store.ready }) {
                fixture.thread(title: Self.senderTitle).environment(\.fleetThread, surface)
            }
        }
    }

    // MARK: FleetRemote: the dispatched thread

    static func dispatchedSnapshot(sentBy: String?) -> NativeThreadSnapshot {
        let first = "Fix the flaky payment test: it fails about one run in ten on CI. Find the race and fix it without adding retries."
            + FleetDispatchProtocol.promptSeparator + "\(sentBy ?? "the person") on MacBook Pro to do the task above. Your branch is fleet/fix-flaky-payment. Commit your work there and push it with git push -u origin fleet/fix-flaky-payment."
        let escaped = String(data: try! JSONEncoder().encode(first), encoding: .utf8)!
        let json = #"""
        {"piSessionID":"fixture","generation":"g","revision":1,"running":true,"model":"anthropic/claude-opus-4-5","thinking":"high",
         "supportedActions":["send","abort","answer","setModel","setThinking","sendImages"],"dialogsSupported":true,"dialogs":[],"commands":[],
         "messages":[
          {"entryID":"u","role":"user","blocks":[{"kind":"text","text":\#(escaped)}],"truncated":false,"timestamp":1758830040000},
          {"entryID":"a","role":"assistant","blocks":[{"kind":"text","text":"I'll start with the test and the clock it reads."}],"truncated":false},
          {"entryID":"t1","role":"toolResult","toolName":"read","toolCallID":"c1","status":"complete","argumentsText":"{\"path\":\"Tests/PaymentRetryTests.swift\"}","blocks":[{"kind":"text","text":"struct PaymentRetryTests {}"}],"truncated":false},
          {"entryID":"a2","role":"assistant","blocks":[{"kind":"text","text":"The test sleeps for 50 ms and then asserts on a retry count that a timer sets. Replacing the sleep with the fake clock."}],"truncated":false}],
         "widgets":[],"provisional":[],"clipped":false,"stats":{"contextTokens":30000,"contextWindow":200000,"contextPercent":15,"totalTokens":300000}}
        """#
        return try! JSONDecoder().decode(NativeThreadSnapshot.self, from: Data(json.utf8))
    }

    func remoteThread(_ fixture: ThreadFixture, sentBy: FleetSentBy, online: Bool, offline: FleetOfflineBanner? = nil) -> some View {
        var surface = FleetThreadSurface(sentBy: sentBy, dispatched: nil, goesBack: sentBy.fromThread, cards: [], parent: nil, actions: FleetThreadActions())
        surface.offline = offline != nil
        return VStack(spacing: 0) {
            ThreadHeader(store: fixture.store, project: "payments-api", title: "Fix flaky payment test", sentBy: sentBy, sentByOnline: online, openSender: sentBy.fromThread ? {} : nil)
            if let offline { FleetOfflineBannerView(banner: offline, retry: {}) }
            ThreadView(store: fixture.store, active: true, isFocused: false, request: fixture.request, commandKey: "preview", agentName: "Fix flaky payment test",
                       workingDirectory: "~/Developer/payments-api", inspectSubagent: nil, review: { _ in })
        }
        .background(Color.sh.bgWindow)
        .environment(\.threadCommands, fixture.commands)
        .environment(\.fleetThread, surface)
    }

    @Test func theDispatchedThreadOnlineAndOffline() async throws {
        let from = DispatchedFrom(hostID: P.here, hostName: "MacBook Pro", agentID: Self.sender, agentTitle: Self.senderTitle, dispatchID: UUID(), at: 1_758_830_040_000)
        var sentBy = FleetSentBy(from, host: "Mac mini", viewer: P.mini)
        sentBy.senderOpens = true
        let fixture = ThreadFixture(Self.dispatchedSnapshot(sentBy: Self.senderTitle))
        defer { fixture.store.stop() }
        try await Preview.renderMatrix("fleet4d-remote-online", size: CGSize(width: 1000, height: 720), ready: { fixture.store.ready }) {
            remoteThread(fixture, sentBy: sentBy, online: true)
        }
        let away = ThreadFixture(Self.dispatchedSnapshot(sentBy: Self.senderTitle))
        defer { away.store.stop() }
        let banner = FleetOfflineBanner(host: "Mac mini", lastSeen: Date().timeIntervalSince1970 * 1000 - 2 * 60_000)
        try await Preview.renderMatrix("fleet4d-remote-offline", size: CGSize(width: 1000, height: 720), ready: { away.store.ready }) {
            remoteThread(away, sentBy: sentBy, online: false, offline: banner)
        }
        // A thread the person started in New thread: sent by you, and nothing goes back.
        let mine = DispatchedFrom(hostID: P.here, hostName: "MacBook Pro", agentID: nil, agentTitle: "", dispatchID: UUID(), at: 1_758_830_040_000)
        let byYou = FleetSentBy(mine, host: "Mac mini", viewer: P.mini)
        let user = ThreadFixture(Self.dispatchedSnapshot(sentBy: nil))
        defer { user.store.stop() }
        try await Preview.renderMatrix("fleet4d-remote-by-you", size: CGSize(width: 1000, height: 720), ready: { user.store.ready }) {
            remoteThread(user, sentBy: byYou, online: true)
        }
    }

    // MARK: FleetStates: a card per state

    @Test func everyStateCard() async throws {
        let records = [
            Self.record(.placing, title: "Index the changelog", at: 1),
            Self.record(.waitingRoom, title: "Migrate orders to Postgres 17", at: 2),
            Self.record(.waitingWake, title: "Profile cold launch", target: P.studio, host: "Mac Studio", reasons: [FleetPlacementReason(.named)], at: 3),
            Self.record(.heldLimit, title: "Add retry to webhooks", target: nil, host: nil, at: 4),
            Self.record(.heldRestart, title: "Regenerate API client", target: nil, host: nil, at: 5),
            Self.record(.preparing, title: "Bump Swift tools to 6.2", at: 6),
            Self.record(.failed, title: "Index the docs", target: nil, host: nil, failure: FleetDispatchCode.repoMissing, at: 7),
            Self.record(.failed, title: "Sync the fixtures", failure: FleetDispatchCode.commitUnreachable, at: 8),
            Self.record(.running, title: "Fix flaky payment test", at: 9),
        ]
        let running = (0..<2).map { Self.record(.running, title: "Running \($0)", at: Double(20 + $0)) }
        let cards = FleetDispatchPresentation.cards(records + running, in: Self.context).filter { $0.layout == .state || $0.title == "Fix flaky payment test" }
        var snapshot = P.snapshot
        snapshot.sync = FleetSyncStatus(peers: [FleetSyncStatus.Peer(hostID: P.mini, name: "Mac mini", state: .catchingUp)])
        let behind = FleetDispatchPresentation.behind(snapshot)
        try await Preview.renderMatrix("fleet4d-states", size: CGSize(width: 760, height: 1180)) {
            ScrollView {
                VStack(spacing: SH.Space.l) {
                    ForEach(cards) { FleetDispatchCardView(card: $0, actions: FleetThreadActions()).equatable() }
                    ForEach(behind) { FleetBehindMacCard(mac: $0) }
                }
                .padding(SH.Space.xxl)
            }
            .frame(width: 760, height: 1180)
            .background(Color.sh.bgWindow)
        }
    }

    // MARK: FleetSidebar

    @Test func theSidebarNestsADispatchedThreadUnderItsSender() async throws {
        let space = Space(name: "payments-api", path: "/Users/dev/payments-api")
        let remoteSpace = Space(name: "payments-api", path: "/srv/payments-api")
        func agent(_ name: String, _ status: AgentStatus, _ space: Space, at: Double, from: AgentID? = nil, fromHost: UUID = P.here) -> Agent {
            var agent = Agent(name: name, spaceID: space.id, tabID: TabID())
            agent.status = status
            agent.lastActiveAt = Date().timeIntervalSince1970 * 1000 - at * 60_000
            if let from { agent.dispatchedFrom = DispatchedFrom(hostID: fromHost, hostName: "MacBook Pro", agentID: from, agentTitle: Self.senderTitle, dispatchID: UUID(), at: 1) }
            return agent
        }
        var senderAgent = agent(Self.senderTitle, .working, space, at: 2)
        senderAgent.id = Self.sender
        let migrate = agent("Migrate orders to Postgres 17", .working, space, at: 6)
        let regenerate = agent("Regenerate API client", .idle, space, at: 40)
        let child = agent("Fix flaky payment test", .working, remoteSpace, at: 1, from: Self.sender)
        let asleep = agent("Profile cold launch", .idle, remoteSpace, at: 90, from: AgentID(rawValue: "gone"))
        let host = SidebarSource.Host(id: UUID(), name: "Mac mini", state: ShepherdState(spaces: [remoteSpace], agents: [child]), fleetID: P.mini)
        var sleeping = SidebarSource.Host(id: UUID(), name: "Mac Studio", state: ShepherdState(spaces: [remoteSpace], agents: [asleep]), fleetID: P.studio)
        sleeping.offline = true
        let source = SidebarSource(local: ShepherdState(spaces: [space], agents: [senderAgent, migrate, regenerate]), localFleetID: P.here, hosts: [host, sleeping])
        let lists = SidebarDerivation.lists(source)
        #expect(lists.working.map(\.title) == [Self.senderTitle, "Fix flaky payment test", "Migrate orders to Postgres 17"])
        #expect(lists.working.map(\.fleetNested) == [false, true, false])
        let rows = lists.sections.flatMap { section in [section.rows] }.flatMap { $0 }
        try await Preview.renderMatrix("fleet4d-sidebar", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 360)) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows, id: \.id) { row in
                    SHSidebarRow(row.title, leading: row.leading, selected: false, dimmed: row.offline, accessory: row.accessory, hasGoal: row.hasGoal,
                                 nested: row.fleetNested, badge: row.pullRequest, elbow: row.fleetNested)
                }
            }
            .padding(SH.Space.m)
            .frame(width: AppLayout.sidebarDefaultWidth, height: 360, alignment: .topLeading)
            .background(Color.sh.bgBase)
        }
    }

    // MARK: FleetNewThread

    @Test func newThreadWithAutoAndItsPopover() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        var space = Space(name: "orders-svc", path: workspace.dir.path)
        space.repoKey = "github.com/acme/orders-svc"
        try await workspace.seed(ShepherdState(spaces: [space]))
        P.seedFleet(workspace)
        var snapshot = P.snapshot
        for index in snapshot.macs.indices where snapshot.macs[index].hostID != P.studio {
            snapshot.macs[index].readiness?.repoKeys = ["github.com/acme/orders-svc"]
            snapshot.macs[index].readiness?.missing = []
        }
        vm.fleetPage.update(snapshot)
        vm.openNewThread()
        try await eventuallyOnMain("the New thread page's defaults") { !vm.newThread.loadingDefaults && vm.newThread.place != nil }
        vm.newThread.prompt = "Profile the orders import and cut its memory in half"
        let picker = vm.newThread.fleetPicker(vm)
        #expect(picker.chip == "Auto · Mac mini" && picker.dispatches && picker.options.map(\.name) == ["Auto", "Mac mini", "This Mac", "Mac Studio"])
        try await Preview.renderMatrix("fleet4d-new-thread-chip", size: CGSize(width: 1280, height: 760)) {
            NewThreadPage(vm: vm, chrome: PageHeaderChrome())
        }
        try await Preview.renderMatrix("fleet4d-new-thread-popover", size: CGSize(width: 1280, height: 760)) {
            NewThreadPage(vm: vm, chrome: PageHeaderChrome(), whereOpen: true)
        }
    }

    // MARK: Settings ▸ Fleet ▸ Dispatch, and the Fleet page's placement card

    @Test func settingsDispatchSection() async throws {
        let model = FleetPreviewTests.model(peers: FleetPreviewTests.peers)
        let state = DispatchState()
        try await Preview.renderMatrix("fleet4d-settings-dispatch", size: CGSize(width: 1000, height: 1240)) {
            FleetSettings(model: model, serviceKeepsRunning: true, dispatch: FleetDispatchControls(
                autoDispatch: .constant(true), threadsCanSend: .constant(true), threadCap: .constant(state.cap), batteryCountsHalf: .constant(true)))
                .frame(width: 1000, height: 1240).background(Color.sh.bgWindow)
        }
    }

    final class DispatchState { let cap = 3 }

    @Test func fleetPagePlacementCard() async throws {
        var snapshot = P.snapshot
        snapshot.dispatches = [Self.record(.running, at: 100), Self.record(.waitingWake, title: "Profile cold launch", target: P.studio, host: "Mac Studio", at: 90)]
        let on = FleetPagePresentation.make(snapshot: snapshot, weight: { _ in .normal }, autoDispatch: true)
        let off = FleetPagePresentation.make(snapshot: snapshot, weight: { _ in .normal }, autoDispatch: false)
        try await Preview.renderMatrix("fleet4d-page-auto-on", size: CGSize(width: 1208, height: 900)) {
            FleetPageContent(page: on, actions: P.noActions).frame(width: 1208, height: 900)
        }
        try await Preview.render("fleet4d-page-auto-off", size: CGSize(width: 1208, height: 900)) {
            FleetPageContent(page: off, actions: P.noActions).frame(width: 1208, height: 900)
        }
    }
}

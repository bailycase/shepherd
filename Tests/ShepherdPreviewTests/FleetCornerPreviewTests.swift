import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
import Vision
@testable import ShepherdApp

/// The user's sidebar redesign in light and dark (FleetCornerFull, FleetCornerMin, FleetCornerMany, FleetCornerManyMin, FleetSubthreads, SidebarTree): the
/// real sidebar through the real view model, with fixture Macs, their dispatch records and a connected Mac's threads. Made-up names only.
@Suite("Fleet corner previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL)"))
@MainActor
struct FleetCornerPreviewTests {
    typealias P = FleetPagePreviewTests
    static let size = CGSize(width: AppLayout.sidebarDefaultWidth, height: 900)
    static let miniLink = UUID()

    // MARK: The Macs

    /// This Mac busy with 3 threads, the mini with room and 2 working, a Mac Studio asleep.
    static var threeMacs: FleetSnapshot {
        var snapshot = P.snapshot
        snapshot.macs[1].sample?.activeAgents = 2
        snapshot.macs[1].readiness?.missing = []
        return snapshot
    }

    /// The same, with the mini so quiet that Auto sends the next work there.
    static var threeMacsMiniNext: FleetSnapshot {
        var snapshot = threeMacs
        snapshot.macs[1].sample?.cpuUtilization = 0.04
        return snapshot
    }

    /// Twelve Macs: This Mac, the mini with the most room, a Mac Studio asleep with work waiting for it, a build Mac without Xcode, and eight more, two of them
    /// asleep.
    static var twelveMacs: FleetSnapshot {
        var snapshot = threeMacsMiniNext
        snapshot.macs[1].sample?.activeAgents = 0
        let sample = FleetPressureSample(cpuUtilization: 0.4, cpuCount: 12, totalMemoryBytes: 64 * P.gib, availableMemoryBytes: 41 * P.gib, activeAgents: 0)
        for index in 4...12 {
            let id = UUID()
            let name = "build-\(String(format: "%02d", index))"
            let asleep = index >= 11
            snapshot.peers.append(FleetPeerStatus(hostID: id, name: name, pairedAt: 3, link: asleep ? .offline : .connected, lastSeen: asleep ? P.seenAt : nil))
            snapshot.macs.append(FleetMacState(hostID: id, sample: asleep ? nil : sample, sampleAge: asleep ? nil : 1,
                                               readiness: FleetReadinessReport(model: "Mac mini", chip: "M4", missing: index == 4 ? [FleetMissingTool(kind: .xcode)] : [])))
        }
        // `build-04` is the fourth peer: put it where the board lists it, and the rest after.
        snapshot.dispatches = [FleetDispatchRecord(parentHostID: P.here, parentHostName: "MacBook Pro", targetHostID: P.studio, targetHostName: "Mac Studio",
                                                   state: .waitingWake, title: "Profile cold launch", task: "", repoKey: "github.com/acme/payments-api", createdAt: 1)]
        return snapshot
    }

    /// The sidebar over a workspace with a few threads, Fleet on with `snapshot`.
    func sidebar(_ snapshot: FleetSnapshot, minimized: Bool, style: SHSidebarStyle = .activity) async throws -> (PreviewWorkspace, ShepherdViewModel) {
        let workspace = try PreviewWorkspace()
        let space = Space(name: "payments-api", path: workspace.dir.path)
        var rows: [(Agent, ShepherdCore.Tab)] = []
        for (index, (name, status)) in [("Pick a retention window", AgentStatus.blocked), ("Speed up checkout CI", .working),
                                        ("Migrate orders to Postgres 17", .working), ("Regenerate API client", .idle)].enumerated() {
            var (agent, tab) = try await workspace.agent(name, in: space, order: index, status: status)
            agent.lastActiveAt = Date().timeIntervalSince1970 * 1000 - Double(index) * 60_000
            if status == .blocked { agent.waitingOn = "Keep 30 or 90 days?"; agent.waitingReason = "asked you" }
            rows.append((agent, tab))
        }
        try await workspace.seed(ShepherdState(spaces: [space], tabs: rows.map(\.1), agents: rows.map(\.0)))
        P.seedFleet(workspace)
        workspace.vm.fleetPage.update(snapshot)
        workspace.vm.fleetCornerMinimized = minimized
        workspace.settings.sidebarStyle = style
        return (workspace, workspace.vm)
    }

    // MARK: FleetCornerFull, FleetCornerMin, FleetCornerMany, FleetCornerManyMin

    @Test func theCornerFullAndMinimized() async throws {
        for (name, snapshot, minimized) in [("fleet-corner-full", Self.threeMacs, false), ("fleet-corner-min", Self.threeMacs, true),
                                            ("fleet-corner-many", Self.twelveMacs, false), ("fleet-corner-many-min", Self.twelveMacs, true)] {
            let (workspace, vm) = try await sidebar(snapshot, minimized: minimized)
            defer { workspace.stop() }
            let corner = try #require(vm.fleetPage.corner)
            #expect(corner.rows.count >= 3 && corner.folded == (snapshot.peers.count > 4))
            try await Preview.renderMatrix(name, size: Self.size) { SidebarView(vm: vm).frame(width: Self.size.width, height: Self.size.height) }
        }
    }

    /// Both sidebar styles carry the same corner: the Spaces tree over the same Macs.
    @Test func theCornerInSpacesStyle() async throws {
        for (name, snapshot, minimized) in [("fleet-corner-spaces", Self.threeMacs, false), ("fleet-corner-spaces-many-min", Self.twelveMacs, true)] {
            let (workspace, vm) = try await sidebar(snapshot, minimized: minimized, style: .projects)
            defer { workspace.stop() }
            try await Preview.renderMatrix(name, size: Self.size) { SidebarView(vm: vm).frame(width: Self.size.width, height: Self.size.height) }
        }
    }

    /// The corner's states beside each other, as the page's Mac cards: asleep with work waiting, a Mac that can't take work, connecting.
    @Test func theCornerStatesTogether() async throws {
        var snapshot = Self.threeMacs
        snapshot.peers[0].link = .connecting
        let build = UUID()
        snapshot.peers.append(FleetPeerStatus(hostID: build, name: "build-04", pairedAt: 3, link: .connected))
        snapshot.macs.append(FleetMacState(hostID: build, sample: snapshot.macs[1].sample, sampleAge: 1,
                                           readiness: FleetReadinessReport(model: "Mac mini", chip: "M4", missing: [FleetMissingTool(kind: .xcode)])))
        snapshot.dispatches = [FleetDispatchRecord(parentHostID: P.here, parentHostName: "MacBook Pro", targetHostID: P.studio, targetHostName: "Mac Studio",
                                                   state: .waitingWake, title: "Profile cold launch", task: "", repoKey: "github.com/acme/web", createdAt: 1)]
        let corner = try #require(FleetCorner.make(P.page(snapshot)))
        #expect(corner.rows.map(\.dot) == [.awake, .connecting, .asleep, .blocked])
        try await Preview.renderMatrix("fleet-corner-states", size: CGSize(width: Self.size.width, height: 240)) {
            FleetCornerView(corner: corner, minimized: false, onPage: true, focusedMac: P.mini, open: { _ in }, setMinimized: { _ in }, settings: {})
                .frame(width: Self.size.width)
                .background(Color.sh.bgBase)
        }
    }

    // MARK: FleetSubthreads

    /// The threads the sidebar scenes draw: This Mac's, the connected mini's, and the dispatch records This Mac keeps.
    struct Cast {
        var local: [Agent] = []
        var mini: [Agent] = []
        var records: [FleetDispatchRecord] = []
    }

    static func thread(_ name: String, _ status: AgentStatus, in space: Space, at minutes: Double, from sender: Agent? = nil, senderHost: UUID = P.here,
                       senderHostName: String = "MacBook Pro", dispatch: UUID = UUID(), seen: Bool = false) -> Agent {
        var agent = Agent(name: name, spaceID: space.id, tabID: TabID(), status: status, nameIsFinal: true)
        agent.lastActiveAt = Date().timeIntervalSince1970 * 1000 - minutes * 60_000
        if let sender {
            agent.dispatchedFrom = DispatchedFrom(hostID: senderHost, hostName: senderHostName, agentID: sender.id, agentTitle: sender.name, dispatchID: dispatch,
                                                  at: agent.lastActiveAt ?? 0)
        }
        if status == .done {
            agent.completedAt = agent.lastActiveAt
            if seen { agent.seenCompletedAt = agent.lastActiveAt }
        }
        return agent
    }

    static func record(_ state: FleetDispatchState, _ title: String, sender: Agent?, id: UUID = UUID(), target: UUID? = P.mini, host: String? = "Mac mini",
                       minutes: Double, clone: String? = nil, failure: String? = nil, detail: String? = nil, kind: FleetDispatchRecord.Kind? = nil) -> FleetDispatchRecord {
        let at = Date().timeIntervalSince1970 * 1000 - minutes * 60_000
        var record = FleetDispatchRecord(id: id, kind: kind ?? (sender == nil ? .userThread : .agentDispatch), parentAgentID: sender?.id, parentHostID: P.here,
                                         parentHostName: "MacBook Pro", parentTitle: sender?.name ?? "", targetHostID: target, targetHostName: host, state: state,
                                         failure: failure, failureDetail: detail, title: title, task: "", repoKey: "github.com/acme/payments-web",
                                         clone: clone.map { FleetCloneProgress(name: $0, source: "github.com/acme/payments-web") }, createdAt: at)
        record.updatedAt = at
        return record
    }

    /// Mounts the cast: This Mac's threads in the workspace, the mini as a connected Mac with its own.
    func mount(_ cast: Cast, minimized: Bool = false, style: SHSidebarStyle = .activity, cap: Int = 3, selected: AgentID? = nil) async throws -> (PreviewWorkspace, ShepherdViewModel) {
        let workspace = try PreviewWorkspace()
        let space = Space(name: "payments-api", path: workspace.dir.path)
        var tabs: [ShepherdCore.Tab] = []
        var local: [Agent] = []
        for (index, var agent) in cast.local.enumerated() {
            let pane = LeafPane(cwd: space.path, agentID: agent.id)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: index, layout: .leaf(pane))
            agent.spaceID = space.id
            agent.tabID = tab.id
            agent.paneID = pane.id
            tabs.append(tab)
            local.append(agent)
        }
        try await workspace.seed(ShepherdState(spaces: [space], tabs: tabs, agents: local))
        P.seedFleet(workspace)
        var snapshot = Self.threeMacs
        // A record names the sender's space, as the host writes it.
        snapshot.dispatches = cast.records.map { record in
            var record = record
            record.spaceID = space.id
            return record
        }
        workspace.vm.fleetPage.threadCap = { cap }
        workspace.vm.fleetPage.update(snapshot)
        workspace.vm.fleetCornerMinimized = minimized
        workspace.settings.sidebarStyle = style
        let remoteSpace = Space(name: "payments-api", path: "/srv/payments-api")
        let mini = cast.mini.map { agent -> Agent in
            var agent = agent
            agent.spaceID = remoteSpace.id
            return agent
        }
        workspace.vm.sidebarSourceAdjust = { source in
            var source = source
            source.localFleetID = P.here
            source.hosts.append(SidebarSource.Host(id: Self.miniLink, name: "Mac mini", state: ShepherdState(spaces: [remoteSpace], agents: mini), fleetID: P.mini))
            return source
        }
        if let selected { workspace.vm.selectAgent(selected) }
        return (workspace, workspace.vm)
    }

    /// FleetCornerFull's sidebar: a thread asking you from another, a sender with a sent thread delivering and one waiting for a Mac to wake, a thread on the
    /// mini with the thread it sent here asking you, one that folds, work with nowhere to go, and what came back.
    @Test func theSidebarAsTheCornerBoardDrawsIt() async throws {
        let space = Space(name: "payments-api", path: "/tmp/p")
        var retention = Self.thread("Pick a retention window", .blocked, in: space, at: 2)
        retention.waitingOn = "Keep 30 or 90 days?"
        retention.waitingReason = "asked you"
        let speed = Self.thread("Speed up checkout CI", .working, in: space, at: 1)
        let harden = Self.thread("Harden webhook retries", .working, in: space, at: 8)
        // Migrate runs on the mini, and sent Backfill here: it asks you, so it is in Needs you too.
        let migrate = Self.thread("Migrate orders to Postgres 17", .working, in: space, at: 6)
        var backfill = Self.thread("Backfill order totals", .blocked, in: space, at: 3, from: migrate, senderHost: P.mini, senderHostName: "Mac mini")
        backfill.waitingOn = "Which batch size?"
        let flaky = UUID(), bump = UUID()
        let fixFlaky = Self.thread("Fix flaky payment test", .working, in: space, at: 4, from: speed, dispatch: flaky)
        let bumpTools = Self.thread("Bump Swift tools to 6.2", .done, in: space, at: 5, from: speed, dispatch: bump)
        var regenerate = Self.thread("Regenerate API client", .done, in: space, at: 9)
        regenerate.dispatchedFrom = DispatchedFrom(hostID: P.studio, hostName: "Mac Studio", agentID: AgentID(), agentTitle: "Release prep", dispatchID: UUID(), at: 1)
        var hardenKids: [Agent] = [], hardenRecords: [FleetDispatchRecord] = []
        for (index, state) in [FleetDispatchState.running, .running, .done, .done].enumerated() {
            let dispatch = UUID()
            hardenKids.append(Self.thread("Webhook task \(index + 1)", state == .done ? .done : .working, in: space, at: 10 + Double(index), from: harden, dispatch: dispatch, seen: true))
            hardenRecords.append(Self.record(state, "Webhook task \(index + 1)", sender: harden, id: dispatch, minutes: 10 + Double(index)))
        }
        var cast = Cast()
        cast.local = [retention, speed, harden, backfill] + (1...3).map { Self.thread("Old thread \($0)", .idle, in: space, at: 60 + Double($0)) }
        cast.mini = [migrate, fixFlaky, bumpTools, regenerate] + hardenKids
        cast.records = [
            Self.record(.delivering, "Fix flaky payment test", sender: speed, id: flaky, minutes: 4),
            Self.record(.done, "Bump Swift tools to 6.2", sender: speed, id: bump, minutes: 2),
            Self.record(.waitingWake, "Split slow UI tests", sender: speed, target: P.studio, host: "Mac Studio", minutes: 3),
            Self.record(.waitingRoom, "Rebuild search index", sender: nil, target: nil, host: nil, minutes: 1),
        ] + hardenRecords
        let (workspace, vm) = try await mount(cast, selected: speed.id)
        defer { workspace.stop() }
        let lists = vm.presentedSidebarLists
        #expect(lists.working.first { $0.title == "Speed up checkout CI" }?.subtitle?.text == "3 sent · 1 back")
        #expect(lists.working.first { $0.title == "Harden webhook retries" }?.subtitle?.text == "4 sent · 2 back")
        #expect(lists.working.first { $0.title == "Harden webhook retries" }?.fold != nil)
        #expect(lists.working.first { $0.title == "Rebuild search index" }?.subtitle?.text == "Auto · no Mac has room")
        #expect(lists.needsYou.first { $0.title == "Backfill order totals" }?.subtitle?.text == "from Migrate orders to Postgres 17")
        try await Preview.renderMatrix("fleet-corner-sidebar", size: Self.size) { SidebarView(vm: vm).frame(width: Self.size.width, height: Self.size.height) }
        // The same threads under Spaces.
        workspace.settings.sidebarStyle = .projects
        try await Preview.renderMatrix("fleet-corner-sidebar-spaces", size: Self.size) { SidebarView(vm: vm).frame(width: Self.size.width, height: Self.size.height) }
    }

    /// Where the first text line beginning `prefix` starts, in points from the sidebar's left edge, as the rendered pixels say it (Vision's boxes).
    static func textX(_ prefix: String, in view: some View, size: CGSize) throws -> CGFloat? {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let scale: CGFloat = 4
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.usesLanguageCorrection = false
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([request])
        let hit = request.results?.first { $0.topCandidates(1).first?.string.hasPrefix(prefix) == true }
        return hit.map { $0.boundingBox.minX * size.width }
    }

    /// The same inset in every path: in both sidebar styles, a sent thread's title starts 18pt right of its sender's (FleetCornerFull: x57 against x39 at the
    /// default width), read from the rendered pixels of the board's own sidebar, not from the metrics.
    @Test func aSentThreadSitsAtTheSameInsetInBothStyles() async throws {
        let space = Space(name: "payments-api", path: "/tmp/p")
        let speed = Self.thread("Speed up checkout CI", .working, in: space, at: 1)
        let flaky = UUID()
        var cast = Cast()
        cast.local = [speed]
        cast.mini = [Self.thread("Fix flaky payment test", .working, in: space, at: 4, from: speed, dispatch: flaky)]
        cast.records = [Self.record(.running, "Fix flaky payment test", sender: speed, id: flaky, minutes: 4)]
        for (style, name) in [(SHSidebarStyle.activity, "activity"), (.projects, "spaces")] {
            for selected in [speed.id, nil] {
                let (workspace, vm) = try await mount(cast, style: style, selected: selected)
                defer { workspace.stop() }
                let size = CGSize(width: Self.size.width, height: 500)
                let view = SidebarView(vm: vm).frame(width: size.width, height: size.height)
                try await eventuallyOnMain("the rows to draw") { vm.presentedSidebarLists.working.contains { $0.fleetNested } || style == .projects }
                var sender: CGFloat?, child: CGFloat?
                try await eventuallyOnMain("\(name) rows' text to be read", timeout: .seconds(20)) {
                    sender = try Self.textX("Speed up", in: view, size: size)
                    child = try Self.textX("Fix flaky", in: view, size: size)
                    return sender != nil && child != nil
                }
                let delta = try #require(child) - (try #require(sender))
                // Vision's boxes are a point loose around a bold selected title, so the Spaces tree's tolerance is wider.
                #expect(abs(delta - 18) <= (style == .activity ? 1.5 : 3), "\(name), selected \(selected != nil): child at \(child ?? 0), sender at \(sender ?? 0)")
                if style == .activity {
                    let (senderX, childX) = (try #require(sender), try #require(child))
                    #expect(abs(senderX - 39) <= 1.5 && abs(childX - 57) <= 1.5, "activity: sender \(senderX), child \(childX)")
                }
            }
        }
    }

    /// Every stage a sent thread shows (FleetSubthreads), then a sender that folds, what is back and a sender that isn't here.
    @Test func everyStageOfASentThread() async throws {
        let space = Space(name: "payments-api", path: "/tmp/p")
        let speed = Self.thread("Speed up checkout CI", .working, in: space, at: 1)
        var cast = Cast()
        cast.local = [speed]
        func pre(_ state: FleetDispatchState, _ title: String, target: UUID? = nil, host: String? = nil, at: Double) {
            cast.records.append(Self.record(state, title, sender: speed, target: target, host: host, minutes: at))
        }
        @discardableResult
        func thread(_ state: FleetDispatchState, _ title: String, status: AgentStatus, target: UUID? = P.mini, host: String? = "Mac mini", at: Double, clone: String? = nil,
                    failure: String? = nil, detail: String? = nil) -> Agent {
            let dispatch = UUID()
            let agent = Self.thread(title, status, in: space, at: at, from: speed, dispatch: dispatch)
            cast.mini.append(agent)
            cast.records.append(Self.record(state, title, sender: speed, id: dispatch, target: target, host: host, minutes: at, clone: clone, failure: failure, detail: detail))
            return agent
        }
        pre(.placing, "Rebuild search index", at: 20)
        pre(.waitingRoom, "Lint the monorepo", at: 19)
        pre(.waitingWake, "Split slow UI tests", target: P.studio, host: "Mac Studio", at: 18)
        pre(.heldLimit, "Audit feature flags", at: 17)
        thread(.preparing, "Port the web client", status: .working, at: 16, clone: "payments-web")
        thread(.preparing, "Backfill order totals", status: .working, target: P.here, host: "MacBook Pro", at: 15)
        let fixFlaky = thread(.running, "Fix flaky payment test", status: .working, at: 14)
        thread(.running, "Pick a shard count", status: .blocked, at: 13)
        thread(.failed, "Profile cold launch", status: .idle, target: P.studio, host: "Mac Studio", at: 12, failure: FleetDispatchCode.hostNotReady, detail: "xcodebuild exited 65")
        thread(.delivering, "Trim build warnings", status: .working, at: 11)
        thread(.done, "Bump Swift tools to 6.2", status: .done, at: 30)
        // A thread another of these sent: it nests flat under the top sender, "via" the one that sent it.
        cast.local.append(Self.thread("Shard UI tests", .working, in: space, at: 10, from: fixFlaky, senderHost: P.mini, senderHostName: "Mac mini"))
        let live = cast.records.filter { $0.state.countsAgainstCap }.count
        let (workspace, vm) = try await mount(cast, cap: live, selected: speed.id)
        defer { workspace.stop() }
        let working = vm.presentedSidebarLists.working
        #expect(working.first?.subtitle?.text == "12 sent · 1 back")
        let lines = working.compactMap { $0.subtitle?.text }
        #expect(lines.contains("held · \(live) of \(live) sends live"))
        #expect(working.last?.subtitle?.text == "via Fix flaky payment test · This Mac · running")
        try await Preview.renderMatrix("fleet-subthreads", size: CGSize(width: Self.size.width, height: 1000)) {
            SidebarView(vm: vm).frame(width: Self.size.width, height: 1000)
        }
    }

    // MARK: FleetDispatch: the sender's thread

    /// The thread that sent the work draws each sent piece as one line: back, delivering, and one that goes when a Mac wakes.
    @Test func theSendersThreadDrawsCompactRows() async throws {
        let sender = Agent(name: "Speed up checkout CI", spaceID: SpaceID(), tabID: TabID())
        var records = [
            Self.record(.done, "Bump Swift tools to 6.2", sender: sender, minutes: 2),
            Self.record(.delivering, "Fix flaky payment test", sender: sender, minutes: 4),
            Self.record(.waitingWake, "Split slow UI tests", sender: sender, target: P.studio, host: "Mac Studio", minutes: 3),
        ]
        records[2].remoteAgentID = nil
        let cards = FleetDispatchPresentation.cards(records, in: FleetCardContext(snapshot: P.snapshot, cap: 3, locale: Locale(identifier: "en_US")))
            .sorted { $0.createdAt < $1.createdAt }
        #expect(cards.allSatisfy { $0.compact != nil })
        try await Preview.renderMatrix("fleet-corner-compact-rows", size: CGSize(width: 760, height: 220)) {
            VStack(spacing: SH.Space.l) {
                ForEach(cards) { FleetDispatchCardView(card: $0, actions: FleetThreadActions(), compactRows: true).equatable() }
            }
            .padding(SH.Space.xxl)
            .frame(width: 760, height: 220, alignment: .top)
            .background(Color.sh.bgWindow)
        }
    }
}

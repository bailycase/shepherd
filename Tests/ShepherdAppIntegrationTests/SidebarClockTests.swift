import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The sidebar's clocks, counted over a real server and view model in an off-screen window: rows
/// whose completions landed at different moments still redraw their figures in one run-loop turn
/// a second, not one turn each.
@Suite("Sidebar clocks", .mainActorExclusive)
@MainActor
struct SidebarClockTests {
    /// The main run loop's turns in which the sidebar's clocks drew, seen once each turn's work is
    /// done (after the display update, so a draw lands in the turn that made it).
    @MainActor private final class ClockTurns {
        private var observer: CFRunLoopObserver?
        private var seen = 0
        private(set) var turns = 0

        func start() {
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex(Int32.max)) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let count = SHRenderProbe.count("sidebar.clock")
                    if count > self.seen { self.turns += 1 }
                    self.seen = count
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }

        func stop() {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
        }
    }

    /// A sidebar of `count` threads that finished one after another, so each Done row's age counts
    /// from its own phase of the second.
    private func finishedThreads(_ count: Int, in app: AppHarness) async throws -> ShepherdViewModel {
        let space = Fixture.space(path: app.dir.path)
        let agents = (0..<count).map { Fixture.agent("agent \($0)", in: space, order: $0) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        let reporter = try ExtensionClient(path: app.scratch.socketPath)
        for fixture in agents {
            let id = fixture.agent.id
            try reporter.send(.setAgentStatus(agentID: id, status: .working))
            try reporter.send(.setAgentStatus(agentID: id, status: .done))
            try await eventuallyOnMain("\(fixture.agent.name) to reach Done") { vm.state.agents.first { $0.id == id }?.status == .done }
        }
        try await eventuallyOnMain("every finished thread to show its age") {
            vm.sidebarLists.done.count == count && vm.sidebarLists.done.allSatisfy { if case .age = $0.accessory { true } else { false } }
        }
        return vm
    }

    private func sidebarWindow(_ view: some View) -> OffscreenWindow {
        OffscreenWindow(size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 900), dark: false, view)
    }

    @Test func clocksThatStartedApartTickInOneTurn() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let count = 12
        let vm = try await finishedThreads(count, in: app)
        let window = sidebarWindow(SidebarView(vm: vm))
        defer { window.close() }
        ListPerf.settle(window)

        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        let turns = ClockTurns()
        turns.start()
        defer { turns.stop() }
        try await eventuallyOnMain("three ticks of every clock", timeout: .seconds(10)) {
            SHRenderProbe.count("sidebar.clock") >= count * 3
        }
        let drawn = SHRenderProbe.count("sidebar.clock")

        // Three ticks of one turn each; the slack is for a timer or two firing a turn late on a
        // busy machine. Clocks each ticking at their own phase take a turn per clock (36).
        #expect(turns.turns <= 8, "\(drawn) clock draws took \(turns.turns) turns")
    }

    /// Whether the window can be seen, as `MainWindowRoutes` publishes it.
    @Observable final class Presence {
        var visible: Bool
        init(visible: Bool) { self.visible = visible }
    }

    private struct SidebarInWindow: View {
        let vm: ShepherdViewModel
        let presence: Presence

        var body: some View { SidebarView(vm: vm).environment(\.mainWindowVisible, presence.visible) }
    }

    /// Beats once a second, a witness that time has passed.
    @MainActor private final class Beats {
        var count = 0
    }

    private struct Metronome: View {
        let beats: Beats

        var body: some View {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let _ = beats.count += 1
                Color.clear
            }
        }
    }

    /// While nobody can see the window its clocks stop (a witness clock beats three times without
    /// one of theirs drawing), and showing it again starts them from the current time.
    @Test func aSidebarNobodyCanSeeStopsItsClocksUntilItShows() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let count = 6
        let vm = try await finishedThreads(count, in: app)
        let presence = Presence(visible: false)
        let window = sidebarWindow(SidebarInWindow(vm: vm, presence: presence))
        defer { window.close() }
        ListPerf.settle(window)
        let beats = Beats()
        let witness = OffscreenWindow(size: CGSize(width: 40, height: 40), dark: false, Metronome(beats: beats))
        defer { witness.close() }

        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        try await eventuallyOnMain("three beats of time passing", timeout: .seconds(10)) { beats.count >= 3 }
        #expect(SHRenderProbe.count("sidebar.clock") == 0, "a clock nobody can see drew")

        presence.visible = true
        try await eventuallyOnMain("the clocks to tick again once shown", timeout: .seconds(10)) {
            SHRenderProbe.count("sidebar.clock") >= count * 2
        }
    }
}

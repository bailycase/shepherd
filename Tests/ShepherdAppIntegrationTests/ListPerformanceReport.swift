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

/// Measures every long list with a realistic large fixture and prints a table (`PERF | list |
/// metric | value`): opening it, scrolling through it a step at a time, the updates it takes
/// while on screen, and how many rows evaluated their body meanwhile. Timings depend on the
/// machine, so this reports rather than asserts; `ListPerformanceTests` pins the budgets.
///
///     SHEPHERD_PERF_REPORT=1 swift test --filter ListPerformanceReport
@Suite("List performance report", .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_PERF_REPORT"] != nil))
@MainActor
struct ListPerformanceReport {
    private let report = PerfReport()

    /// Opens `make()` in a window and closes it: the first surface a test run opens pays
    /// one-time costs (fonts, SwiftUI's caches) that would otherwise land on whichever test ran
    /// first.
    private func warmUp(size: CGSize, _ make: () -> some View) {
        let window = OffscreenWindow(size: size, dark: true, make())
        ListPerf.settle(window)
        window.close()
    }

    /// Opens `make()` warm, reporting the time and the rows built.
    private func open(_ name: String, size: CGSize, _ make: () -> some View) -> OffscreenWindow {
        warmUp(size: size, make)
        var window: OffscreenWindow!
        var ms = 0.0
        let rows = ListPerf.counting {
            let start = ContinuousClock.now
            window = OffscreenWindow(size: size, dark: true, make())
            ListPerf.settle(window)
            ms = ListPerf.milliseconds(ContinuousClock.now - start)
        }
        report.add(name, "open", ms: ms)
        report.add(name, "open: rows", counts: rows)
        return window
    }

    // MARK: Sidebar

    @Test func sidebar() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start(with: ListFixtures.fleet(in: app.dir))
        let name = "sidebar (300 agents, 40 spaces)"
        let window = open(name, size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 800)) { SidebarView(vm: vm) }
        defer { window.close() }

        let scroll = try #require(ListPerf.scrollView(in: window))
        var down = ListPerf.Scroll(), up = ListPerf.Scroll()
        let scrolling = ListPerf.counting {
            down = ListPerf.scroll(window, scroll, step: 120, steps: 200)
            up = ListPerf.scroll(window, scroll, step: -120, steps: 200)
        }
        report.add(name + " ↓", scroll: down)
        report.add(name + " ↑", scroll: up)
        report.add(name, "scroll down and up: rows", counts: scrolling)

        // A status report from one agent: the whole workspace is adopted again.
        var times: [Double] = []
        let broadcasts = ListPerf.counting {
            for index in 0..<10 {
                var next = vm.state
                next.agents[index * 3].status = next.agents[index * 3].status == .working ? .done : .working
                times.append(ListPerf.time(window) { vm.adopt(next) })
            }
        }
        report.add(name, "status broadcast ×10: mean", ms: times.reduce(0, +) / Double(times.count))
        report.add(name, "status broadcast ×10: rows", counts: broadcasts)

        var selects: [Double] = []
        let selecting = ListPerf.counting {
            for index in 0..<10 {
                selects.append(ListPerf.time(window) { vm.selectAgent(vm.state.agents[index * 7].id) })
            }
        }
        report.add(name, "select ×10: mean", ms: selects.reduce(0, +) / Double(selects.count))
        report.add(name, "select ×10: rows", counts: selecting)
    }

    // MARK: Palette

    @Test(arguments: [40, 1000])
    func palette(count: Int) throws {
        let name = "palette (\(count) results)"
        let items = ListFixtures.paletteItems(count)
        let highlight = PaletteHighlight()
        let window = open(name, size: CGSize(width: 900, height: 700)) {
            Color.clear.nwCommandPalette(isPresented: .constant(true)) {
                PaletteCard(items: items, run: { _ in }, close: {}, initialQuery: "fix", highlight: highlight)
            }
        }
        defer { window.close() }

        // ↓ twenty times: each moves the highlight one row, scrolling it into view.
        var moves: [Double] = []
        let moving = ListPerf.counting {
            for index in 1...20 { moves.append(ListPerf.time(window) { highlight.move(to: index) }) }
        }
        report.add(name, "move the highlight ×20: mean", ms: moves.reduce(0, +) / Double(moves.count))
        report.add(name, "move the highlight ×20: rows", counts: moving)

        let scroll = try #require(ListPerf.scrollView(in: window))
        var down = ListPerf.Scroll()
        let scrolling = ListPerf.counting { down = ListPerf.scroll(window, scroll, step: 120, steps: 400) }
        report.add(name + " ↓", scroll: down)
        report.add(name, "scroll: rows", counts: scrolling)
    }

    // MARK: Review

    @Test func reviewBigFile() throws {
        let name = "review (one 2k-line file)"
        let files = [ListFixtures.diffFile("Big.swift", lines: 2000)]
        let window = open(name, size: CGSize(width: 600, height: 800)) { ReviewPaneContent(model: ListFixtures.reviewModel(files)) }
        defer { window.close() }

        let scroll = try #require(ListPerf.scrollView(in: window))
        var down = ListPerf.Scroll(), up = ListPerf.Scroll()
        let scrolling = ListPerf.counting {
            down = ListPerf.scroll(window, scroll, step: 200, steps: 400)
            up = ListPerf.scroll(window, scroll, step: -200, steps: 400)
        }
        report.add(name + " ↓", scroll: down)
        report.add(name + " ↑", scroll: up)
        report.add(name, "scroll down and up: rows", counts: scrolling)
    }

    @Test func reviewManyFiles() async throws {
        let name = "review (300 files)"
        let files = (0..<300).map { ListFixtures.diffFile("Sources/Module\($0)/File\($0).swift", lines: 12) }
        let model = ListFixtures.reviewModel(files)
        let window = open(name, size: CGSize(width: 600, height: 800)) { ReviewPaneContent(model: model) }
        defer { window.close() }

        // Every file's colors land while the pane is open, one file at a time.
        let start = ContinuousClock.now
        var landings = 0
        let highlighting = try await countingAsync {
            var landed = model.highlights.count
            try await eventuallyOnMain("every file to be highlighted", timeout: .seconds(60)) {
                if model.highlights.count != landed {
                    landed = model.highlights.count
                    landings += 1
                    ListPerf.settle(window)
                }
                return landed == files.count
            }
        }
        report.add(name, "highlight every file: wall", ms: ListPerf.milliseconds(ContinuousClock.now - start))
        report.add(name, "highlight every file: rows", counts: highlighting)
        // One file's colors landing: the list's update, measured by folding a file off screen.
        var folds: [Double] = []
        for index in 0..<5 { folds.append(ListPerf.time(window) { model.toggleFolded(files[290 - index].id) }) }
        report.add(name, "an off-screen file changes ×5: mean", ms: folds.reduce(0, +) / Double(folds.count))

        var selects: [Double] = []
        let selecting = ListPerf.counting {
            for index in stride(from: 10, to: 300, by: 29) {
                selects.append(ListPerf.time(window) { model.select(model.session.files[index].id) })
            }
        }
        report.add(name, "select a file ×10: mean", ms: selects.reduce(0, +) / Double(selects.count))
        report.add(name, "select a file ×10: rows", counts: selecting)

        let scroll = try #require(ListPerf.scrollView(in: window))
        var down = ListPerf.Scroll()
        let scrolling = ListPerf.counting { down = ListPerf.scroll(window, scroll, step: 200, steps: 400) }
        report.add(name + " ↓", scroll: down)
        report.add(name, "scroll: rows", counts: scrolling)
    }

    // MARK: Thread

    @Test(arguments: [50, 500])
    func thread(turns: Int) async throws {
        let name = "thread (\(turns) turns)"
        var snapshot = ListFixtures.threadSnapshot(turns: turns, running: true)
        let store = NativeThreadStore()
        let request: NativeThreadStore.Request = { value in
            if case .send(_, _, let operation, _, _, _) = value { return .accepted(operationID: operation) }
            return .snapshot(value: snapshot)
        }
        let small = ListFixtures.threadSnapshot(turns: 5)
        let warm = NativeThreadStore()
        warmUp(size: CGSize(width: 900, height: 800)) {
            ThreadView(store: warm, active: true, isFocused: false, request: { _ in .snapshot(value: small) }, commandKey: "warm")
        }
        var window: OffscreenWindow!
        defer {
            store.stop()
            window.close()
        }
        var open = 0.0
        let opening = try await countingAsync {
            let start = ContinuousClock.now
            window = OffscreenWindow(size: CGSize(width: 900, height: 800), dark: true,
                                     ThreadView(store: store, active: true, isFocused: false, request: request, commandKey: "perf"))
            try await eventuallyOnMain("the thread to load") { store.ready }
            ListPerf.settle(window)
            open = ListPerf.milliseconds(ContinuousClock.now - start)
        }
        report.add(name, "open (load + first layout)", ms: open)
        report.add(name, "open: rows", counts: opening)

        let scroll = try #require(ListPerf.scrollView(in: window))
        var up = ListPerf.Scroll(), down = ListPerf.Scroll()
        let scrolling = ListPerf.counting {
            up = ListPerf.scroll(window, scroll, step: -300, steps: 60)
            down = ListPerf.scroll(window, scroll, step: 300, steps: 60)
        }
        report.add(name + " ↑", scroll: up)
        report.add(name + " ↓", scroll: down)
        report.add(name, "scroll up and back: rows", counts: scrolling)

        // Streaming: the live reply grows by a sentence each poll.
        ListPerf.jump(window, scroll, toEnd: true)
        var refreshes: [Double] = [], layouts: [Double] = []
        let streaming = try await countingAsync {
            for index in 0..<10 {
                let live = ListFixtures.message("live", "assistant", String(repeating: "Streaming sentence number \(index). ", count: index + 1))
                snapshot = ListFixtures.threadSnapshot(turns: turns, running: true, revision: UInt64(index + 2), provisional: [live])
                let start = ContinuousClock.now
                await store.refresh()
                refreshes.append(ListPerf.milliseconds(ContinuousClock.now - start))
                layouts.append(ListPerf.time(window))
            }
        }
        report.add(name, "stream a chunk ×10: store refresh mean", ms: refreshes.reduce(0, +) / Double(refreshes.count))
        report.add(name, "stream a chunk ×10: view update mean", ms: layouts.reduce(0, +) / Double(layouts.count))
        report.add(name, "stream a chunk ×10: rows", counts: streaming)
    }

    // MARK: Inspector

    @Test func inspectorTranscript() async throws {
        let name = "inspector transcript (500 turns)"
        let store = NativeThreadStore()
        let run = ListFixtures.run(0)
        var messages = ListFixtures.conversation(turns: 500, prefix: "c")
        var pages = 0
        let task = Task { [store] in
            await store.run { request in
                if case .subagentTranscript(_, let runID, _) = request {
                    pages += 1
                    return .transcript(value: NativeSubagentTranscript(runID: runID, messages: messages))
                }
                return .snapshot(value: NativeThreadSnapshot(
                    piSessionID: "s", generation: "g", revision: 1, running: true, supportedActions: ["send", "subagents"],
                    dialogsSupported: true, dialogs: [], messages: [], provisional: [], clipped: false, subagents: [run]))
            }
        }
        defer {
            task.cancel()
            store.stop()
        }
        try await eventuallyOnMain("the thread to connect") { store.ready }
        warmUp(size: CGSize(width: 600, height: 800)) { SubagentInspector(store: store, runID: "none", active: true, close: {}) }
        var window: OffscreenWindow!
        var open = 0.0
        let opening = try await countingAsync {
            let start = ContinuousClock.now
            window = OffscreenWindow(size: CGSize(width: 600, height: 800), dark: true,
                                     SubagentInspector(store: store, runID: run.runID, active: true, close: {}))
            try await eventuallyOnMain("the transcript to load") { pages >= 1 && (ListPerf.scrollView(in: window)?.documentView?.bounds.height ?? 0) > 2000 }
            ListPerf.settle(window)
            open = ListPerf.milliseconds(ContinuousClock.now - start)
        }
        defer { window.close() }
        report.add(name, "open (load + first layout)", ms: open)
        report.add(name, "open: rows", counts: opening)

        let scroll = try #require(ListPerf.scrollView(in: window))
        var up = ListPerf.Scroll()
        let scrolling = ListPerf.counting { up = ListPerf.scroll(window, scroll, step: -300, steps: 60) }
        report.add(name + " ↑", scroll: up)
        report.add(name, "scroll: rows", counts: scrolling)

        // Live reloads that append a turn each, while the reader is up the transcript.
        let appending = try await countingAsync {
            for index in 0..<5 {
                let before = pages
                messages += [ListFixtures.message("x\(index)u", "user", "One more thing"),
                             ListFixtures.message("x\(index)a", "assistant", ListFixtures.answer)]
                try await eventuallyOnMain("the next page") { pages > before + 1 }
                ListPerf.settle(window)
            }
        }
        report.add(name, "a reload appends a turn ×5: rows", counts: appending)
    }

    // MARK: Subagents

    private struct GroupHost: View {
        let runs: [ChildRun]

        var body: some View {
            ScrollView {
                SubagentStack(runs: runs, turnLive: runs.contains { !$0.isTerminal },
                              actions: SubagentActions(inspect: { _ in }, command: { _, _, _, _ in }, enabled: true))
                    .padding(NW.Space.l)
            }
            .frame(width: 800, height: 800)
            .background(Color.nw.bgWindow)
        }
    }

    @Test(arguments: ["running", "complete"])
    func subagents(state: String) throws {
        let name = "subagents (200 runs, \(state == "complete" ? "ledger" : "strip"))"
        let runs = (0..<200).map { ListFixtures.run($0, state: state) }
        let window = open(name, size: CGSize(width: 800, height: 800)) { GroupHost(runs: runs) }
        defer { window.close() }

        // One run changes state: the group is compared by value and redrawn.
        var next = runs
        next[5].state = state == "complete" ? "failed" : "complete"
        var update = 0.0
        let updating = ListPerf.counting {
            update = ListPerf.time(window) { window.show(GroupHost(runs: next)) }
        }
        report.add(name, "one run changes", ms: update)
        report.add(name, "one run changes: rows", counts: updating)

        if let scroll = ListPerf.scrollView(in: window) {
            var down = ListPerf.Scroll()
            let scrolling = ListPerf.counting { down = ListPerf.scroll(window, scroll, step: 200, steps: 100) }
            report.add(name + " ↓", scroll: down)
            report.add(name, "scroll: rows", counts: scrolling)
        }
    }

    // MARK: Directory picker

    @Test func directoryPicker() async throws {
        let name = "directory picker (2k dirs)"
        let dirs = ListFixtures.directories(2000)
        warmUp(size: CGSize(width: 600, height: 600)) {
            RemoteDirectoryPicker(hostName: "this Mac", list: { _ in RemoteHostClient.DirListing(path: "/", parent: nil, dirs: ["a"]) },
                                  choose: { _ in }, cancel: {})
        }
        var window: OffscreenWindow!
        var open = 0.0
        let opening = try await countingAsync {
            let start = ContinuousClock.now
            window = OffscreenWindow(size: CGSize(width: 600, height: 600), dark: true,
                                     RemoteDirectoryPicker(hostName: "this Mac", list: { _ in
                                         RemoteHostClient.DirListing(path: "/work", parent: "/", dirs: dirs)
                                     }, choose: { _ in }, cancel: {}))
            try await eventuallyOnMain("the listing to load") { (ListPerf.scrollView(in: window)?.documentView?.bounds.height ?? 0) > 1000 }
            ListPerf.settle(window)
            open = ListPerf.milliseconds(ContinuousClock.now - start)
        }
        defer { window.close() }
        report.add(name, "open (load + first layout)", ms: open)
        report.add(name, "open: rows", counts: opening)

        let scroll = try #require(ListPerf.scrollView(in: window))
        var down = ListPerf.Scroll()
        let scrolling = ListPerf.counting { down = ListPerf.scroll(window, scroll, step: 200, steps: 400) }
        report.add(name + " ↓", scroll: down)
        report.add(name, "scroll: rows", counts: scrolling)
    }

    private func countingAsync(_ work: () async throws -> Void) async throws -> [String: Int] {
        NWRenderProbe.start()
        defer { NWRenderProbe.stop() }
        try await work()
        return NWRenderProbe.counts
    }
}

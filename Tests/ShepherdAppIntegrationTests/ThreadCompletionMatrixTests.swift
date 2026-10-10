import AppKit
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
import Vision
@testable import ShepherdApp

/// Stress completion boundaries rather than repeating the same happy-path tool sequence.
@Suite("Completion boundary matrix", .serialized, .mainActorExclusive)
@MainActor
struct ThreadCompletionMatrixTests {
    typealias Flow = ThreadTailFlowTests
    typealias Fx = ThreadBlankScreenTests

    enum Boundary: String, CaseIterable, Sendable {
        case smallWindow, tallWindow, hugeLastReply, onlyThinking, onlyTools, emptyReply
        case failure, abort, hidden, readerAbove, composerGrows, composerShrinks, collapsePanel
        case historyReplacement, noPromptInPage, emptyHistoryDuringFinish, newSession
        case spawnRowsCollapse, manyToolsFinish, largeFinalTable, scrolledReplyCollapses
    }

    @Test(arguments: Boundary.allCases, [false, true])
    func aCompletionBoundaryKeepsRealContentVisible(boundary: Boundary, native: Bool) async throws {
        let size = switch boundary {
        case .smallWindow: CGSize(width: 620, height: 420)
        case .tallWindow: CGSize(width: 3200, height: 1800)
        default: CGSize(width: 2000, height: 870)
        }
        let host = Flow.FlowHost(turns: 85, mix: .giant)
        let deck = Flow.Deck(host: host, size: size, native: native)
        deck.model.tray = true
        defer { deck.close() }
        try await deck.open()
        let at = Fx.base + 100_000_000
        var live = [Fx.user("matrix-user", "Audit the thread and finish the review.", at: at)]
        var worker = ChildRun(runID: "matrix-child", label: "Read-only worker review", state: "running", startedAt: at, role: "worker")
        if boundary == .spawnRowsCollapse {
            worker.toolCallID = "linked-worker"
            live.append(NativeThreadMessage(entryID: "spawn", role: "toolResult", blocks: [.init(kind: .text, text: "{}")],
                                            toolName: "shepherd_child_start", toolCallID: "linked-worker",
                                            argumentsText: #"{"task":"Review this code"}"#, status: "complete", timestamp: at + 1))
        }
        if boundary == .manyToolsFinish {
            live += (0..<140).map { Fx.tool("bulk-\($0)", "read", ["path": "File\($0).swift"], output: "Checked.", at: at + 2) }
        }
        host.subagents = [worker]
        if boundary == .composerShrinks { deck.store.draft = String(repeating: "A draft line.\n", count: 30) }
        if boundary == .collapsePanel { deck.model.panel = true }
        for step in 0..<6 {
            if boundary == .onlyThinking {
                live.append(NativeThreadMessage(entryID: "thinking-\(step)", role: "assistant", blocks: [.init(kind: .thinking, text: Fx.prose(50, step))], timestamp: at + Double(step) * 1000))
            } else {
                live.append(Fx.tool("matrix-tool-\(step)", "shepherd_child_wait", ["ids": [worker.runID]], output: Fx.prose(step == 5 ? 200 : 1, step), at: at + Double(step) * 1000))
                if boundary != .onlyTools && boundary != .emptyReply {
                    live.append(Fx.reply("matrix-reply-\(step)", Fx.prose(step == 5 ? (boundary == .scrolledReplyCollapses ? 600 : 100) : 4, step), at: at + Double(step) * 1000 + 100))
                }
            }
            host.running = true
            host.provisional = live
            host.bump()
            await deck.store.refresh()
            try await Task.sleep(for: .milliseconds(40))
        }
        if boundary == .hidden { deck.hide() }
        if boundary == .readerAbove || boundary == .scrolledReplyCollapses {
            deck.command(.previousTurn)
            try await eventuallyOnMain("reader leaves the tail") { !deck.tailGuard.following }
            if boundary == .scrolledReplyCollapses,
               let scroll = deck.scrollView, let document = scroll.documentView {
                deck.tailGuard.readerMoved()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - 4000)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        if boundary == .composerGrows { deck.store.draft = String(repeating: "A draft line.\n", count: 30) }
        if boundary == .composerShrinks { deck.store.draft = "" }
        if boundary == .collapsePanel { deck.model.panel = false }
        let final: String = switch boundary {
        case .hugeLastReply: Fx.prose(500, 999) + "\n\nThe worker completed its review."
        case .largeFinalTable: "| File | Result |\n|---|---|\n" + (0..<150).map { "| File \($0) | Verified |\n" }.joined()
        case .emptyReply, .onlyThinking, .onlyTools: ""
        default: "The worker completed its review."
        }
        live.append(Fx.reply("matrix-final", final, at: at + 7000))
        if boundary == .failure || boundary == .abort {
            live[live.count - 1].status = boundary == .failure ? "error" : "aborted"
            live[live.count - 1].isError = boundary == .failure
        }
        worker.state = "complete"
        worker.endedAt = at + 7000
        host.subagents = [worker]
        host.running = false
        if boundary == .emptyHistoryDuringFinish {
            host.provisional = []
            host.bump()
            await deck.store.refresh()
            try await Task.sleep(for: .milliseconds(80))
        }
        host.provisional = []
        if boundary == .historyReplacement { host.all = Array(live.suffix(4)) }
        else if boundary == .scrolledReplyCollapses { host.all += [live[0], live[live.count - 1]] }
        else if boundary == .noPromptInPage {
            host.all += (0..<100).map { Fx.reply("extra-\($0)", "Review progress \($0).", at: at + Double($0)) } + live.suffix(1)
        } else { host.all += live }
        if boundary == .newSession { host.all = [Fx.user("new-prompt", "New session after completion", at: at), Fx.reply("new-answer", "The session is ready.", at: at + 1000)] }
        host.bump()
        await deck.store.refresh()
        if boundary == .hidden { deck.show() }
        // No forced layout between completion and this bounded recovery interval.
        try await Task.sleep(for: .seconds(2))
        let image = try ThreadWindowCapture.image(deck.window.window)
        let scroll = try #require(deck.scrollView)
        let viewport = scroll.convert(scroll.bounds, to: nil)
        let scale = CGFloat(image.height) / deck.window.window.frame.height
        let region = CGRect(x: (viewport.midX - min(viewport.width, 700) / 2) * scale,
                            y: (deck.window.window.frame.height - viewport.maxY) * scale,
                            width: min(viewport.width, 700) * scale,
                            height: max(1, viewport.height - (deck.reading?.insetBottom ?? 0) - 24) * scale)
        let pixels = try #require(image.cropping(to: region))
        let bitmap = NSBitmapImageRep(cgImage: pixels)
        let data = try #require(bitmap.bitmapData)
        let reference = (Int(data[0]), Int(data[1]), Int(data[2]))
        var ink = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let i = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
                if abs(Int(data[i]) - reference.0) + abs(Int(data[i + 1]) - reference.1) + abs(Int(data[i + 2]) - reference.2) > 36 { ink += 1 }
            }
        }
        let state = deck.reading
        let prefix = "\(boundary.rawValue)-\(native ? "anchored" : "scrolling")"
        let guardState = "rowsInView=\(deck.tailGuard.rowsInView), attempts=\(deck.tailGuard.attempts), repairing=\(deck.tailGuard.repairing), rowIDs=\(deck.tailGuard.rowIDs.count)"
        print("BOUNDARY \(prefix): rows=\(deck.store.rows.count), targets=\(deck.tailGuard.visible), following=\(deck.tailGuard.following), \(guardState), compositorInk=\(ink), \(String(describing: state))")
        guard !deck.store.rows.isEmpty, ink > 120 else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-completion-matrix")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(prefix + ".png"))
            Issue.record("Blank completed transcript: \(prefix), \(guardState), targets=\(deck.tailGuard.visible), \(state). See \(directory.path)")
            return
        }
    }

    @Test func workerTrayChangesWhileTailRecoveryIsRepairing() async throws {
        let deck = Flow.Deck(host: Flow.FlowHost(turns: 85, mix: .giant), size: CGSize(width: 2000, height: 870), native: false)
        defer { deck.close() }
        try await deck.open()
        var live = [Fx.reply("tray-live", Fx.prose(80, 1), at: Fx.base + 9_000_000)]
        var worker = ListFixtures.run(0)
        await deck.publish(running: true, provisional: live) { $0.subagents = [worker] }
        try await deck.expectTail("before tray completion")
        let land = deck.tailGuard.land
        deck.tailGuard.land = {}
        deck.tailGuard.targets([])
        try await eventuallyOnMain("tail repair started") { deck.tailGuard.repairing }
        worker.state = "complete"
        live.append(Fx.reply("tray-final", "The worker finished while the tail was recovering.", at: Fx.base + 9_010_000))
        deck.host.subagents = [worker]
        deck.host.all += live
        deck.host.provisional = []
        deck.host.running = false
        deck.host.bump()
        deck.tailGuard.land = land
        try await eventuallyOnMain("completion loaded") { !deck.store.running && deck.store.subagents.first?.state == "complete" }
        try await deck.expectTail("completion during recovery")
        let request = VNRecognizeTextRequest()
        try request.useCPUForTests()
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: ThreadWindowCapture.image(deck.window.window)).perform([request])
        let text = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        #expect(text.contains { $0.contains("worker finished") })
    }

    @Test func aReaderAboveTheTranscriptSurvivesItsHistoryBeingReplaced() async throws {
        try StubPi.installAsEngine()
        let deck = Flow.Deck(host: Flow.FlowHost(turns: 85, mix: .giant), size: CGSize(width: 2000, height: 870), native: false)
        defer { deck.close() }
        try await deck.open()
        let marker = Fx.base + 60_000_000
        let live = [Fx.user("reading-prompt", "Review this work.", at: marker)] + (0..<100).map {
            Fx.reply("reading-\($0)", Fx.prose(3, $0), at: marker + Double($0) * 1000)
        }
        await deck.publish(running: true, provisional: live)
        try await deck.expectTail("long active turn")
        deck.command(.previousTurn)
        try await eventuallyOnMain("reader lands above the tail") {
            !deck.tailGuard.following && (deck.reading?.distance ?? 0) > NativeScrollFollower.threshold
        }
        #expect(!deck.tailGuard.following)
        var final = [live[0], Fx.reply("new-history-id", "The worker completed the review.", at: marker + 120_000)]
        final[0].entryID = "new-history-user"
        await deck.publish(running: false, provisional: []) { $0.all = final }
        let request = VNRecognizeTextRequest()
        try request.useCPUForTests()
        request.recognitionLanguages = ["en-US"]
        try await eventuallyOnMain("the replacement history to paint", poll: .milliseconds(100)) {
            try VNImageRequestHandler(cgImage: ThreadWindowCapture.image(deck.window.window)).perform([request])
            return request.results?.contains { $0.topCandidates(1).first?.string.contains("worker completed") == true } == true
        }
        let image = try ThreadWindowCapture.image(deck.window.window)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("completion-reader-replaced.png")
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: destination)
        #expect(request.results?.contains { $0.topCandidates(1).first?.string.contains("worker completed") == true } == true)
        #expect(!deck.tailGuard.following, "replacing the history must not cancel reader detachment")
    }
}

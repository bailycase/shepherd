import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ThreadPerformanceTests {
    typealias F = Fixture

    /// The pre-incremental full projection, deliberately independent of the suffix planner.
    private func fullRows(_ store: NativeThreadStore) -> [NativeThreadRow] {
        var aliases: [String: String] = [:]
        for message in store.displayedMessages where message.role == "user" {
            if let operation = message.operationID { aliases[message.entryID] = "pending:\(operation.uuidString)" }
        }
        let turns = NativeThreadStore.endingCommentAnswers(nativeTurns(store.displayedMessages, aliases: aliases))
        let placements = nativeSubagentPlacements(store.subagents, turns: turns)
        let lastReply = turns.lastIndex { !$0.isUser }
        let liveReply = store.running ? lastReply.flatMap { index in
            turns[(index + 1)...].allSatisfy { $0.messages.allSatisfy { $0.status == "queued" } } ? index : nil
        } : nil
        let recorded = changesTurnsByMessage(store.snapshot?.turnChanges)
        var rows: [NativeThreadRow] = []
        for (index, turn) in turns.enumerated() {
            if turn.isUser {
                var row = NativeThreadRow(turn: turn, presentation: nil, live: false, promptText: nil, startedAt: nil)
                row.designComment = NativeThreadStore.designComment(turn)
                row.commentAnswered = row.designComment != nil && turns.indices.contains(index + 1) && !turns[index + 1].isUser
                    && !NativeThreadStore.opensWithCompaction(turns[index + 1])
                row.designMarkup = NativeThreadStore.designMarkup(turn)
                rows.append(row)
                continue
            }
            let live = index == liveReply
            let opener = index > 0 && turns[index - 1].isUser ? turns[index - 1] : nil
            let presentation = nativeTurnPresentation(turn.messages, live: live, cards: NativeCardLayout(placements[turn.id]),
                                                       errors: NativeTurnErrorContext(host: store.hostName, retry: live ? store.snapshot?.retry : nil))
            let prompt = opener.map { $0.messages.flatMap(\.blocks).filter { $0.kind == .text }.map(\.text).joined(separator: "\n") }
            let started = opener?.messages.first?.timestamp
            let record = started.flatMap { recorded[$0] }
            var row = NativeThreadRow(turn: turn, presentation: presentation, live: live, promptText: prompt, startedAt: started,
                                      recordedTurn: record, changes: live ? nil : nativeChangesCard(turn: record, changes: presentation.changes))
            row.designComment = NativeThreadStore.opensWithCompaction(turn) ? nil : opener.flatMap(NativeThreadStore.designComment)
            row.markupProposals = NativeMarkupProposals(turn)
            if index == turns.count - 1, !live, let opener { row.retryEntryID = NativeThreadStore.retryEntryID(opener) }
            rows.append(row)
        }
        NativeThreadStore.foldRepeatedErrors(&rows)
        return rows
    }

    @Test func incrementalRowsMatchTheFullProjectionAcrossHistoricalAndNeighborChanges() async {
        var comment = F.user("comment", id: "comment")
        comment.origin = .designComment(id: UUID())
        comment.timestamp = 42
        comment.operationID = UUID()
        var steer = F.user("steer", id: "steer")
        steer.origin = .steered
        var history = [F.user(id: "u1"), F.assistant("same failure", status: "error", id: "e1"),
                       F.user(id: "u2"), F.assistant("same failure", status: "error", id: "e2"),
                       comment, F.assistant("answer", id: "answer"), NativeThreadStoreTests.compaction("compaction"),
                       F.tool("shepherd_child_start", output: "started", id: "spawn", callID: "spawn"), steer,
                       F.assistant("done", id: "done"), F.user("last", id: "last"),
                       F.tool("edit", args: #"{"path":"a","oldText":"a","newText":"b"}"#, output: "done", id: "edit")]
        func proposal(_ text: String) -> String {
            DesignMarkupProposals(proposals: [DesignCommentDraft(board: DesignPath("A.dc.html")!, tid: 1, path: [], target: "target",
                                                                text: text, proposal: "p#0")]).block
        }
        history.append(F.tool("markup_propose", output: proposal("proposal"), id: "markup"))
        let host = FakeHost(F.snapshot(messages: history, subagents: [F.run("child", toolCallID: "spawn")]))
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        #expect(store.rows == fullRows(store))
        let parses = store.markupParses, joins = store.promptJoins
        for chunk in 0..<3 {
            host.snapshot.provisional = [F.assistant("chunk \(chunk)", status: "streaming", id: "live")]
            host.snapshot.revision += 1
            await store.refresh()
            #expect(store.rows == fullRows(store))
        }
        #expect(store.markupParses == parses && store.promptJoins == joins,
                "streaming prose must not reparse unchanged markup proposals or rejoin prompts")
        host.snapshot.provisional = []
        func check() async {
            host.snapshot.messages = history
            host.snapshot.revision += 1
            await store.refresh()
            #expect(store.rows == fullRows(store))
            #expect(store.turns == fullRows(store).map(\.turn))
            #expect(store.placements == nativeSubagentPlacements(store.subagents, turns: store.turns))
        }
        // Same-length historical tool rewrites must invalidate the call cache too.
        history[11].argumentsText = #"{"path":"b","oldText":"b","newText":"a"}"#
        await check()
        history[12].blocks[0].text = proposal("changed")
        await check()
        #expect(store.rows.last?.markupProposals?.proposals.first?.text == "changed")
        history[3].blocks = [NativeThreadBlock(kind: .text, text: "other failure")]
        await check()
        history[5] = F.message("system", "hidden", id: "answer")
        await check()
        history.insert(F.assistant("before summary", id: "before"), at: 6)
        await check()
        history[4].origin = nil
        await check()
        host.snapshot.turnChanges = [ChangesTurn(messageTimestamp: 42, startedAt: 42, endedAt: 50, state: .ready,
                                                files: [ChangesFile(path: "b", status: .modified, added: 1, removed: 1)], canUndo: true)]
        await check()
        host.snapshot.subagents?[0].state = "complete"
        await check()
        // Empty live thinking is visible only at the source tail, even after ignored rows.
        history.append(F.assistant("", thinking: "", status: "streaming", id: "empty"))
        await check()
        history.append(F.message("system", "hidden", id: "system-tail"))
        await check()
        history.removeLast(2)
        await check()
        var seed: UInt64 = 17
        for step in 0..<80 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let index = Int(seed % UInt64(history.count))
            let id = history[index].entryID
            switch step % 5 {
            case 0: history[index] = F.user("replacement", id: id)
            case 1: history[index] = F.assistant("same failure", status: "error", id: id)
            case 2: history[index] = F.message("system", "", id: id)
            case 3:
                history[index] = F.user("steer", id: id)
                history[index].origin = .steered
            default: history[index] = F.assistant("replacement", id: id)
            }
            await check()
        }
        // Older-page splices and a subsequent recent-page merge retain every boundary.
        host.next = [.success(.snapshot(value: F.snapshot(messages: [F.user("older", id: "older"), F.assistant("old", id: "old")], olderCursor: nil)))]
        host.snapshot.olderCursor = history.first?.entryID
        await store.refresh()
        await store.loadOlder()
        #expect(store.rows == fullRows(store))
        host.snapshot.provisional = [F.assistant("stream", status: "streaming", id: "stream")]
        await store.refresh()
        #expect(store.rows == fullRows(store))
    }

    /// `rowStructureRevision` moves exactly when the row IDs do, and `liveRowID` names the live row,
    /// across streaming, child progress, a provisional reply persisting, finishing, a new turn and an older page.
    @Test func rowStructureRevisionMovesOnlyWithRowIDs() async {
        var history = (0..<20).flatMap { [F.user(id: "u\($0)"), F.assistant("answer", id: "a\($0)")] }
        history += [F.user(id: "now"), F.tool("shepherd_child_start", output: "started", id: "spawn", callID: "spawn")]
        let host = FakeHost(F.snapshot(running: true, messages: history, subagents: [F.run("child", tokens: 1, toolCallID: "spawn")]))
        host.snapshot.olderCursor = "u0"
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        var ids = store.rows.map(\.id), revision = store.rowStructureRevision
        func step(structural: Bool?, _ change: () -> Void) async {
            change()
            host.snapshot.revision += 1
            await store.refresh()
            let now = store.rows.map(\.id)
            #expect((store.rowStructureRevision != revision) == (now != ids), "the revision moves exactly when the IDs do")
            if let structural { #expect((now != ids) == structural) }
            #expect(store.liveRowID == store.rows.last(where: \.live)?.id)
            ids = now
            revision = store.rowStructureRevision
        }
        await step(structural: nil) { host.snapshot.provisional = [F.assistant("chunk", status: "streaming", id: "live")] }
        for chunk in 0..<5 {
            await step(structural: false) { host.snapshot.provisional = [F.assistant("chunk \(chunk)", status: "streaming", id: "live")] }
        }
        #expect(store.liveRowID != nil)
        await step(structural: false) { host.snapshot.subagents?[0].tokens = 9 }
        // The provisional reply persists under its own id: the same reply row.
        await step(structural: nil) {
            host.snapshot.provisional = []
            host.snapshot.messages.append(F.assistant("chunk 4", id: "live"))
        }
        #expect(store.liveRowID != nil)
        await step(structural: false) { host.snapshot.running = false }
        // The finish settles after the store's own short hold; it lands in a derive of its own.
        await until { !store.rows.contains(where: \.live) }
        #expect(store.rows.map(\.id) == ids && store.rowStructureRevision == revision, "live -> finished with unchanged IDs")
        #expect(store.liveRowID == nil)
        await step(structural: true) { host.snapshot.messages += [F.user(id: "next"), F.assistant("reply", id: "reply")] }
        host.next = [.success(.snapshot(value: F.snapshot(messages: [F.user("older", id: "older"), F.assistant("old", id: "old")], olderCursor: nil)))]
        await store.loadOlder()
        #expect(store.rows.map(\.id) != ids && store.rowStructureRevision != revision, "an older page prepends rows")
        #expect(store.rows == fullRows(store))
    }

    @Test(arguments: [100, 1_000, 10_000], [false, true])
    func tailWorkRetainsHistoryRatherThanVisitingIt(_ count: Int, paged: Bool) async {
        let history = (0..<(count / 2)).flatMap { [F.user("prompt \($0)", id: "u\($0)"), F.assistant("answer", id: "a\($0)")] }
        let host = FakeHost(F.snapshot(running: true, messages: history))
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        let visits = store.projectedMessages, rows = store.projectedRows, comparisons = store.historyComparisons
        let joins = store.promptJoins, retained = store.retainedHistoryBytes
        if paged {
            host.snapshot.messages = Array(history.suffix(50))
            host.snapshot.olderCursor = host.snapshot.messages.first?.entryID
        }
        for index in 0..<200 {
            host.snapshot.revision += 1
            host.snapshot.provisional = [F.assistant("chunk \(index)", status: "streaming", id: "live")]
            await store.refresh()
        }
        #expect(store.messages.count == count)
        #expect(store.projectedMessages - visits <= 200 * 5)
        #expect(store.projectedRows - rows <= 200 * 5, "include the predecessor whose error fold may change")
        #expect(store.historyComparisons - comparisons == 200 * (paged ? 50 : count),
                "complete incoming pages still need correct first-difference detection")
        #expect(store.promptJoins == joins, "unchanged prompt joins are reused even in the rebuilt suffix")
        #expect(store.retainedHistoryBytes < retained + 16_384, "replaced tail/cache entries must not accumulate accounting cost")
        #expect(store.rows == fullRows(store))
        print("thread-work history=\(count) paged=\(paged) updates=200 messages=\(store.projectedMessages - visits) rows=\(store.projectedRows - rows) comparisons=\(store.historyComparisons - comparisons)")
    }

    @Test func mountedCostSumsTheEagerRowsAndReadsNoMore() async {
        let history = (0..<100).flatMap { [F.user("prompt \($0)", id: "u\($0)"), F.assistant(NativeMountedCostTests.bigReply(cycles: 1 + $0 % 3), id: "a\($0)")] }
        let host = FakeHost(F.snapshot(running: true, messages: history))
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        #expect(store.rows.count == 200)
        let eager = store.rows.suffix(30).reduce(0) { $0 + NativeMountedCost.row($1) }
        #expect(eager > 30 * NativeMountedCost.rowBase)
        #expect(store.mountedCost(eagerRows: 30) == eager)
        #expect(store.mountedCost(eagerRows: 0) == 0)
        #expect(store.mountedCost(eagerRows: 1_000) == store.rows.reduce(0) { $0 + NativeMountedCost.row($1) }, "more rows than the thread has are all of them")

        let computed = store.rowCostComputations
        #expect(computed == 100, "one per reply, when its presentation was built")
        let visited = (0..<100).map { _ in store.mountedCostWalk(eagerRows: 30, skipping: { _ in false }).visited }
        #expect(visited.allSatisfy { $0 == 30 }, "a read passes the rows it sums and no more of the 200")

        host.snapshot.revision += 1
        host.snapshot.provisional = [F.assistant("chunk 1", status: "streaming", id: "live")]
        await store.refresh()
        #expect(store.rowCostComputations == computed + 1, "a streamed pull costs the live row alone")
        #expect(store.mountedCost(eagerRows: 30) == store.rows.suffix(30).reduce(0) { $0 + NativeMountedCost.row($1) })
        host.snapshot.revision += 1
        host.snapshot.provisional = [F.assistant("chunk 1 and 2, with a fence\n\n```swift\nlet a = 1\n```", status: "streaming", id: "live")]
        await store.refresh()
        #expect(store.rowCostComputations == computed + 2)
        #expect(store.mountedCost(eagerRows: 30) == store.rows.suffix(30).reduce(0) { $0 + NativeMountedCost.row($1) })

        store.stop()
        store.release()
        #expect(store.rows.isEmpty && store.mountedCost(eagerRows: 30) == 0, "a released thread mounts nothing")
    }

    @Test func mountedCostReachesBackPastTheRowsTheViewLeavesOut() async {
        let history = (0..<100).flatMap { [F.user("prompt \($0)", id: "u\($0)"), F.assistant(NativeMountedCostTests.bigReply(cycles: 1 + $0 % 3), id: "a\($0)")] }
        let host = FakeHost(F.snapshot(messages: history))
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        let replies = store.rows.filter { !$0.isUser }
        #expect(replies.count == 100)
        let hidden: (NativeThreadRow) -> Bool = { $0.isUser }
        let expected = replies.suffix(30).reduce(0) { $0 + NativeMountedCost.row($1) }
        let walk = store.mountedCostWalk(eagerRows: 30, skipping: hidden)
        #expect(walk.cost == expected, "the last 30 rows the view draws, not 15 of them and 15 it leaves out")
        #expect(store.mountedCost(eagerRows: 30, skipping: hidden) == expected)
        #expect(walk.visited <= 60, "it passes the hidden rows between them and no others")
        #expect(store.mountedCost(eagerRows: 30) < expected, "unfiltered, the last 30 rows hold half the replies")
        #expect(store.mountedCost(eagerRows: 1_000, skipping: hidden) == replies.reduce(0) { $0 + NativeMountedCost.row($1) })
        #expect(store.mountedCost(eagerRows: 30, skipping: { _ in true }) == 0, "nothing drawn costs nothing")
    }

    @Test func mountedCostAddsTheNextChunkOfTheLastGiantReplyOnce() async {
        let giant = NativeMountedCostTests.gradedReply(fences: 60)
        let host = FakeHost(F.snapshot(messages: [F.user(id: "u0"), F.assistant(giant, id: "a0"), F.user(id: "u1"), F.assistant("short", id: "a1"),
                                                  F.user(id: "u2"), F.assistant(giant, id: "a2"), F.user(id: "u3")]))
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        await store.waitForProse()
        #expect(store.rows.count == 7)
        guard case .prose(_, _, let prose)? = store.rows[5].presentation?.items.last else {
            Issue.record("the last reply is not prose")
            return
        }
        let edge = prose.chunks[prose.chunks.count - prose.eagerTail - 1].cost
        #expect(prose.isGiant && edge > 0)
        let costs = store.rows.map { NativeMountedCost.row($0) }
        #expect(store.mountedCost(eagerRows: 7) == costs.reduce(0, +) + edge, "the earlier giant reply adds nothing")
        #expect(store.mountedCost(eagerRows: 2) == costs[6] + costs[5] + edge)
        #expect(store.mountedCost(eagerRows: 1) == costs[6], "the last reply is out of the sum, and so is its next chunk")
    }

    @Test func childProgressInvalidatesItsOwningSuffixRatherThanAllHistory() async {
        var history = (0..<500).flatMap { [F.user(id: "u\($0)"), F.assistant("answer", id: "a\($0)")] }
        history[999] = F.tool("shepherd_child_start", output: "started", id: "spawn", callID: "spawn")
        let host = FakeHost(F.snapshot(messages: history, subagents: [F.run("child", tokens: 1, toolCallID: "spawn")]))
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        let visits = store.projectedMessages
        for tokens in 2...11 {
            host.snapshot.revision += 1
            host.snapshot.subagents?[0].tokens = tokens
            await store.refresh()
        }
        #expect(store.projectedMessages - visits <= 40)
        #expect(store.rows == fullRows(store))
        #expect(store.placements == nativeSubagentPlacements(store.subagents, turns: store.turns))
    }

    @Test func duplicateSpawnIDsMoveToTheLastOwnerAndFallBackWhenItIsRemoved() async {
        var history = (0..<12).flatMap { [F.user(id: "u\($0)"), F.assistant("answer", id: "a\($0)")] }
        history[1] = F.tool("shepherd_child_start", output: "started", id: "first", callID: "shared")
        let host = FakeHost(F.snapshot(messages: history, subagents: [F.run("child", toolCallID: "shared")]))
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        func check(owner: String) async {
            host.snapshot.messages = history
            host.snapshot.revision += 1
            await store.refresh()
            #expect(store.placements == nativeSubagentPlacements(store.subagents, turns: store.turns))
            #expect(store.rows == fullRows(store), "both the former and new owner's presentations must match full derivation")
            #expect(store.placements.keys.sorted() == [owner])
            #expect(store.placements.values.flatMap(\.all).map(\.runID) == ["child"])
        }
        await check(owner: "u0/reply")
        history += [F.user(id: "later"), F.tool("shepherd_child_start", output: "started", id: "second", callID: "shared")]
        await check(owner: "later/reply")
        history += [F.user(id: "tail"), F.assistant("tail", id: "tail-answer")]
        await check(owner: "later/reply")
        history[history.count - 1].blocks[0].text = "changed tail"
        await check(owner: "later/reply")
        history.removeAll { $0.entryID == "second" }
        await check(owner: "u0/reply")
        history[1].toolCallID = "different"
        host.snapshot.messages = history
        host.snapshot.revision += 1
        await store.refresh()
        #expect(store.placements.isEmpty && store.rows == fullRows(store))
    }

    @Test func coldReplacementAndFinalMarkdownUseBoundedOffMainParses() async {
        let long = String(repeating: "words ", count: 1_500)
        let (gate, release) = AsyncStream<Void>.makeStream()
        let store = manualStore()
        store.beforeProseParse = { for await _ in gate {} }
        let history = (0..<8).flatMap { index in
            let tail = index == 7 ? "\n\n```swift\nlet value = 1" : "\n\n| A | B |"
            return [F.user(id: "u\(index)"), F.assistant(long + tail, status: "streaming", id: "a\(index)")]
        }
        let host = FakeHost(F.snapshot(running: true, messages: history))
        let loop = await start(store, host)
        defer { release.finish(); loop.cancel(); store.stop() }
        #expect(store.activeProseTasks == NativeThreadStore.maximumProseTasks)
        #expect(store.proseParses == 0)
        host.snapshot.messages[1] = F.assistant(long + "replacement", id: "a0")
        host.snapshot.messages[15].status = nil
        host.snapshot.revision += 1
        await store.refresh()
        #expect(store.activeProseTasks == NativeThreadStore.maximumProseTasks)
        release.finish()
        let expected = fullRows(store)
        await store.waitForProse()
        #expect(store.rows == expected)
        #expect(store.mainActorLargeParses == 0 && store.proseParses == 0)
        #expect(store.activeProseTasks == 0)
        #expect(store.offMainParses <= 10)
    }

    @Test func releaseAndSessionReplacementFenceDetachedParses() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let store = manualStore()
        store.beforeProseParse = { for await _ in gate {} }
        let long = String(repeating: "words ", count: 1_500)
        let host = FakeHost(F.snapshot(messages: [F.assistant(long, id: "same")]))
        let loop = await start(store, host)
        defer { release.finish(); loop.cancel(); store.stop() }
        #expect(store.activeProseTasks == 1)
        host.snapshot = F.snapshot(generation: "new", messages: [F.assistant("new", id: "same")])
        await store.refresh()
        #expect(store.rows == fullRows(store))
        host.snapshot.messages = [F.assistant(long, id: "same")]
        host.snapshot.revision += 1
        await store.refresh()
        let work = store.proseWork
        #expect(work.count == 1)
        store.suspend()
        #expect(store.canReleaseHistory && store.retainedHistoryBytes > 0)
        store.draft = "keep draft"
        store.attach(files: [NativeAttachedFile(name: "keep", path: "/tmp/keep")])
        store.release()
        release.finish()
        for task in work { await task.value }
        #expect(store.snapshot == nil && store.rows.isEmpty && store.retainedHistoryBytes == 0)
        #expect(store.draft == "keep draft" && store.attachedFiles.count == 1)
    }

    @Test func revertingToACachedTextInvalidatesAnOlderDetachedReplacement() async {
        let long = String(repeating: "words ", count: 1_500)
        let host = FakeHost(F.snapshot(messages: [F.assistant(long, thinking: long, id: "same")]))
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        await store.waitForProse()
        #expect(store.thinkingParses == 0 && store.proseParses == 0 && store.mainActorLargeParses == 0)
        let expected = store.rows
        let (gate, release) = AsyncStream<Void>.makeStream()
        store.beforeProseParse = { for await _ in gate {} }
        host.snapshot.messages = [F.assistant(long + "replacement", thinking: long + "replacement", id: "same")]
        host.snapshot.revision += 1
        await store.refresh()
        #expect(store.activeProseTasks == 2)
        host.snapshot.messages = [F.assistant(long, thinking: long, id: "same")]
        host.snapshot.revision += 1
        await store.refresh()
        release.finish()
        await store.waitForProse()
        #expect(store.rows == expected && store.offMainParses == 4)
    }

    @Test func submissionFeedbackPrecedesAdmissionAndRefusalDoesNotOverwriteANewDraft() async throws {
        let store = manualStore(), gate = FirstPullGate()
        let host = FakeHost(F.snapshot(actions: ["send", "sendImages", "designReferences", "browserElements"]))
        let request: NativeThreadStore.Request = { request in
            if case .send = request {
                gate.asked = true
                await until { !gate.held }
                return .failure(code: "busy", message: "not admitted")
            }
            return try host.handle(request)
        }
        let loop = Task { await store.run(request: request) }
        defer { gate.held = false; loop.cancel(); store.stop() }
        await until { store.ready }
        store.draft = "submitted"
        let files = [NativeAttachedFile(name: "submitted", path: "/tmp/submitted")]
        store.attach(files: files)
        let piece = try #require(DesignReference(string: "shepherd-design-ref://local/d1/A.dc.html"))
        let reference = NativeAttachedReference(reference: piece, label: "A")
        #expect(store.attach(reference: reference))
        let element = BrowserElement(page: "page", selector: "button", label: "button", width: 1, height: 1, html: "<button/>")
        #expect(store.attach(element: element))
        let elements = store.attachedElements
        let image = NativeImage(mimeType: "image/png", data: Data([1, 2, 3]), name: "image")
        let send = Task { await store.send(images: [image], delivery: .followUp) }
        await until { gate.asked }
        let record = try #require(store.submissions.first)
        #expect(store.draft.isEmpty && store.attachedFiles.isEmpty && record.state == .sending)
        #expect(record.images == [image] && record.files == files && store.sentCount == 0)
        #expect(record.references == [reference] && record.elements == elements)
        #expect(store.attachedReferences.isEmpty && store.attachedElements.isEmpty)
        store.draft = "new draft"
        store.suspend()
        #expect(!store.canReleaseHistory)
        store.release()
        #expect(store.snapshot != nil && store.submissions.count == 1)
        gate.held = false
        #expect(await send.value == false)
        #expect(store.submissions.first?.state == .failed && store.draft == "new draft")
        #expect(store.restoreSubmission(record.id) == nil)
        store.draft = ""
        let restored = try #require(store.restoreSubmission(record.id))
        #expect(store.draft == "submitted" && store.attachedFiles == files && restored.images == [image])
        #expect(store.attachedReferences == [reference] && store.attachedElements == elements)
        #expect(store.canReleaseHistory)
        store.release()
        #expect(store.draft == "submitted" && store.attachedFiles == files)
    }

    @Test func releasePreservesUserOwnedQueuedImagesAndProtectsPendingEchoes() async throws {
        let image = NativeImage(mimeType: "image/png", data: Data([1, 2]), name: "queued")
        let host = FakeHost(F.snapshot(running: true, actions: ["send", "sendImages", "queue"], queue: NativeQueue()))
        host.acceptAll()
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        store.draft = "queued"
        #expect(await store.send(images: [image], delivery: .followUp))
        guard case .send(_, _, let operation, _, _, _, _, _, _) = try #require(host.actions.last) else {
            Issue.record("expected send"); return
        }
        store.suspend()
        #expect(store.canReleaseHistory)
        store.release()
        #expect(store.rows.isEmpty && store.queuedImages(operation) == [image])

        let other = manualStore(), oldHost = FakeHost(F.snapshot())
        oldHost.acceptAll()
        let oldLoop = await start(other, oldHost)
        defer { oldLoop.cancel(); other.stop() }
        other.draft = "echo"
        await other.send()
        other.suspend()
        #expect(!other.pending.isEmpty && !other.canReleaseHistory)
        other.release()
        #expect(other.snapshot != nil && !other.pending.isEmpty)
    }

    @Test func lateAcceptanceNeverClearsANewIdenticalDraft() async {
        let store = manualStore(), gate = FirstPullGate()
        let host = FakeHost(F.snapshot())
        let loop = Task {
            await store.run { request in
                if case .send(_, _, let id, _, _, _, _, _, _) = request {
                    gate.asked = true
                    await until { !gate.held }
                    return .accepted(operationID: id)
                }
                return try host.handle(request)
            }
        }
        defer { gate.held = false; loop.cancel(); store.stop() }
        await until { store.ready }
        store.draft = "same words"
        let sending = Task { await store.send(delivery: .followUp) }
        await until { gate.asked }
        #expect(store.draft.isEmpty)
        store.draft = "same words"
        gate.held = false
        #expect(await sending.value)
        #expect(store.draft == "same words" && store.submissions.isEmpty)
    }

    @Test func warmResumesRequireTheSameConnectionAndActionsKeepReadiness() async {
        let host = FakeHost(F.snapshot(revision: 9))
        host.acceptAll()
        let store = manualStore()
        func run(_ connection: String) async -> Task<Void, Never> {
            let served = FirstPullGate()
            let task = Task {
                await store.run(request: {
                    served.asked = true
                    return try host.handle($0)
                }, connection: connection)
            }
            await until { served.asked }
            return task
        }
        let first = await run("connection")
        store.suspend(); first.cancel(); await first.value
        for _ in 0..<50 {
            host.next = [.success(.unchanged(piSessionID: "s", generation: "g", revision: 9))]
            let task = await run("connection")
            #expect(host.requests.last == .snapshot(expectedSessionID: "s", afterRevision: 9))
            store.suspend(); task.cancel(); await task.value
        }
        let changed = await run("new connection")
        defer { changed.cancel(); store.stop() }
        #expect(host.requests.last == .snapshot())
        store.draft = "send"
        await store.send()
        #expect(store.ready && host.requests.last == .snapshot(expectedSessionID: "s", afterRevision: 9))
        store.stop()
        changed.cancel(); await changed.value
        let stopped = await run("new connection")
        #expect(host.requests.last == .snapshot())
        stopped.cancel(); store.stop()
    }
}

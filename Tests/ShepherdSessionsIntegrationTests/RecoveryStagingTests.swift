import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

private extension NativeThreadResult {
    var wasAccepted: Bool { if case .accepted = self { return true }; return false }
}

@Suite("Recovery checkpoint staging", .integrationTimeLimit)
struct RecoveryStagingTests {
    private func images(_ bytes: Int) -> [NativeImage] {
        var remaining = bytes
        var result: [NativeImage] = []
        while remaining > 0 {
            let size = min(remaining, NativeImage.maxBytes)
            result.append(.init(mimeType: "image/png", data: Data(repeating: 137, count: size)))
            remaining -= size
        }
        return result
    }

    @Test(arguments: [0, 1 << 20, 5 << 20])
    func queuedAdmissionWaitsForFileWorkWithoutBlockingAnotherThread(bytes: Int) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("slow", from: try await pi.ready())
        let working = try await pi.snapshot { $0.running }
        let other = try await PiAgent.launch(on: h)
        _ = try await other.ready()
        try await eventually("initial recovery save settled") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let replied = Locked(false)
        let id = UUID(), payload = images(bytes)
        let request = Task {
            let value = try await pi.send("held image queue", images: payload, operationID: id, from: working)
            replied.withValue { $0 = true }
            return value
        }
        try await eventually("image checkpoint staged behind gate") { try await h.server.enqueue { h.server.recoveryWritesInFlight > 0 } }
        #expect(!replied.current)
        _ = try await other.snapshot()
        let checkpoint = try AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).checkpoint(for: pi.agent.id)
        #expect(checkpoint?.items.contains { $0.entry.id == id } != true)
        let visible = try await pi.snapshot()
        #expect(visible.queue?.items.contains { $0.id == id } != true)
        gate.signal()
        #expect(try await request.value.wasAccepted)
        let store = AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery"))
        let saved = try #require(try store.checkpoint(for: pi.agent.id))
        #expect(saved.items.first { $0.entry.id == id }?.images == payload)
        // The old decoder still reads the exact same inline JSON representation.
        let legacy = try JSONDecoder().decode(AgentRecoveryStore.Checkpoint.self, from: Data(contentsOf: store.file(for: pi.agent.id)))
        #expect(legacy == saved)
    }

    @Test func overlappingCandidatesCannotOverwriteAnAcceptedSend() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h), ready = try await pi.ready()
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let first = Task { try await pi.send("slow", images: images(1 << 20), from: ready) }
        try await eventually("first candidate held") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 1 } }
        let second = Task { try await pi.send("slow second", images: images(1 << 20), from: ready) }
        try await eventually("second candidate held") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 2 } }
        gate.signal()
        let results = try await [first.value, second.value]
        #expect(results.filter(\.wasAccepted).count == 1)
        _ = try await pi.snapshot { $0.running }
        #expect(pi.stdin("prompt").count == 1)
        let checkpoint = try #require(try AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).checkpoint(for: pi.agent.id))
        #expect(checkpoint.items.isEmpty)
        #expect(checkpoint.active)
    }

    @Test func failedQueueEditRenameKeepsTheOriginalImagesAndTextUnpublished() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("slow", from: try await pi.ready())
        let working = try await pi.snapshot { $0.running }, id = UUID()
        #expect(try await pi.send("original", images: images(1 << 20), operationID: id, from: working).wasAccepted)
        let store = AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery"))
        let original = try #require(try store.checkpoint(for: pi.agent.id))
        let url = store.file(for: pi.agent.id), backup = url.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: url, to: backup)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(!(try await pi.queue(.edit(id: id, text: "unwritten"), from: working)).wasAccepted)
        let visible = try await pi.snapshot()
        #expect(visible.queue?.items.first?.text == "original")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: backup, to: url)
        #expect(try JSONDecoder().decode(AgentRecoveryStore.Checkpoint.self, from: Data(contentsOf: url)) == original)
    }

    @Test(arguments: [1 << 20, 5 << 20])
    func recoveryReservationsStayBoundedUntilCancelledWorkersDrain(bytes: Int) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h), ready = try await pi.ready()
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let limit = min(8, (32 << 20) / (bytes + "held 0".utf8.count))
        let requests = (0..<limit).map { index in Task { try await pi.send("held \(index)", images: images(bytes), from: ready) } }
        try await eventually("recovery reservation limit") { try await h.server.enqueue { h.server.recoveryWritesInFlight == limit } }
        #expect(!(try await pi.send("overflow", images: images(bytes), from: ready)).wasAccepted)
        _ = try await pi.request(.abort(expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: UUID()))
        for request in requests { #expect(!(try await request.value).wasAccepted) }
        #expect(try await h.server.enqueue { h.server.recoveryWritesInFlight == limit && h.server.recoveryWriteBytes == limit * bytes + (0..<limit).reduce(0) { $0 + "held \($1)".utf8.count } })
        gate.signal()
        try await eventually("all reservations released") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 && h.server.recoveryWriteBytes == 0 } }
        #expect(pi.stdin("prompt").isEmpty)
    }

    /// #449: a recovery stage that cannot be admitted (every write slot busy) must not withhold a
    /// running turn's streamed text until Stop or pi's next event.
    @Test func aRefusedRecoveryStageStillPublishesStreamedText() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("slow", from: try await pi.ready())
        _ = try await pi.snapshot("first deltas") { s in
            s.provisional.contains { $0.role == "assistant" && $0.blocks.contains { $0.text.hasPrefix("Hello line") } }
        }
        try await eventually("turn checkpoint settled") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        try await h.server.enqueue {
            h.server.recoveryWritesInFlight += 8
            // The checkpoint changes while no write can be admitted.
            try #require(h.server.rpcThread(forAgent: pi.agent.id)).recoveryAttempts += 1
        }
        pi.release(1)
        _ = try await pi.snapshot("the rest of the reply", timeout: .seconds(5)) { s in
            s.provisional.contains { $0.role == "assistant" && $0.blocks.contains { $0.text.hasSuffix("sep world") } }
        }
        try await h.server.enqueue { h.server.recoveryWritesInFlight -= 8 }
        let saved = try AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).checkpoint(for: pi.agent.id)
        #expect(saved?.attempts == 1)
        pi.release(2)
    }

    @Test func imageBytesCountAgainstTheWholeQueueBudget() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("slow", from: try await pi.ready())
        let working = try await pi.snapshot { $0.running }
        #expect(try await pi.send("first", images: images(5 << 20), from: working).wasAccepted)
        #expect(!(try await pi.send("overflow", images: images(5 << 20), from: working)).wasAccepted)
        let saved = try #require(try AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).checkpoint(for: pi.agent.id))
        #expect(saved.items.map(\.entry.text) == ["first"])
    }

    @Test(arguments: ["stop", "settle", "switch", "switch-delete"], [false, true])
    func aHeldClearReplyCannotAuthorizeAnotherRun(end: String, boundary: Bool) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("tools:1 hold", from: try await pi.ready())
        let running = try await pi.snapshot { $0.running && $0.provisional.contains { $0.toolCallID != nil } }
        let first = UUID(), second = UUID(), firstImage = images(1024), secondImage = images(2048)
        if boundary {
            #expect(try await pi.send("tools:0 second image", images: secondImage, operationID: second, from: running).wasAccepted)
            await withCheckedContinuation { continuation in
                h.server.queue.async {
                    h.server.rpcThread(forAgent: pi.agent.id)!.deliverAtBoundary(expiresAt: Date().timeIntervalSince1970 * 1000 + 10_000) {
                        continuation.resume()
                    }
                }
            }
        }
        #expect(try await pi.send("tools:0 first image", delivery: .steer, images: firstImage, operationID: first, from: running).wasAccepted)
        if !boundary {
            #expect(try await pi.send("tools:0 second image", delivery: .steer, images: secondImage, operationID: second, from: running).wasAccepted)
        }
        #expect(pi.stdin("prompt").count == 3)
        try await h.server.enqueue {
            let thread = try #require(h.server.rpcThread(forAgent: pi.agent.id))
            thread.paused = true
            thread.commit()
        }
        try await eventually("initial recovery checkpoints drained") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        let gate = h.dir.appendingPathComponent("clear-reply-gate"), release = h.dir.appendingPathComponent("clear-reply-go")
        try Data().write(to: gate)
        defer { try? Data().write(to: release) }
        let replies = Locked<[NativeThreadResult]>([])
        let action = Task {
            let result = try await pi.queue(.unsteer(id: first), from: running)
            replies.withValue { $0.append(result) }
            return result
        }
        try await eventually("pi cleared its queue but is withholding the reply") {
            FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("clear-reply-held").path)
        }
        if end == "stop" {
            #expect(try await pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID())).wasAccepted)
        } else if end == "settle" {
            let aborted = await withCheckedContinuation { continuation in
                h.server.queue.async { h.server.rpcThread(forAgent: pi.agent.id)!.session.request(.abort) { continuation.resume(returning: $0) } }
            }
            #expect(try aborted.get().success)
            try await eventually("old run settled while clear reply remains held") {
                try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.running == false }
            }
        } else {
            try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.session.send(.newSession) }
            try await eventually("new conversation serves before old clear reply") {
                try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.generation != running.generation }
            }
        }
        if end == "switch-delete" {
            let current = try await pi.snapshot()
            #expect(try await pi.queue(.delete(id: second), from: current).wasAccepted)
        }
        #expect(replies.current.isEmpty && pi.stdin("prompt").count == 3)
        try Data().write(to: release)
        try await eventually("obsolete clear reply completes once") { replies.current.count == 1 }
        let result = try await action.value
        if case .failure(let code, _) = result { #expect(code == (end.hasPrefix("switch") ? "stale_session" : "send_cancelled")) }
        else { Issue.record("obsolete restoration was accepted") }
        try await eventually("clear and restoration ownership fully released") {
            try await h.server.enqueue {
                guard let thread = h.server.rpcThread(forAgent: pi.agent.id) else { return false }
                return thread.steersInFlight == 0 && !thread.settleAwaitingSteers && !thread.inputActive
                    && thread.recoveryPreparations.isEmpty && h.server.recoveryWritesInFlight == 0
            }
        }
        let expectedIDs = Set(end == "switch-delete" ? [first] : [first, second])
        let expectedSecond = end == "switch-delete" ? nil : secondImage
        try await h.server.enqueue {
            let thread = try #require(h.server.rpcThread(forAgent: pi.agent.id))
            #expect(thread.paused && Set(thread.items.map(\.entry.id)) == expectedIDs)
            #expect(thread.items.first { $0.entry.id == first }?.images == firstImage)
            #expect(thread.items.first { $0.entry.id == second }?.images == expectedSecond)
            #expect(thread.items.allSatisfy { $0.entry.state == .queued })
        }
        #expect(pi.stdin("prompt").count == 3 && replies.current.count == 1)
        let saved = try #require(try AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).checkpoint(for: pi.agent.id))
        #expect(saved.paused && Set(saved.items.map(\.entry.id)) == expectedIDs)
        #expect(saved.items.first { $0.entry.id == second }?.images == expectedSecond)
    }

    @Test(arguments: ["settle", "stop", "exit", "disk", "readmission", "complete"], [false, true])
    func settlementCannotRetireImageOwnershipDuringQueueRestoration(end: String, boundary: Bool) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("tools:1 hold", from: try await pi.ready())
        let running = try await pi.snapshot { $0.running && $0.provisional.contains { $0.toolCallID != nil } }
        let first = UUID(), second = UUID(), firstImage = images(1024), secondImage = images(2048)
        if boundary {
            #expect(try await pi.send("tools:0 second image", images: secondImage, operationID: second, from: running).wasAccepted)
            await withCheckedContinuation { continuation in
                h.server.queue.async {
                    h.server.rpcThread(forAgent: pi.agent.id)!.deliverAtBoundary(expiresAt: Date().timeIntervalSince1970 * 1000 + 10_000) {
                        continuation.resume()
                    }
                }
            }
            #expect(pi.stdin("prompt").count == 2)
        }
        #expect(try await pi.send("tools:0 first image", delivery: .steer, images: firstImage, operationID: first, from: running).wasAccepted)
        if !boundary {
            #expect(try await pi.send("tools:0 second image", delivery: .steer, images: secondImage, operationID: second, from: running).wasAccepted)
        }
        _ = try await pi.snapshot { $0.queue?.items.count == (boundary ? 1 : 2) }
        try await h.server.enqueue {
            let thread = try #require(h.server.rpcThread(forAgent: pi.agent.id))
            thread.paused = true // Keep reclaimed input visible instead of automatically draining it.
            thread.commit()
        }
        try await eventually("initial checkpoints drained") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        let fileGate = DispatchSemaphore(value: 0), frameGate = DispatchSemaphore(value: 0)
        let frameEntered = Locked(false), replies = Locked<[NativeThreadResult]>([])
        let directory = h.dir.appendingPathComponent("agent-recovery")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            fileGate.signal(); frameGate.signal()
        }
        if end == "readmission" {
            try await h.server.enqueue {
                h.server.rpcThread(forAgent: pi.agent.id)?.session.beforeInputPreparation = {
                    frameEntered.withValue { $0 = true }; frameGate.wait()
                }
            }
        }
        h.server.logicalProjectFiles.async { fileGate.wait() }
        let action = Task {
            let result = try await pi.queue(.unsteer(id: first), from: running)
            replies.withValue { $0.append(result) }
            return result
        }
        try await eventually("clear_queue answered and restore checkpoint is held") {
            try await h.server.enqueue {
                guard let thread = h.server.rpcThread(forAgent: pi.agent.id) else { return false }
                return thread.items.first { $0.entry.id == first }?.entry.state == .queued
                    && !thread.recoveryPreparations.isEmpty
            }
        }
        if end == "readmission" {
            fileGate.signal()
            try await eventually("restored image frame awaits admission") { frameEntered.current }
        }
        // pi really settles after clear_queue, while disk staging or image re-admission is held.
        if end != "complete" {
            let abort = await withCheckedContinuation { continuation in
                h.server.queue.async { h.server.rpcThread(forAgent: pi.agent.id)!.session.request(.abort) { continuation.resume(returning: $0) } }
            }
            #expect(try abort.get().success)
            try await eventually("settlement deferred behind restoration ownership") {
                try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.settleAwaitingSteers == true }
            }
        }
        try await h.server.enqueue {
            let thread = try #require(h.server.rpcThread(forAgent: pi.agent.id))
            #expect(thread.steersInFlight > 0)
            if boundary {
                #expect(thread.dispatches.first { $0.id == second }?.images == secondImage)
                #expect(thread.dispatches.first { $0.id == second }?.delivery == .steer)
            } else {
                #expect(thread.items.first { $0.entry.id == second }?.images == secondImage)
                #expect(thread.items.first { $0.entry.id == second }?.entry.state == .steering)
            }
        }
        if end == "stop" {
            _ = try await pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID()))
        } else if end == "exit" {
            h.server.killSession(pi.sessionID)
        } else if end == "disk" {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }
        if end == "stop" || end == "exit" {
            try await eventually("cancelled restoration answered before writer release") { replies.current.count == 1 }
        }
        fileGate.signal(); frameGate.signal()
        try await eventually("restoration completes exactly once") { replies.current.count == 1 }
        let result = try await action.value
        #expect(result.wasAccepted == (end == "complete"))
        try await eventually("all restoration continuations and workers released") {
            try await h.server.enqueue {
                guard let thread = h.server.rpcThread(forAgent: pi.agent.id) else { return false }
                return h.server.recoveryWritesInFlight == 0 && thread.recoveryPreparations.isEmpty
                    && thread.steersInFlight == 0 && !thread.settleAwaitingSteers && !thread.inputActive
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if end == "complete" {
            pi.finishTool(1)
            let delivered = try await pi.snapshot { $0.messages.contains { $0.operationID == second } }
            #expect(delivered.messages.filter { $0.operationID == second }.count == 1)
            let sent = try await pi.waitForStdin("prompt", count: 4)
            #expect((sent["images"] as? [[String: Any]])?.first?["data"] as? String == secondImage[0].data.base64EncodedString())
        } else {
            #expect(pi.stdin("prompt").count == 3, "failed restoration cannot send another prompt")
            try await h.server.enqueue {
                let thread = try #require(h.server.rpcThread(forAgent: pi.agent.id))
                #expect(Set(thread.items.map(\.entry.id)) == Set([first, second]))
                #expect(thread.items.first { $0.entry.id == first }?.images == firstImage)
                #expect(thread.items.first { $0.entry.id == second }?.images == secondImage)
                #expect(thread.items.allSatisfy { $0.entry.state == .queued })
            }
        }
        #expect(replies.current.count == 1)
    }

    @Test(arguments: ["expiry", "stop", "switch", "success"])
    func boundaryStagingRetainsDeadlineDeliveryAndCancellation(end: String) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("tools:1 hold", from: try await pi.ready())
        let running = try await pi.snapshot { $0.running && $0.provisional.contains { $0.toolCallID != nil } }
        let id = UUID(), payload = images(1 << 20)
        #expect(try await pi.send("boundary image", images: payload, operationID: id, from: running).wasAccepted)
        try await eventually("queued checkpoint settled") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        let gate = DispatchSemaphore(value: 0), done = Locked(0), captures = Locked(0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        try await h.server.enqueue {
            let thread = try #require(h.server.rpcThread(forAgent: pi.agent.id))
            thread.beforePrompt = { next in captures.withValue { $0 += 1 }; next() }
            thread.deliverAtBoundary(expiresAt: Date().timeIntervalSince1970 * 1000 + (end == "expiry" ? 2_000 : 10_000)) {
                done.withValue { $0 += 1 }
            }
            #expect(thread.items.map(\.entry.id) == [id], "no speculative dequeue")
        }
        try await eventually("boundary checkpoint held") { try await h.server.enqueue { h.server.recoveryWritesInFlight > 0 } }
        #expect(done.current == 0 && pi.stdin("prompt").count == 1)
        if end == "stop" {
            #expect(try await pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID())).wasAccepted)
        } else if end == "switch" {
            try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.session.send(.newSession) }
            // A public snapshot correctly waits for the changed recovery checkpoint. Observe
            // the owner fence directly while this test intentionally holds that writer.
            try await eventually("RPC generation switched behind the file gate") {
                try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.generation != running.generation }
            }
        }
        if end != "success" {
            try await eventually("boundary answered before file worker release", timeout: .seconds(5)) { done.current == 1 }
            #expect(pi.stdin("prompt").count == 1)
            #expect(try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.paused == true })
        }
        gate.signal()
        try await eventually("boundary workers drained") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        if end == "success" {
            try await eventually("durable boundary admitted") { done.current == 1 }
            let sent = try await pi.waitForStdin("prompt", count: 2)
            #expect(sent["streamingBehavior"] as? String == "steer")
            #expect((sent["images"] as? [[String: Any]])?.first?["data"] as? String == payload[0].data.base64EncodedString())
            let saved = try #require(try AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).checkpoint(for: pi.agent.id))
            #expect(saved.pending.map(\.entry.id) == [id] && saved.items.isEmpty)
        } else {
            #expect(pi.stdin("prompt").count == 1)
            #expect(try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.items.map(\.entry.id) == [id] })
        }
        #expect(done.current == 1 && captures.current == 0, "a boundary never starts another Before prompt capture")
    }

    @Test func expiredBoundaryStageCannotCompleteANewerPreparationWithTheSameQueueID() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("tools:1 hold", from: try await pi.ready())
        let running = try await pi.snapshot { $0.running && $0.provisional.contains { $0.toolCallID != nil } }
        let id = UUID()
        #expect(try await pi.send("same queue ID", images: images(1 << 20), operationID: id, from: running).wasAccepted)
        try await eventually("queued checkpoint settled") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
        defer { first.signal(); second.signal() }
        h.server.logicalProjectFiles.async { first.wait() }
        let old = Locked(0), newer = Locked(0)
        try await h.server.enqueue {
            h.server.rpcThread(forAgent: pi.agent.id)?.deliverAtBoundary(expiresAt: Date().timeIntervalSince1970 * 1000 + 2_000) {
                old.withValue { $0 += 1 }
            }
        }
        try await eventually("old boundary expires while staged", timeout: .seconds(5)) { old.current == 1 }
        h.server.logicalProjectFiles.async { second.wait() }
        try await h.server.enqueue {
            let thread = try #require(h.server.rpcThread(forAgent: pi.agent.id))
            thread.paused = false
            thread.deliverAtBoundary(expiresAt: Date().timeIntervalSince1970 * 1000 + 10_000) { newer.withValue { $0 += 1 } }
        }
        first.signal()
        try await eventually("old stage drained while new stage remains held") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 1 } }
        #expect(old.current == 1 && newer.current == 0 && pi.stdin("prompt").count == 1)
        second.signal()
        try await eventually("new boundary with reused ID completes") { newer.current == 1 }
        #expect(old.current == 1 && pi.stdin("prompt").count == 2)
    }

    @Test(arguments: [false, true])
    func sessionSwitchAnswersEveryDuplicateStagedSendExactlyOnce(evicted: Bool) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h), ready = try await pi.ready()
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let request: NativeThreadRequest = .send(expectedSessionID: ready.piSessionID, generation: ready.generation,
            operationID: UUID(), text: "must never reach pi", delivery: .followUp, images: images(1 << 20))
        let replies = Locked([[NativeThreadResult]](repeating: [], count: 2))
        try await h.server.enqueue {
            let thread = try #require(h.server.rpcThread(forAgent: pi.agent.id))
            for index in 0..<2 { thread.handle(request) { result in replies.withValue { $0[index].append(result) } } }
            if evicted {
                for _ in 0..<RPCThreadState.operationTableSize {
                    thread.handle(.queue(expectedSessionID: ready.piSessionID, generation: ready.generation,
                        operationID: UUID(), action: .delete(id: UUID()))) { #expect(!$0.wasAccepted) }
                }
            }
        }
        try await eventually("one shared recovery preparation") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 1 } }
        try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.session.send(.newSession) }
        _ = try await pi.snapshot { $0.generation != ready.generation }
        try await eventually("both callers answered before worker release") { replies.current.allSatisfy { $0.count == 1 } }
        #expect(replies.current.allSatisfy { $0.first == .failure(code: "stale_session", message: "Refresh the thread before acting.") })
        #expect(pi.stdin("prompt").isEmpty)
        gate.signal()
        try await eventually("cancelled stage drained") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        #expect(replies.current.allSatisfy { $0.count == 1 })
        #expect(pi.stdin("prompt").isEmpty)
    }

    @Test(arguments: ["stop", "restart", "revoke", "disk", "exit", "retire"])
    func invalidatedOrFailedAdmissionNeverPublishesOrReachesPi(boundary: String) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let ready = try await pi.ready()
        try await eventually("initial recovery jobs settled") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let authorized = Locked(true), replies = Locked<[NativeThreadResult]>([]), id = UUID()
        let request: NativeThreadRequest = .send(expectedSessionID: ready.piSessionID, generation: ready.generation,
            operationID: id, text: "must never reach pi", delivery: .followUp, images: images(1 << 20))
        let sending = Task {
            await withCheckedContinuation { continuation in
                h.server.queue.async {
                    h.server.rpcThread(forAgent: pi.agent.id)!.handle(request, inputAuthorization: { authorized.current }) { result in
                        replies.withValue { $0.append(result) }
                        continuation.resume(returning: result)
                    }
                }
            }
        }
        try await eventually("admission file work gated") { try await h.server.enqueue { h.server.recoveryWritesInFlight > 0 } }
        switch boundary {
        case "stop":
            _ = try await pi.request(.abort(expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: UUID()))
        case "restart":
            h.server.stop()
            try h.server.start()
        case "revoke": authorized.withValue { $0 = false }
        case "exit", "retire":
            h.server.killSession(pi.sessionID)
            try await eventually("exited staging reply") { !replies.current.isEmpty }
            if boundary == "retire" { await h.server.retireSession(sessionID: pi.sessionID) }
        default:
            let url = AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).file(for: pi.agent.id)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        if ["stop", "restart", "exit", "retire"].contains(boundary) {
            try await eventually("cancelled reply before worker release") { replies.current.count == 1 }
            #expect(try await h.server.enqueue { h.server.recoveryWritesInFlight > 0 }, "reservations stay held until the worker drains")
        }
        gate.signal()
        #expect(!(await sending.value).wasAccepted)
        #expect(pi.stdin("prompt").isEmpty)
        if boundary != "disk" {
            let saved = try AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).checkpoint(for: pi.agent.id)
            #expect(saved?.pending.contains { $0.entry.id == id } != true)
        }
        try await eventually("staging jobs released") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: h.dir.appendingPathComponent("agent-recovery").path)) ?? []
        #expect(!files.contains { $0.hasPrefix(".recovery-stage-") })
        #expect(replies.current.count == 1)
    }
}

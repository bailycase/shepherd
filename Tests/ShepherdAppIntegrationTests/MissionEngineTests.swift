import AppKit
import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// No credentials or external model: the staged, pinned engine talks only to our scripted loopback provider.
/// SHEPHERD_MISSION_ENGINE_TEST=1 SHEPHERD_ENGINE_SMOKE=.build/pi-engine swift test --filter MissionEngineTests
@Suite("Missions through the bundled Pi engine", .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_MISSION_ENGINE_TEST"] == "1",
                "set SHEPHERD_MISSION_ENGINE_TEST=1 and stage .build/pi-engine"))
@MainActor
struct MissionEngineTests {
    @Test func realToolsAndRPCSettleTwoLanesBeforeExplicitPublication() async {
        // MissionRuntimeFixture replaces gh and the default engine; isolate those process-wide stand-ins.
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.journey() }
        }
        expectScenarioCompleted(result)
    }

    private static func journey() async throws {
        // EngineSmoke/RealPi are in the sessions test target, not shared support.
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let enginePath = ProcessInfo.processInfo.environment["SHEPHERD_ENGINE_SMOKE"]
            .map { URL(fileURLWithPath: $0) } ?? repository.appendingPathComponent(".build/pi-engine")
        let engine = try #require(BundledPiEngine(contents: enginePath), "Stage the pinned engine at \(enginePath.path)")
        let fixture = try MissionRuntimeFixture()
        defer { fixture.stop() }
        let userHome = fixture.root.appendingPathComponent("live-home")
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        let setup = PiSetup(engine: .bundled(engine), home: fixture.root.appendingPathComponent("live-pi"), userHome: userHome.path)
        try setup.files.install()

        let provider = Process(), input = Pipe(), output = Pipe()
        provider.executableURL = engine.node
        provider.arguments = [repository.appendingPathComponent("Tests/Extensions/mission-engine-provider.mjs").path,
                              fixture.root.appendingPathComponent("fixture.json").path]
        provider.currentDirectoryURL = fixture.root
        provider.environment = ["HOME": userHome.path, "TMPDIR": fixture.root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        provider.standardInput = input
        provider.standardOutput = output
        try provider.run()
        defer {
            try? input.fileHandleForWriting.close()
            if provider.isRunning { provider.terminate() }
            provider.waitUntilExit()
        }
        let port = try await readPort(output.fileHandleForReading)
        let models = """
        {"providers":{"test":{"baseUrl":"http://127.0.0.1:\(port)/v1","api":"openai-completions","apiKey":"fixture-only",\
        "models":[{"id":"model","name":"model","reasoning":false,"input":["text"],"contextWindow":64000,"maxTokens":4096}]}}}
        """
        try Data(models.utf8).write(to: setup.home.appendingPathComponent("models.json"))
        var settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: setup.files.settings)) as? [String: Any])
        settings["defaultProvider"] = "test"
        settings["defaultModel"] = "model"
        settings["retry"] = ["enabled": false]
        settings["compaction"] = ["enabled": false]
        try JSONSerialization.data(withJSONObject: settings).write(to: setup.files.settings)

        // Explicit PiSetup bypasses the fake SHEPHERD_PI_ENGINE installed by the fixture.
        // The fixture's original app remains owned but unused; this VM owns the real mission.
        let app = try AppHarness(pi: setup, modelCatalog: {
            .init(models: [MissionRuntimeFixture.model], defaultModel: MissionRuntimeFixture.model)
        })
        defer { app.stop() }
        let vm = try await app.start()
        for space in fixture.spaces { try await app.server.addSpace(space) }
        try await eventuallyOnMain("real-engine mission spaces adopted") { vm.state.spaces.count == 2 }
        // Missions is an opt-in experiment (off by default); these journeys turn it on as a person would.
        vm.settings.missionsEnabled = true
        vm.openDestination(.missions)
        let controller = vm.missions
        controller.newMissionBackend = .legacyMap
        await controller.refreshModels()
        #expect(controller.availableModels == [MissionRuntimeFixture.model])
        AccessibilityNode.enable()
        let window = OffscreenWindow(size: CGSize(width: 1240, height: 900), dark: true,
                                     MissionsDestination(controller: controller))
        defer { window.close() }
        func press(_ label: String) async throws {
            try await eventuallyOnMain("real-engine UI enables \(label)", timeout: .seconds(60)) {
                window.layout()
                return window.controls().contains { $0.role == ControlRole.button && $0.label == label && $0.isEnabled }
            }
            try window.press(label)
        }

        func wait(_ id: MissionID, for phase: MissionRun.Phase) async throws {
            try await eventuallyOnMain("real-engine mission finishes \(phase.rawValue)", timeout: .seconds(60)) {
                let run = app.server.state.missions.first { $0.id == id }?.run
                return (run?.phase == phase || run?.phase == .paused || run?.phase == .stopped || controller.error != nil)
                    && controller.jobs[id] == nil
            }
            let mission = try controller.record(id)
            try #require(mission.run?.phase == phase, "\(mission.run?.notice ?? controller.error ?? "No diagnostic")")
        }
        func expectUnpublished(_ run: MissionRun) throws {
            #expect(run.publicationApproval == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.ghLog.path))
            for checkout in run.checkouts {
                #expect(checkout.prURL == nil && checkout.publishedHead == nil)
                #expect(try git(["rev-parse", "HEAD"], in: URL(fileURLWithPath: checkout.path))
                    .trimmingCharacters(in: .whitespacesAndNewlines) == checkout.head)
            }
            for remote in fixture.remotes {
                #expect(try git(["for-each-ref", "--format=%(refname)", "refs/heads/mission/"], in: remote).isEmpty)
            }
            try fixture.expectSourcesUnchanged()
        }

        try await press("New mission")
        let setter = NSSelectorFromString("setAccessibilityValue:")
        try await eventuallyOnMain("real-engine UI presents the mission form") {
            AccessibilityNode.all(under: window.host).contains { $0.label == "Destination" && $0.object.responds(to: setter) }
        }
        let editor = try #require(AccessibilityNode.all(under: window.host).first { $0.label == "Destination" && $0.object.responds(to: setter) })
        let goal = "Change result.txt to after followed by a newline in both repositories and verify it independently."
        _ = editor.object.perform(setter, with: goal)
        if let textView = editor.object as? NSTextView {
            textView.insertText(goal, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: textView)
        }
        for space in fixture.spaces {
            let checkbox = try #require(window.controls().first { $0.role == ControlRole.checkBox && $0.label?.contains(space.name) == true })
            try window.press(try #require(checkbox.label), role: ControlRole.checkBox)
        }
        try await press("Plan mission")
        try await eventuallyOnMain("real-engine UI creates a mission") { controller.records.count == 1 }
        let id = try #require(controller.records.first?.id)
        try await wait(id, for: .map)
        let planned = try controller.record(id)
        let planning = try #require(planned.run)
        #expect(controller.selectedID == id && vm.destination == .missions)
        #expect(planned.approvedPlanRevision == nil)
        #expect(planning.checkouts.count == 2 && planning.attempts.count == 1)
        #expect(planning.attempts.first?.status == .succeeded)
        for checkout in planning.checkouts {
            #expect(checkout.path != checkout.repo)
            #expect(try String(contentsOf: URL(fileURLWithPath: checkout.path).appendingPathComponent("result.txt"), encoding: .utf8) == "before\n")
        }
        try expectUnpublished(planning)

        try await press("Launch")
        try await wait(id, for: .review)
        let reviewed = try controller.record(id)
        let run = try #require(reviewed.run)
        let plan = try #require(reviewed.draft.plan)
        #expect(reviewed.approvedPlanRevision != nil)
        #expect(run.attempts.count == 7) // planner, two writers, two host checks, two fresh validators
        let agents = run.attempts.compactMap(\.agentID)
        #expect(agents.count == 5 && Set(agents).count == 5)
        for attempt in run.attempts where attempt.agentID != nil {
            #expect(attempt.status == .succeeded && attempt.sessionID != nil && attempt.generation != nil)
            #expect(attempt.tokens > 0)
        }
        for station in plan.stations {
            let attempt = try #require(run.latest(station.id))
            #expect(attempt.status == .succeeded && attempt.fingerprint != nil)
            if station.kind == .check {
                #expect(attempt.agentID == nil && attempt.exitCode == 0)
                #expect(attempt.output.contains("HOST_CHECK_OK"))
            } else {
                // These are Pi's persisted messages, not host-created receipts or synthetic agent_end events.
                let sessionID = try #require(attempt.sessionID)
                let files = try #require(FileManager.default.enumerator(at: setup.sessionsRoot, includingPropertiesForKeys: nil))
                let session = try #require(files.compactMap { $0 as? URL }.first { $0.lastPathComponent.hasSuffix("_\(sessionID).jsonl") })
                let messages = try String(contentsOf: session, encoding: .utf8).split(separator: "\n").compactMap {
                    (try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["message"] as? [String: Any]
                }
                let tool = station.kind == .worker ? "write" : "read"
                let calls = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                    .filter { $0["type"] as? String == "toolCall" && $0["name"] as? String == tool }
                #expect(calls.count == 1)
                let call = try #require(calls.first)
                let arguments = try #require(call["arguments"] as? [String: Any])
                #expect(arguments["path"] as? String == "result.txt")
                if station.kind == .worker { #expect(arguments["content"] as? String == "after\n") }
                let result = try #require(messages.first { $0["role"] as? String == "toolResult" && $0["toolName"] as? String == tool })
                #expect(result["isError"] as? Bool == false)
                #expect(result["toolCallId"] as? String == call["id"] as? String)
                if station.kind == .validator {
                    #expect(attempt.output.contains("Read actual result.txt") && !attempt.output.hasPrefix("{"))
                    #expect((result["content"] as? [[String: Any]])?.contains { ($0["text"] as? String)?.contains("after") == true } == true)
                }
            }
        }
        let reviews = try #require(controller.reviews[id])
        #expect(reviews.count == 2 && reviews.allSatisfy { !$0.files.isEmpty })
        for checkout in run.checkouts {
            #expect(try String(contentsOf: URL(fileURLWithPath: checkout.path).appendingPathComponent("result.txt"), encoding: .utf8) == "after\n")
        }
        try expectUnpublished(run)
        // No fixture adapter was invoked, even though it is still installed as the default engine.
        #expect(!FileManager.default.fileExists(atPath: fixture.calls.path))

        let fingerprint = try #require(run.reviewFingerprint)
        let files = window.controls().filter { $0.role == ControlRole.button && $0.label?.contains("result.txt") == true }
        try #require(files.count == 2, "Both actual worktree diffs must be reviewable")
        for index in files.indices {
            let label = try #require(files[index].label)
            try window.press(label, nth: files.prefix(index).filter { $0.label == label }.count)
        }
        try await press("Publish pull requests")
        try await wait(id, for: .done)
        let done = try #require(controller.record(id).run)
        #expect(done.publicationApproval == fingerprint && done.attempts == run.attempts)
        for checkout in done.checkouts {
            let index = try #require(fixture.spaces.firstIndex { $0.id == checkout.spaceID })
            let head = try #require(checkout.publishedHead)
            #expect(checkout.prURL == "https://github.invalid/fixture/repo/pull/1")
            let pushed = try git(["rev-parse", "refs/heads/" + checkout.branch], in: fixture.remotes[index]).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(pushed.hasPrefix(head))
            #expect(try git(["show", pushed + ":result.txt"], in: fixture.remotes[index]) == "after\n")
            #expect(try git(["rev-parse", pushed + "^"], in: fixture.remotes[index]).trimmingCharacters(in: .whitespacesAndNewlines) == fixture.initialHeads[index])
            #expect(try git(["status", "--porcelain"], in: URL(fileURLWithPath: checkout.path)).isEmpty)
        }
        let gh = try String(contentsOf: fixture.ghLog, encoding: .utf8)
        #expect(gh.split(separator: "\n").filter { $0.hasPrefix("pr create ") }.count == 2)
        try fixture.expectSourcesUnchanged()
        #expect(!window.window.isKeyWindow && !window.window.isMainWindow)
        #expect(vm.selectedAgentID == nil)
    }

    private static func readPort(_ handle: FileHandle) async throws -> Int {
        let bytes = Locked(Data())
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            bytes.withValue { $0.append(chunk) }
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
        defer { handle.readabilityHandler = nil }
        var port: Int?
        try await eventuallyOnMain("mission loopback provider listening") {
            let data = bytes.current
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
                  let value = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any] else { return false }
            port = value["port"] as? Int
            return port != nil
        }
        return try #require(port)
    }
}

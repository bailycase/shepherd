import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Opt-in acceptance against actual upstream Spec Kit and the real bundled pi. Upstream's own
/// `specify init --integration pi` (an existing, provenance-checked v1.2.3 install, run offline in
/// scratch) generates the project; the pinned engine loads its stock `.pi/prompts` and expands them;
/// a loopback scripted provider drives pi's real bash tool through the official scripts.
/// The model is scripted: this proves loading, expansion, scripts and Mission gates, not model quality.
@Suite("Missions through stock Spec Kit and the bundled Pi engine", .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_MISSION_ENGINE_TEST"] == "1"
                && ProcessInfo.processInfo.environment["SHEPHERD_TEST_SPECKIT_SPECIFY"] != nil,
                "set SHEPHERD_MISSION_ENGINE_TEST=1, stage .build/pi-engine and point SHEPHERD_TEST_SPECKIT_SPECIFY at a verified specify-cli 1.2.3 executable"))
@MainActor
struct MissionSpecKitEngineTests {
    /// github/spec-kit v1.2.3 (tag commit) and sha256 of the generator inputs the test relies on.
    static let commit = "5ea8b1cf0a38699340a38e00d02770308997d8c0"
    static let commandHashes = [
        "specify.md": "7d5a88e6afa504f1d16503df6bf8664f30e3df812b83f9a456a2eaccaeb638ee",
        "plan.md": "206a0386d20b3eed4c087a4d9de247a3e7b2b59348bf3c801fc74f63ca2726a5",
        "tasks.md": "2f9176c6e7c23d2a83d2bd018ffa1e67aee977389a57f2a3fe35fe987b425944",
        "implement.md": "feab334232940cfd4ecbcdae41cf63ccb7d581a60380230837385f296f7b49bd",
        "converge.md": "4fb017b2869ad02d58aafe272a90077187ce4231f08effee6f340b0f3a07fc16",
        "clarify.md": "5260d798c5671deb9ac7e59d6ffdb69b30c26fb28878d3cc25e30fb71cacc734",
        "analyze.md": "ffe0640ebe778795737937f2d4ec6f0149d7d55b72692e25369a668f985d1dfe",
        "checklist.md": "1192784f378fb977b408b72ca1bfb8fc55e129519f3f44bc5d0a7e152c480654",
        "constitution.md": "a915ba6ae5fdbd499c143204eab3888b95a0ff0656e2c16b40282375acb5902c",
    ]
    static let scriptHashes = [
        "check-prerequisites.sh": "38f5e2c8150ee35ee62a5ae3aec66be8bdb15a9805ba20cc3974acdecb6c5e10",
        "common.sh": "53cb1c23e349db4586c272436ce35c6e2f36a9c0b5351a85e0b216d9887a26b7",
        "setup-plan.sh": "d378ec66ba20d2da01c71dad8935062c1c27f0bba890be9a6d3dda52ea056a4e",
        "setup-tasks.sh": "0f7d7e996ed4a26ab7bf09bf10540366ee402b930a4a9cbc0ee7bc6a8bd0013b",
    ]
    static let goal = "Change result.txt to after followed by a newline."

    @Test func upstreamInitPromptsAndScriptsRunThroughAMissionOnTheRealEngine() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.journey() }
        }
        expectScenarioCompleted(result)
    }

    /// Same rig, driven only through the Missions window's own controls: no controller calls for
    /// consent, commands, approval or acceptance. The regression for "Spec Kit missions cannot leave preflight".
    @Test func nativeControlsConsentPlanImplementSteerAndReachReviewThroughStockSpecKit() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.controlsJourney() }
        }
        expectScenarioCompleted(result)
    }

    /// Visible names of the controls the journey presses, in one place. Labels the UI owns.
    enum Labels {
        /// The last repository still to allow: the grant that also continues planning.
        static func allow(_ repository: String) -> String { "Allow \(repository)'s project files and continue planning" }
        static func accept(_ repository: String) -> String { "Accept \(repository)'s completion report" }
        // MissionGoalView: the planner conversation's composer and its send.
        static let plannerComposer = "Reply to the planner, or tell it what to change\u{2026}", plannerSend = "Send to the planner"
        // MissionsPage: the goal editor's and plan button's accessibility labels.
        static let newMission = "New mission", destination = "Mission goal", plan = "Plan the mission"
        static let reviewMap = "Review the map", launch = "Launch", transcript = "Transcript"
        // The shared native composer (Composer.swift, ComposerParts.swift): field and its send action.
        static let threadComposer = "Message the agent", threadSend = "Send"
    }

    private static func controlsJourney() async throws {
        let rig = try await Rig(); defer { rig.stop() }
        let controller = rig.controller
        AccessibilityNode.enable()
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 1100), dark: false, MissionsDestination(controller: controller))
        defer { window.close() }
        func ready(_ label: String, role: String = ControlRole.button) async throws {
            do {
                try await eventuallyOnMain("\(label) is rendered enabled", timeout: .seconds(45)) {
                    window.layout()
                    return window.controls().contains { $0.role == role && $0.label == label && $0.isEnabled }
                }
            } catch {
                let mission = controller.records.first
                Issue.record("\(label) not ready. phase=\(mission?.run?.phase.rawValue ?? "nil") notice=\(mission?.run?.notice ?? "nil") error=\(controller.error ?? "nil") reports=\(controller.specKitReports.values.flatMap(\.values).map(\.status.rawValue)) controls=\(window.controls().map(\.description))")
                throw error
            }
        }
        func press(_ label: String) async throws {
            try await ready(label)
            let before = controller.records.first?.revision
            try window.press(label)
            // The press must reach the controller: a job starts or the record moves.
            try await eventuallyOnMain("\(label) reached the mission (error: \(controller.error ?? "none"))", timeout: .seconds(30)) {
                controller.error != nil || controller.records.first?.revision != before || controller.records.first.map { controller.jobs[$0.id] != nil } == true
            }
            try #require(controller.error == nil, "\(label): \(controller.error ?? "")")
        }
        func settle(_ phase: MissionRun.Phase) async throws { try await rig.wait(try #require(controller.records.first?.id), phase) }

        try await ready(Labels.newMission); try window.press(Labels.newMission)
        let setter = NSSelectorFromString("setAccessibilityValue:")
        try await eventuallyOnMain("mission form") { AccessibilityNode.all(under: window.host).contains { $0.label == Labels.destination && $0.object.responds(to: setter) } }
        let editor = try #require(AccessibilityNode.all(under: window.host).first { $0.label == Labels.destination && $0.object.responds(to: setter) })
        _ = editor.object.perform(setter, with: goal)
        if let textView = editor.object as? NSTextView {
            textView.insertText(goal, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: textView)
        }
        // MissionRepositoryToggles: a button per repository, its value "chosen" or "not chosen".
        try await ready(rig.space.name)
        if AccessibilityNode.all(under: window.host).first(where: { $0.label == rig.space.name })?.value != "chosen" { try window.press(rig.space.name) }
        try await eventuallyOnMain("repository chosen") { window.layout(); return AccessibilityNode.all(under: window.host).contains { $0.label == rig.space.name && $0.value == "chosen" } }
        try await press(Labels.plan)
        try await settle(.map)
        let id = try #require(controller.records.first?.id)
        try #require(controller.record(id).run?.specKit != nil, "a new Mission from the UI is a Spec Kit mission")

        // Preparing lands on Map; trust and the planner conversation are in the Goal step.
        func openGoal() throws {
            window.layout()
            if let goal = window.controls().first(where: { $0.label?.hasPrefix("Step 1, Goal") == true }), let label = goal.label { try window.press(label) }
        }
        /// Types through a field's own text input (NSTextInputClient) in the offscreen window: no global focus or events.
        func type(_ text: String, into label: String) async throws {
            try await eventuallyOnMain("\(label) is shown", timeout: .seconds(60)) {
                window.layout(); return AccessibilityNode.all(under: window.host).contains { $0.label == label }
            }
            let node = try #require(AccessibilityNode.all(under: window.host).first { $0.label == label })
            let view = (node.object as? NSCell)?.controlView ?? node.object as? NSView
            let input: (NSTextView & NSTextInputClient)?
            if let textView = view as? NSTextView { input = textView }
            else if let field = view as? NSTextField, window.window.makeFirstResponder(field) { input = field.currentEditor() as? (NSTextView & NSTextInputClient) }
            else { input = view.flatMap { root in sequence(first: root, next: { $0.subviews.first }).compactMap { $0 as? NSTextView }.first } }
            let editor = try #require(input, "\(label) has a text input: \(Swift.type(of: node.object))")
            _ = window.window.makeFirstResponder(editor)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        func say(_ text: String) async throws {
            try openGoal()
            try await type(text, into: Labels.plannerComposer)
            try await press(Labels.plannerSend)
        }
        try openGoal()
        // Nothing reaches a model until the owner allows the repository's files and continues planning.
        try await ready(Labels.allow(rig.space.name))
        #expect(rig.requests == 0, "no model request before explicit consent")
        #expect(!window.controls().contains { $0.label?.hasPrefix("/speckit.") == true || $0.label?.hasPrefix("Run /speckit.") == true },
                "the owner never drives stock commands")
        try await press(Labels.allow(rig.space.name))
        // Consent is saved before planning starts: wait for planning to reach the model, then for it to settle.
        try await eventuallyOnMain("planning started", timeout: .seconds(60)) { rig.requests > 0 || controller.error != nil }
        try await settle(.map)
        // The stock spec template marks questions, so the planner ran clarify and stops on its real question.
        var run = try #require(try controller.record(id).run)
        #expect(run.specKit?[rig.space.id]?.consentFingerprint != nil)
        #expect(run.pendingQuestion?.contains("Which authentication method") == true, "\(run.pendingQuestion ?? "no question")")
        #expect(rig.events.contains { $0["command"] as? String == "specify" && $0["done"] as? Bool == true })
        #expect(rig.events.contains { $0["command"] as? String == "clarify" && $0["done"] as? Bool == true })
        // Typed answer: bound to that question, it continues clarify's own thread, then plan and tasks follow.
        try await say("Email and password.")
        try await settle(.map)
        run = try #require(try controller.record(id).run)
        #expect(run.pendingQuestion == nil && run.notice?.contains("map is ready") == true, "\(run.notice ?? "")")
        #expect(run.messages.last { $0.role == .user }?.replyTo == run.messages.last { $0.question != nil }?.id)
        #expect(rig.events.contains { $0["owner"] as? String == "Email and password." && $0["after"] as? String == "clarify" })
        // General feedback with no question: into the planning conversation; nothing changed, nothing rebuilt.
        let plans = rig.events.filter { $0["command"] as? String == "plan" && $0["done"] as? Bool == true }.count
        try await say("Keep the edit minimal.")
        try await settle(.map)
        #expect(rig.events.contains { $0["owner"] as? String == "Keep the edit minimal." && $0["command"] == nil })
        #expect(rig.events.filter { $0["command"] as? String == "plan" && $0["done"] as? Bool == true }.count == plans)
        // Implement is held mid-turn so the station's embedded thread can steer it.
        try Data().write(to: rig.hold)
        // "Review the map" only navigates; Launch is the explicit approval. A ready map may already be showing.
        window.layout()
        if window.controls().contains(where: { $0.label == Labels.reviewMap && $0.isEnabled }) { try window.press(Labels.reviewMap) }
        try await press(Labels.launch)
        try await eventuallyOnMain("implement is working", timeout: .seconds(60)) {
            rig.events.contains { $0["command"] as? String == "implement" && ($0["step"] as? Int) == 1 }
        }
        let steer = "Prefer a minimal edit."
        // Run selects the running station; its thread is the Transcript tab.
        try await eventuallyOnMain("Transcript tab", timeout: .seconds(30)) { window.layout(); return window.controls().contains { $0.label == Labels.transcript } }
        let tab = try #require(window.controls().first { $0.label == Labels.transcript })
        try window.press(Labels.transcript, role: tab.role)
        do {
            try await eventuallyOnMain("embedded station thread composer", timeout: .seconds(30)) {
                window.layout()
                return AccessibilityNode.all(under: window.host).contains { $0.label == Labels.threadComposer && $0.object.responds(to: setter) }
            }
        } catch {
            let nodes = AccessibilityNode.all(under: window.host).compactMap { node in node.label.map { "\(node.role ?? "?") \($0)" } }
            Issue.record("No embedded composer. nodes=\(nodes.suffix(80))")
            throw error
        }
        // Type through the composer's own field editor (NSTextInputClient), in the offscreen window only:
        // no global focus, no posted events.
        let implementing = try #require(try controller.record(id).run?.attempts.last { $0.command == .implement })
        let node = try #require(AccessibilityNode.all(under: window.host).first { $0.label == Labels.threadComposer && $0.object.responds(to: setter) })
        // The composer's accessibility element is its field's cell (ComposerTextField.Cell).
        let field = try #require(((node.object as? NSCell)?.controlView ?? node.object as? NSView) as? NSTextField,
                                 "composer field: \(Swift.type(of: node.object))")
        try #require(window.window.makeFirstResponder(field), "the composer takes first responder in the offscreen window")
        let fieldEditor = try #require(field.currentEditor() as? (NSTextView & NSTextInputClient))
        fieldEditor.insertText(steer, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventuallyOnMain("typed words reach the agent's draft") {
            controller.vm?.threadStores.store(for: implementing.agentID!).draft == steer
        }
        try await ready(Labels.threadSend); try window.press(Labels.threadSend)
        try await eventuallyOnMain("steer accepted by the mission", timeout: .seconds(30)) {
            (try? controller.record(id).run?.attempts.contains { $0.command == .implement && $0.operationIDs?.isEmpty == false }) == true
        }
        try Data().write(to: rig.release)
        try await settle(.map)
        // The provider logs a steer on each request after it; the attempt records exactly one owned send.
        #expect(rig.events.contains { $0["command"] as? String == "implement" && $0["steer"] as? String == steer }, "the provider saw the owner's steer")
        #expect(try controller.record(id).run?.attempts.first { $0.id == implementing.id }?.operationIDs?.count == 1, "one Send, one steer")

        // Converge's report waits for the owner; only the accept control moves on, to Review.
        let lane = try #require(controller.record(id).run?.specKit?[rig.space.id])
        #expect(lane.convergence?.outcome == .unchanged && lane.convergence?.accepted == false)
        try await press(Labels.accept(rig.space.name))
        try await settle(.review)
        try rig.expectStockResult(id)
        // Finished steps (their pi stopped on purpose) show their real transcript from the session file.
        let finishedConverge = try #require(try controller.record(id).run?.attempts.last { $0.command == .converge })
        let history = try #require(controller.thread(for: finishedConverge.id))
        #expect(history.send == nil, "a finished step is read-only")
        let transcript = try #require(await history.preview?(), "the converge step's session file")
        #expect(transcript.messages.contains { $0.role == "assistant" }, "its real replies, not an empty starting thread")
        // The app holds the finished step's store offline: history from disk, no error, no "Starting", no restart.
        let finishedStore = history.store
        #expect(finishedStore.offline)
        // Count the host's answers: a finished step's pi is held off, so each pull is a `native_starting` (not serving)
        // answer, which an offline store treats as expected rather than as a start or a lost connection.
        final class Answers { var notServing = 0 }
        let answers = Answers()
        let counted: NativeThreadStore.Request = { request in
            do {
                let result = try await history.request(request)
                if case .failure(let code, _) = result, code == NativeThreadCode.starting { answers.notServing += 1 }
                return result
            } catch {
                if String(describing: error).hasPrefix(NativeThreadCode.starting) { answers.notServing += 1 }
                throw error
            }
        }
        let polling = Task { await finishedStore.run(request: counted, preview: history.preview) }
        try await eventuallyOnMain("history shown across several held-off answers", timeout: .seconds(30)) {
            !finishedStore.rows.isEmpty && answers.notServing >= 2
        }
        #expect(finishedStore.loadError == nil && !finishedStore.starting && !finishedStore.awaitingPi, "\(finishedStore.loadError ?? "")")
        polling.cancel(); finishedStore.stop()
        #expect(!window.window.isKeyWindow && !window.window.isMainWindow)
    }

    /// A steer that reaches pi while the turn's last model call is in flight (no tool calls follow), on the
    /// real engine: records what pi and the mission actually do with it.
    @Test func steerDuringTheFinalModelCallIsReportedTruthfullyWithoutANewTurn() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.lateSteerJourney() }
        }
        expectScenarioCompleted(result)
    }

    private static func lateSteerJourney() async throws {
        // converge: step 0 runs check-prerequisites, step 1 is its final text. Hold that final model call.
        let rig = try await Rig(holdCommand: "converge", holdStep: 1); defer { rig.stop() }
        let controller = rig.controller, space = rig.space
        let id = try await controller.create(goal: goal, spaces: [space.id], model: MissionRuntimeFixture.model, branches: [space.id: "refs/heads/main"])
        try await rig.wait(id, .map)
        let report = try #require(controller.specKitReports[id]?[space.id])
        try await controller.grantSpecKitConsent(id: id, revision: controller.record(id).revision, space: space.id, fingerprint: report.consentFingerprint)
        for command in [SpecKitCommand.specify, .plan, .tasks] {
            try await controller.runSpecKit(id: id, revision: controller.record(id).revision, command: command)
            try await rig.wait(id, .map)
        }
        try Data().write(to: rig.hold)
        try await controller.launch(id: id, revision: controller.record(id).revision)
        try await eventuallyOnMain("converge's final model call is held", timeout: .seconds(90)) {
            rig.events.contains { $0["command"] as? String == "converge" && $0["held"] != nil }
        }
        let converge = try #require(try controller.record(id).run?.attempts.last { $0.command == .converge && $0.status == .running })
        let steer = "Also mention the contract."
        // pi's acknowledgement is only "queued": the call returns once pi has read the message.
        let steering = Task { try await controller.steer(id: id, revision: try controller.record(id).revision, attemptID: converge.id, text: steer) }
        try await eventuallyOnMain("steer queued with pi") { (try? controller.record(id).run?.attempts.first { $0.id == converge.id }?.operationIDs?.count) == 1 }
        let requestsBefore = rig.requests
        try Data().write(to: rig.release)
        // Pinned pi checks its steering queue when a model call returns: a steer that arrived in time is read
        // and gets one more call in the same run; one that missed the check stays unread when the run ends.
        // Both happen (it is a race); the mission must say which, truthfully, and never start a turn for it.
        let consumed: Bool
        do { try await steering.value; consumed = true }
        catch let error as MissionError where error.code == "mission_steer_undelivered" { consumed = false }
        try await eventuallyOnMain("the mission settles after the late steer", timeout: .seconds(120)) {
            guard let run = rig.app.server.state.missions.first(where: { $0.id == id })?.run else { return false }
            return !run.phase.active && controller.jobs[id] == nil
        }
        let mission = try controller.record(id)
        let attempt = try #require(mission.run?.attempts.first { $0.id == converge.id })
        // Read after the final reply, pi's next call shows it as the run's newest user message.
        let seen = rig.events.contains { $0["steer"] as? String == steer || $0["owner"] as? String == steer }
        let evidence = ("late-steer-evidence seen=\(seen) phase=\(mission.run?.phase.rawValue ?? "nil") status=\(attempt.status.rawValue) notice=\(mission.run?.notice ?? "nil") requests=\(rig.requests) ops=\(attempt.operationIDs?.count ?? 0) output=\(attempt.output.prefix(300)) events=\(rig.events.filter { $0["command"] as? String == "converge" })")
        print(evidence)
        if ProcessInfo.processInfo.environment["SHEPHERD_SPECKIT_EVIDENCE"] == "1" { Issue.record(Comment(rawValue: evidence)) }
        if consumed {
            #expect(seen && attempt.undeliveredOperationIDs == nil, "a steer reported read reached the model in the same run")
            #expect(rig.requests == requestsBefore + 2, "the held reply plus the one call pi made for the steer")
        } else {
            if seen, let agent = attempt.agentID,
               case .snapshot(let snapshot)? = try? await rig.app.server.nativeThread(agentID: agent, request: .snapshot()) {
                let users = snapshot.messages.filter { $0.role == "user" }.map { "\($0.entryID) op=\($0.operationID?.uuidString ?? "nil") \($0.blocks.map(\.text).joined().prefix(60))" }
                Issue.record("late steer read by pi but reported undelivered. ops=\(attempt.operationIDs ?? []) users=\(users)")
            }
            #expect(!seen, "a steer reported undelivered never reached the model")
            #expect(attempt.undeliveredOperationIDs?.count == 1 && attempt.output.contains("not delivered"), "recorded as undelivered")
            #expect(rig.requests == requestsBefore + 1, "no turn was started to deliver it")
        }
    }

    static func sha(_ url: URL) throws -> String { SpecKit.sha256(try Data(contentsOf: url)) }

    /// The exact executable's install record and bundled generator inputs match the pinned tag.
    static func verifyProvenance(_ specify: URL) throws {
        let tool = specify.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let lib = tool.appendingPathComponent("lib")
        let python = try #require(try FileManager.default.contentsOfDirectory(atPath: lib.path).first { $0.hasPrefix("python3") })
        let site = lib.appendingPathComponent(python).appendingPathComponent("site-packages")
        let info = site.appendingPathComponent("specify_cli-1.2.3.dist-info")
        let direct = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: info.appendingPathComponent("direct_url.json"))) as? [String: Any])
        let vcs = try #require(direct["vcs_info"] as? [String: Any])
        try #require(direct["url"] as? String == "https://github.com/github/spec-kit.git" && vcs["commit_id"] as? String == commit,
                     "specify-cli is not the pinned github/spec-kit v1.2.3 commit: \(direct)")
        let pack = site.appendingPathComponent("specify_cli/core_pack")
        for (name, hash) in commandHashes { try #require(try sha(pack.appendingPathComponent("commands/\(name)")) == hash, "core_pack commands/\(name) differs from the tag") }
        for (name, hash) in scriptHashes { try #require(try sha(pack.appendingPathComponent("scripts/bash/\(name)")) == hash, "core_pack scripts/bash/\(name) differs from the tag") }
    }

    /// Bounded, offline, scratch-only process: HOME and XDG dirs in scratch, no bytecode writes into the install.
    static func run(_ executable: URL, _ arguments: [String], in directory: URL, scratch: URL, timeout: TimeInterval = 60) throws -> (status: Int32, output: String) {
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let home = scratch.appendingPathComponent("home")
        process.environment = ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                               "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path, "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
                               "TMPDIR": scratch.path, "PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "NO_COLOR": "1", "TERM": "dumb"]
        process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); process.waitUntilExit(); throw MissionError("timeout", "\(executable.lastPathComponent) exceeded \(timeout)s") }
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// Official init + bundled pi + loopback provider + app, shared by the controller and native-control journeys.
    @MainActor
    final class Rig {
        let root: URL, project: URL, log: URL, hold: URL, release: URL
        let app: AppHarness, vm: ShepherdViewModel, controller: MissionController, space: Space
        private let provider: Process, input: Pipe

        init(holdCommand: String = "implement", holdStep: Int = 2) async throws {
            let env = ProcessInfo.processInfo.environment
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let enginePath = env["SHEPHERD_ENGINE_SMOKE"].map { URL(fileURLWithPath: $0) } ?? repository.appendingPathComponent(".build/pi-engine")
            let engine = try #require(BundledPiEngine(contents: enginePath), "Stage the pinned engine at \(enginePath.path)")
            let specify = URL(fileURLWithPath: try #require(env["SHEPHERD_TEST_SPECKIT_SPECIFY"]))
            try MissionSpecKitEngineTests.verifyProvenance(specify)

            root = try makeScratchDirectory("speckit-accept")
            for folder in ["home/.config", "home/.cache", "home/.local/share"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            project = try MissionSpecKitEngineTests.initializeStockProject(specify, root: root)

            let userHome = root.appendingPathComponent("live-home")
            try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
            let setup = PiSetup(engine: .bundled(engine), home: root.appendingPathComponent("live-pi"), userHome: userHome.path)
            try setup.files.install()
            log = root.appendingPathComponent("provider.jsonl")
            hold = root.appendingPathComponent("hold-implement"); release = root.appendingPathComponent("release-implement")
            let config = root.appendingPathComponent("provider.json")
            try JSONSerialization.data(withJSONObject: ["launcher": setup.files.launcher.path, "log": log.path, "goal": MissionSpecKitEngineTests.goal,
                                                        "hold": hold.path, "release": release.path,
                                                        "holdCommand": holdCommand, "holdStep": holdStep]).write(to: config)
            provider = Process(); input = Pipe()
            let output = Pipe()
            provider.executableURL = engine.node
            provider.arguments = [repository.appendingPathComponent("Tests/Extensions/mission-speckit-provider.mjs").path, config.path]
            provider.currentDirectoryURL = root
            provider.environment = ["HOME": userHome.path, "TMPDIR": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            provider.standardInput = input; provider.standardOutput = output
            try provider.run()
            let port = try await MissionSpecKitEngineTests.readPort(output.fileHandleForReading)
            try Data("""
            {"providers":{"test":{"baseUrl":"http://127.0.0.1:\(port)/v1","api":"openai-completions","apiKey":"fixture-only",\
            "models":[{"id":"model","name":"model","reasoning":false,"input":["text"],"contextWindow":128000,"maxTokens":4096}]}}}
            """.utf8).write(to: setup.home.appendingPathComponent("models.json"))
            var settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: setup.files.settings)) as? [String: Any])
            settings["defaultProvider"] = "test"; settings["defaultModel"] = "model"
            settings["retry"] = ["enabled": false]; settings["compaction"] = ["enabled": false]
            try JSONSerialization.data(withJSONObject: settings).write(to: setup.files.settings)

            app = try AppHarness(pi: setup, modelCatalog: { .init(models: [MissionRuntimeFixture.model], defaultModel: MissionRuntimeFixture.model) })
            vm = try await app.start()
            space = Space(name: "Stock project", path: project.path)
            try await app.server.addSpace(space)
            let vm = vm
            try await eventuallyOnMain("stock project adopted") { vm.state.spaces.count == 1 }
            // Missions is an opt-in experiment (off by default); these journeys turn it on as a person would.
            vm.settings.missionsEnabled = true
            vm.openDestination(.missions)
            controller = vm.missions
            await controller.refreshModels()
        }

        func stop() {
            app.stop()
            try? input.fileHandleForWriting.close()
            if provider.isRunning { provider.terminate() }
            provider.waitUntilExit()
        }

        var events: [[String: Any]] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        var requests: Int { events.filter { $0["request"] != nil }.count }

        func wait(_ id: MissionID, _ phase: MissionRun.Phase) async throws {
            let app = app, controller = controller
            try await eventuallyOnMain("mission settles in \(phase.rawValue)", timeout: .seconds(120)) {
                // Reached, or stopped short: an owner action can save before the job it starts is scheduled.
                guard let run = app.server.state.missions.first(where: { $0.id == id })?.run, !run.phase.active, controller.jobs[id] == nil else { return false }
                return run.phase == phase || run.phase == .paused || run.phase == .stopped || controller.error != nil
            }
            let mission = try controller.record(id)
            let errors = events.compactMap { $0["error"] as? String }
            try #require(errors.isEmpty, "provider rejected a turn: \(errors)")
            try #require(mission.run?.phase == phase, "\(mission.run?.notice ?? controller.error ?? "no diagnostic")")
        }

        /// The stock end state, checked the same way after either journey.
        func expectStockResult(_ id: MissionID) throws {
            let events = events
            for command in ["specify", "plan", "tasks", "implement", "converge"] {
                #expect(events.contains { $0["command"] as? String == command && $0["done"] as? Bool == true }, "\(command) completed as an expanded stock turn")
            }
            #expect(events.filter { $0["command"] as? String == "implement" && $0["done"] as? Bool == true }.count == 1,
                    "accepting converge resumes review without implementing again")
            #expect(events.contains { ($0["output"] as? [String: Any])?["delegation"] as? String == "refused" },
                    "compatibility blocker recorded: nested pi -p is refused inside Spec Kit mission threads")
            let checkout = try #require(controller.record(id).run?.checkouts.first)
            let worktree = URL(fileURLWithPath: checkout.path)
            #expect(try String(contentsOf: worktree.appendingPathComponent("result.txt"), encoding: .utf8) == "after\n")
            #expect(try String(contentsOf: worktree.appendingPathComponent("specs/001-result/tasks.md"), encoding: .utf8).contains("- [X] T001"))
            #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("specs/001-result/plan.md").path), "setup-plan copied the stock plan template")
            #expect(try String(contentsOf: worktree.appendingPathComponent("specs/001-result/contracts/cli.md"), encoding: .utf8).contains("result.txt holds after"),
                    "implement's contract edit is kept as output")
            let check = try MissionSpecKitEngineTests.run(URL(fileURLWithPath: "/bin/bash"),
                                                          [".specify/scripts/bash/check-prerequisites.sh", "--json", "--require-tasks", "--include-tasks"],
                                                          in: worktree, scratch: root)
            #expect(check.status == 0 && check.output.contains("tasks.md"), "stock tooling reads the result: \(check.output)")
            #expect(try String(contentsOf: project.appendingPathComponent("result.txt"), encoding: .utf8) == "before\n", "primary checkout untouched")
            #expect(try controller.record(id).run?.publicationApproval == nil)
        }
    }

    /// Upstream init into a fresh, empty folder (no --force, extensions, presets, network or git), provenance-checked, then committed.
    static func initializeStockProject(_ specify: URL, root: URL) throws -> URL {
        let project = root.appendingPathComponent("project")
        let initialized = try run(specify, ["init", project.path, "--integration", "pi", "--script", "sh", "--ignore-agent-tools", "--non-interactive"],
                                  in: root, scratch: root)
        try #require(initialized.status == 0, "specify init failed: \(initialized.output)")
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: project.appendingPathComponent(".specify/integrations/pi.manifest.json"))) as? [String: Any])
        let managed = try #require(manifest["files"] as? [String: String])
        var generated: [String: String] = [:]
        for command in SpecKitCommand.allCases {
            let file = project.appendingPathComponent(command.promptPath)
            generated[command.promptPath] = try sha(file)
            #expect(managed[command.promptPath] == generated[command.promptPath], "\(command.promptPath) matches upstream's own install manifest")
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("{SCRIPT}") && !text.contains("__SPECKIT_COMMAND_"), "\(command.promptPath) is upstream-processed, not a raw template")
        }
        // Upstream renders the pi invocation into some helpers' command formatters at install time, so the
        // installed scripts are checked against upstream's own shared-infra manifest; the generator's
        // inputs were checked against the tag above, and unrendered helpers must still be tag bytes.
        let shared = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: project.appendingPathComponent(".specify/integrations/speckit.manifest.json"))) as? [String: Any])
        let sharedFiles = try #require(shared["files"] as? [String: String])
        for name in scriptHashes.keys {
            let path = ".specify/scripts/bash/\(name)"
            #expect(sharedFiles[path] == (try? sha(project.appendingPathComponent(path))), "\(path) matches upstream's shared-infra manifest")
        }
        for name in ["common.sh", "setup-plan.sh"] {
            #expect((try? sha(project.appendingPathComponent(".specify/scripts/bash/\(name)"))) == scriptHashes[name], "\(name) installed byte-for-byte from the tag")
        }
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent(".specify/templates/spec-template.md").path))
        print("speckit-provenance commit=\(commit) prompts=\(generated.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
        try Data("before\n".utf8).write(to: project.appendingPathComponent("result.txt"))
        try git(["init", "-q", "-b", "main"], in: project)
        try git(["-c", "user.name=Spec Kit Acceptance", "-c", "user.email=acceptance@example.invalid", "add", "-A"], in: project)
        try git(["-c", "user.name=Spec Kit Acceptance", "-c", "user.email=acceptance@example.invalid", "commit", "-q", "-m", "specify init --integration pi"], in: project)
        try #require(!(try git(["ls-files"], in: project)).contains(".specify/feature.json"))
        return project
    }

    private static func journey() async throws {
        let rig = try await Rig(); defer { rig.stop() }
        let controller = rig.controller, space = rig.space
        let id = try await controller.create(goal: goal, spaces: [space.id], model: MissionRuntimeFixture.model, branches: [space.id: "refs/heads/main"])
        try await rig.wait(id, .map)
        let report = try #require(controller.specKitReports[id]?[space.id])
        try #require(report.status == .ready && report.matchesTestedRelease && report.customizedFiles.isEmpty, "\(report)")
        #expect(rig.requests == 0, "nothing reaches the provider before consent")
        try await controller.grantSpecKitConsent(id: id, revision: controller.record(id).revision, space: space.id, fingerprint: report.consentFingerprint)
        for command in [SpecKitCommand.specify, .plan, .tasks] {
            try await controller.runSpecKit(id: id, revision: controller.record(id).revision, command: command)
            try await rig.wait(id, .map)
        }
        try await controller.launch(id: id, revision: controller.record(id).revision)
        try await rig.wait(id, .map)
        let lane = try #require(controller.record(id).run?.specKit?[space.id])
        #expect(lane.featureDirectory == "specs/001-result")
        let convergence = try #require(lane.convergence)
        #expect(convergence.outcome == .unchanged && !convergence.accepted, "converge's report waits for the owner")
        try await controller.acceptConvergence(id: id, revision: controller.record(id).revision, attemptID: convergence.attemptID)
        try await rig.wait(id, .review)
        try rig.expectStockResult(id)
    }

    static func readPort(_ handle: FileHandle) async throws -> Int {
        let bytes = Locked(Data())
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            bytes.withValue { $0.append(chunk) }
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
        defer { handle.readabilityHandler = nil }
        var port: Int?
        try await eventuallyOnMain("Spec Kit loopback provider listening") {
            let data = bytes.current
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
                  let value = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any] else { return false }
            port = value["port"] as? Int
            return port != nil
        }
        return try #require(port)
    }
}

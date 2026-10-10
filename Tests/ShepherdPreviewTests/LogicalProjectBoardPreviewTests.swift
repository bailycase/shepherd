import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
@testable import ShepherdApp

/// ProjectLead boards 07 (Started) and 08 (ThreadRunning), driven through the runtime that produces them: the stub engine plays a
/// script, the coordinator's tool calls are real `projectRuntime` requests to the owner (`owner_call` in stub-pi.py, the same wire
/// as `Extensions/shepherd-project-context.ts`), and each worker reports its plan as a real `project_plan` tool result. No view
/// string is typed in. The words are the fixture author's; every card, count, age and row comes from the owner and the native thread.
extension LogicalProjectPreviewTests {
    /// The `project_plan` result exactly as the extension returns it (`{"version":1,"steps":[...]}`).
    private static func planResult(_ steps: [(String, String)]) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["version": 1, "steps": steps.map { ["text": $0.0, "state": $0.1] }])
        return ["toolName": "project_plan", "content": [["type": "text", "text": String(decoding: body, as: UTF8.self)]], "details": [String: Any]()]
    }

    /// What the engine reports as its model (the composer's own label), as the stub's startup file says it: the named model the boards
    /// show, and `level` (nil for a model that reports no reasoning level).
    private static func startup(model: String, level: String?, in folder: URL) throws {
        var config: [String: Any] = ["model": ["id": model, "name": model, "reasoning": level != nil]]
        if let level { config["thinkingLevel"] = level } else { config["noThinkingLevels"] = true }
        try JSONSerialization.data(withJSONObject: config).write(to: folder.appendingPathComponent("stub-pi-startup.json"))
    }

    private static func write(_ book: [String: Any], to folder: URL) throws {
        try JSONSerialization.data(withJSONObject: book).write(to: folder.appendingPathComponent("project-script.json"))
    }

    /// Boards 05 (Question), 06 (Resolved) and 04 (Paused with its question): three assigned workers, two of which finish (and are
    /// resolved through the runtime's own `resolve`), one that holds a real native select. Pause keeps that question waiting.
    @Test func boardsQuestionResolvedAndPausedFromScriptedWorkers() async throws {
        try StubPi.installAsEngine()
        let (world, projects) = try await world(projects: [("Gamecards", "Launch a gift card reseller API for game partners"), ("Latency budget", "")])
        defer { world.stop() }
        let vm = world.vm
        let ref = LogicalProjectRef(home: .local, id: projects[0].id)
        let space = try #require(vm.state.spaces.last { !$0.hidden })
        let ask = "i want to test projects a bit, can you spin up some threads or something of what you would do"
        let again = "lets try it out"
        let jobs = [("Gift card market scan", "Research how the market already handles gift card reselling."),
                    ("Partner API draft", "Draft the partner integration API as an OpenAPI spec."),
                    ("Checkout widget mockup", "Build a clickable mockup of the embeddable checkout widget.")]
        // Every worker waits for `release-workers` before it plays, so the coordinator's closing words (which link the tasks by the IDs the
        // owner assigned) are in its book before any worker event wakes it.
        let release: [String: Any] = ["wait": "release-workers", "timeout": 120]
        let done: [[String: Any]] = [release, ["tool": try Self.planResult([("Researched the market", "done"), ("Wrote it up", "done")])],
                                     ["publish": ["source": "scan-source.md", "name": "gift-card-platforms.md", "content": "# Market scan\nTango, Tremendous, Runa"]],
                                     ["text": "The market scan is written up."]]
        var prompts: [String: Any] = [jobs[0].1: done,
                                      jobs[2].1: [release, ["tool": try Self.planResult([("Built the storefront and checkout mockup", "done"), ("Published it to the project’s files", "done")])],
                                                  ["publish": ["source": "widget-source.html", "name": "checkout-widget.html", "content": "<h1>Checkout</h1>"]],
                                                  ["text": "The clickable checkout widget mockup is ready. It shows the widget on a made-up partner site."]]]
        prompts[jobs[1].1] = [release, ["startedAgo": 1740],
                              ["publish": ["source": "overview-source.md", "name": "overview.md", "content": "# Partner API"]],
                              ["publish": ["source": "openapi-source.yaml", "name": "openapi.yaml", "content": "openapi: 3.1.0"]],
                              ["ask": ["title": "Who should take the payment when a user buys a gift card?",
                                       "options": ["Partners (Recommended)\nPartners charge users and draw on a prepaid balance; we avoid card fees and most fraud risk.",
                                                   "Gamecards\nWe run checkout as merchant of record; easier for partners but we eat processing fees and chargebacks.",
                                                   "Both\nPartners choose either mode; most flexible but roughly doubles the payment and fraud work."]]]]
        try Self.write(["prompts": prompts, "socket": world.scratch.socketPath], to: URL(fileURLWithPath: space.path))
        try Self.startup(model: "claude-sonnet-4-6", level: nil, in: URL(fileURLWithPath: space.path))
        var items: [[String: Any]] = [["text": "Happy to. I’m splitting out three starter threads for Gamecards so you can see how it works."]]
        for (index, job) in jobs.enumerated() {
            items.append(["text": ["First, a look at how the market already handles gift card reselling.", "Second, a draft of the partner integration API.",
                                   "Third, a clickable mockup of the embeddable checkout widget."][index]])
            items.append(["owner": ["project_assign": ["title": job.0, "prompt": job.1]]])
        }
        let coordinatorFolder = world.dir.appendingPathComponent("logical-projects/\(ref.id.rawValue)")
        try Self.write(["prompts": [ask: items], "socket": world.scratch.socketPath], to: coordinatorFolder)
        try Self.startup(model: "claude-sonnet-4-6", level: "low", in: coordinatorFolder)
        #expect(await vm.logicalProjects.sendMessage(ref, text: ask))
        try await eventuallyOnMain("three workers assigned", timeout: .seconds(60)) { vm.state.projects.first?.tasks.count == 3 }
        // The coordinator's words once the workers report: its reaction to the third worker event (two settle, one asks), linking each
        // task by the ID the owner assigned; and its reply to the person's "lets try it out" with the worker's context for the question.
        let assigned = vm.state.projects.first?.tasks ?? []
        func link(_ title: String) throws -> String {
            let id = try #require(assigned.first { $0.title == title }?.id)
            return "[\(title)](\(ProjectTaskLinks.url(project: ref.id, task: id)))"
        }
        let closing = "All three threads have finished. The \(try link(jobs[0].0)) and the \(try link(jobs[2].0)) don’t need anything from you. The \(try link(jobs[1].0)) has four questions only you can answer, starting with who takes the payment."
        try Self.write(["prompts": [ask: items, again: [["text": "From the partner API draft. It assumes partners charge users and buy cards from a prepaid balance."]]],
                        "events": [[["text": closing]]],
                        "socket": world.scratch.socketPath], to: coordinatorFolder)
        FileManager.default.createFile(atPath: URL(fileURLWithPath: space.path).appendingPathComponent("release-workers").path, contents: nil)
        try await eventuallyOnMain("two settled and one is waiting on you", timeout: .seconds(60)) {
            let phases = vm.state.projects.first?.tasks.map(\.phase) ?? []
            return phases.filter { $0 == .settled }.count == 2 && phases.filter { $0 == .waiting }.count == 1
        }
        // The person's own Resolve, through the runtime, on each settled task: two of three done.
        for title in [jobs[0].0, jobs[2].0] {
            let id = try #require(vm.state.projects.first?.tasks.first { $0.title == title }?.id)
            let ok = await vm.logicalProjects.resolve(ref, task: id)
            #expect(ok, "Resolve \(title): \(vm.logicalProjects.failure?.message ?? "no refusal")")
            // The next action carries the revision the owner published: wait for this one to land rather than retry a refusal.
            try await eventuallyOnMain("\(title) is resolved on the owner") { vm.state.projects.first?.tasks.first { $0.id == id }?.phase == .resolved }
        }
        let tasks = vm.state.projects.first?.tasks ?? []
        #expect(await vm.logicalProjects.sendMessage(ref, text: again))
        let workers = tasks.map(\.workerAgentID)
        for id in workers { Task { await vm.threadStores.store(for: id).run(request: { try await vm.server.nativeThread(agentID: id, request: $0) }) } }
        let coordinator = try #require(vm.state.projects.first?.coordinatorAgentID)
        let server = vm.server
        Task { await vm.threadStores.store(for: coordinator).run(request: { try await server.nativeThread(agentID: coordinator, request: $0) }) }
        let waiting = try #require(tasks.first { $0.title == jobs[1].0 })
        let workerStore = vm.threadStores.store(for: waiting.workerAgentID)
        vm.openLogicalProject(ref)
        let ready: @MainActor () -> Bool = {
            let conversation = vm.projectCoordinator.conversationStore(agentID: coordinator)
            let cards = conversation?.rows.flatMap(\.turn.messages).filter { $0.projectAction?.taskID != nil }.count ?? 0
            let said = conversation?.rows.flatMap(\.turn.messages).contains { $0.blocks.contains { $0.text.hasPrefix("All three threads") } } ?? false
            let published = vm.state.projects.first?.artifacts.filter { $0.state == .ready }.count ?? 0
            return cards == 3 && said && published == 4 && !workerStore.dialogs.isEmpty
        }
        // Board 05: the conversation alone (the Threads pane closed).
        vm.logicalProjectPaneOpen = false
        try await Preview.renderMatrix("board-question", size: CGSize(width: 1600, height: 900), scales: [1, 1.3], ready: ready) { window(vm, style: .projects) }
        // Board 06: a resolved task opened in the pane, with its footer and Reopen.
        vm.logicalProjectPaneOpen = true
        vm.logicalProjectPaneTask = tasks.first { $0.title == jobs[2].0 }?.id
        try await Preview.renderMatrix("board-resolved", size: CGSize(width: 1600, height: 900), scales: [1, 1.3], ready: ready) { window(vm, style: .projects) }
        // Board 04: Pause. The question stays waiting (the runtime does not abort a turn that is only asking).
        vm.logicalProjectPaneTask = nil
        #expect(await vm.logicalProjects.setPaused(ref, true))
        try await eventuallyOnMain("paused, with the question still waiting", timeout: .seconds(30)) {
            vm.state.projects.first?.paused == true && vm.state.projects.first?.tasks.first { $0.title == jobs[1].0 }?.phase == .waiting
        }
        try await Preview.renderMatrix("board-paused", size: CGSize(width: 1600, height: 900), scales: [1, 1.3], ready: ready) { window(vm, style: .projects) }
    }

    /// Board 07: three working threads, the conversation with three task cards, "Starting threads" live, the Threads pane grouped Working.
    @Test(arguments: ["started", "thread-running"])
    func boardStartedFromAScriptedCoordinatorAndThreeScriptedWorkers(state: String) async throws {
        try StubPi.installAsEngine()
        let (world, projects) = try await world(projects: [("Gamecards", "Launch a gift card reseller API for game partners"), ("Latency budget", "")])
        defer { world.stop() }
        let vm = world.vm
        let ref = LogicalProjectRef(home: .local, id: projects[0].id)
        let space = try #require(vm.state.spaces.last { !$0.hidden })
        let ask = "i want to test projects a bit, can you spin up some threads or something of what you would do"
        let jobs = [("Gift card market scan", "Research how the market already handles gift card reselling.",
                     [("Researching Tango, Tremendous, Runa", "current"), ("Write up what each one charges", "pending")], 1800),
                    ("Partner API draft", "Draft the partner integration API as an OpenAPI spec.",
                     [("Writing the OpenAPI spec", "current"), ("List the open questions", "pending")], 1740),
                    ("Checkout widget mockup", "Build a clickable mockup of the embeddable checkout widget.",
                     [("Building the storefront and checkout mockup", "current"), ("Publish it to the project’s files", "pending")], state == "started" ? 1800 : 52)]
        // Each worker plays its own script, keyed by its assignment (they share the linked Space's folder).
        var prompts: [String: Any] = [:]
        for job in jobs {
            // The worker introduces what it is about to do (a genuine assistant message), then reports its plan and keeps working.
            let intro: [[String: Any]] = job.0 == "Checkout widget mockup" ? [["text": "Building a quick interactive mockup of the widget a partner would embed."]] : []
            prompts[job.1] = [["startedAgo": job.3]] + intro + [["tool": try Self.planResult(job.2)], ["wait": "hold-workers", "timeout": 600]]
        }
        try Self.startup(model: "claude-sonnet-4-6", level: nil, in: URL(fileURLWithPath: space.path))
        try Self.write(["prompts": prompts, "socket": world.scratch.socketPath], to: URL(fileURLWithPath: space.path))
        let openers = ["Happy to. I’m splitting out three starter threads for Gamecards so you can see how it works.",
                       "First, a look at how the market already handles gift card reselling.",
                       "Second, a draft of the partner integration API.",
                       "Third, a clickable mockup of the embeddable checkout widget."]
        var items: [[String: Any]] = [["text": openers[0]]]
        for (index, job) in jobs.enumerated() {
            items.append(["text": openers[index + 1]])
            items.append(["owner": ["project_assign": ["title": job.0, "prompt": job.1]]])
        }
        items.append(["wait": "hold-coordinator", "timeout": 600])
        let coordinatorFolder = world.dir.appendingPathComponent("logical-projects/\(ref.id.rawValue)")
        try Self.write(["prompts": [ask: items], "socket": world.scratch.socketPath], to: coordinatorFolder)
        try Self.startup(model: "claude-sonnet-4-6", level: "low", in: coordinatorFolder)

        #expect(await vm.logicalProjects.sendMessage(ref, text: ask))
        do {
            try await eventuallyOnMain("three workers were assigned by the coordinator's own tool calls", timeout: .seconds(40)) {
                vm.state.projects.first?.tasks.count == 3 && vm.state.projects.first?.tasks.allSatisfy { $0.phase == .running } == true
            }
        } catch {
            let p = vm.state.projects.first
            throw PreviewError("not assigned: tasks \(p?.tasks.map { "\($0.title):\($0.phase)" } ?? []), messages \(p?.messages.map { "\($0.phase)" } ?? []), paused \(p?.paused as Any), coordinator \(p?.coordinatorAgentID as Any), failure \(vm.logicalProjects.failure?.message ?? "none")")
        }
        let workers = (vm.state.projects.first?.tasks ?? []).map(\.workerAgentID)
        for id in workers { Task { await vm.threadStores.store(for: id).run(request: { try await vm.server.nativeThread(agentID: id, request: $0) }) } }
        let coordinator = try #require(vm.state.projects.first?.coordinatorAgentID)
        let server = vm.server
        Task { await vm.threadStores.store(for: coordinator).run(request: { try await server.nativeThread(agentID: coordinator, request: $0) }) }
        vm.openLogicalProject(ref)
        let ready: @MainActor () -> Bool = {
            let store = vm.projectCoordinator.conversationStore(agentID: coordinator)
            let cards = store?.rows.flatMap(\.turn.messages).filter { $0.projectAction?.taskID != nil }.count ?? 0
            return cards == 3 && workers.allSatisfy { vm.workerActivity($0) != nil && vm.workerStarted($0) != nil }
        }
        if state == "started" {
            try await Preview.renderMatrix("board-started", size: CGSize(width: 1600, height: 900), scales: [1, 1.3], ready: ready) { window(vm, style: .projects) }
        } else {
            // Board 08: the third worker's own thread beside the conversation, steering composer, its plan as the Steps card.
            vm.logicalProjectPaneTask = vm.state.projects.first?.tasks.last?.id
            let worker = try #require(vm.state.projects.first?.tasks.last?.workerAgentID)
            let running: @MainActor () -> Bool = {
                ready() && vm.threadStores.store(for: worker).rows.contains { $0.presentation?.latestProjectPlan != nil }
            }
            try await Preview.renderMatrix("board-thread-running", size: CGSize(width: 1600, height: 900), scales: [1, 1.3], ready: running) { window(vm, style: .projects) }
            // The same state with the worker's composer focused, through the app's own request (`ThreadInput.focus()`), and `ready` waits
            // until the window's first responder is a field editor, as `theComposerTakesTheKeyboardAgainWhenItsThreadComesBack` does.
            let workerInput = vm.threadStores.input(for: worker)
            var asked: Set<ObjectIdentifier> = []
            let focused: @MainActor () -> Bool = {
                guard running() else { return false }
                let windows = NSApp.windows.filter { $0.frame.origin.x < -20_000 }
                // Each appearance and text scale is a new window: ask once in each, after it has mounted.
                for window in windows where asked.insert(ObjectIdentifier(window)).inserted {
                    // A window has one first responder and the conversation's composer holds it: let go, then ask for the worker's.
                    _ = window.makeFirstResponder(nil)
                    workerInput.focus()
                }
                return windows.compactMap { $0.firstResponder as? NSTextView }.filter(\.isFieldEditor)
                    .contains { ($0.delegate as? NSView).map { $0.convert($0.bounds, to: nil).minX > 1121 } ?? false }
            }
            try await Preview.renderMatrix("board-thread-running-worker-focus", size: CGSize(width: 1600, height: 900), scales: [1, 1.3], ready: focused) {
                window(vm, style: .projects)
            }
        }
    }

    /// The worker thread when a person steers it: the assignment and the person's own words are consecutive user messages, so one native
    /// user turn. The assignment draws as the board's plain prose, the person's words as a bubble (with an image, whose chip is the
    /// bubble's attachment). Nothing is typed in: the steer goes through the worker's own store and the engine reads it as pi does.
    @Test func boardWorkerThreadWithAnAssignmentAndAPersonsSteer() async throws {
        try StubPi.installAsEngine()
        let (world, projects) = try await world(projects: [("Gamecards", "Launch a gift card reseller API for game partners")])
        defer { world.stop() }
        let vm = world.vm
        let ref = LogicalProjectRef(home: .local, id: projects[0].id)
        let space = try #require(vm.state.spaces.last { !$0.hidden })
        let prompt = "Build a clickable mockup of the embeddable checkout widget."
        try Self.startup(model: "claude-sonnet-4-6", level: nil, in: URL(fileURLWithPath: space.path))
        // The worker holds before its first reply, so the person's steer is read into the assignment's own user turn.
        try Self.write(["prompts": [prompt: [["wait": "hold-workers", "timeout": 600]]], "socket": world.scratch.socketPath], to: URL(fileURLWithPath: space.path))
        let owner = try await vm.projectCoordinator.perform(projectID: ref.id, expectedRevision: try #require(vm.state.projects.first).revision,
            request: .assign(operationID: UUID(), spaceID: space.id, title: "Checkout widget mockup", prompt: prompt))
        let task = try #require(owner.tasks.first)
        try await eventuallyOnMain("the worker is running", timeout: .seconds(40)) { vm.state.projects.first?.tasks.first?.phase == .running }
        // The pane's own store and request (by Project and task): the steer goes where the person's composer would send it.
        let store = vm.projectWorkerStore(.local, task.workerAgentID)
        Task { await store.run(request: vm.projectWorkerRequest(ref, task: task.id)) }
        try await eventuallyOnMain("the assignment is the worker's first user message") { store.rows.contains { $0.isUser } && store.running }
        vm.openLogicalProject(ref)
        vm.logicalProjectPaneTask = task.id
        store.draft = "use the blue theme"
        _ = await store.send(delivery: .steer)
        FileManager.default.createFile(atPath: URL(fileURLWithPath: space.path).appendingPathComponent("hold-workers").path, contents: nil)
        let mixed: @MainActor () -> Bool = { store.rows.contains { $0.isUser && $0.turn.messages.count == 2 } }
        do { try await eventuallyOnMain("the steer joined the assignment's user turn", timeout: .seconds(20), mixed) } catch {
            throw PreviewError("rows \(store.rows.map { "\($0.isUser ? "user" : "agent")\($0.turn.messages.map { $0.blocks.first?.text.prefix(20) ?? "" })" }) queue \(store.queue.map(\.text)) running \(store.running)")
        }
        try await Preview.renderMatrix("board-worker-mixed", size: CGSize(width: 1600, height: 900), scales: [1, 1.3], ready: mixed) { window(vm, style: .projects) }
    }

    /// Boards 09 (Empty) and 01-03's page: the whole window over a real, freshly created Project (no conversation yet), a bare one with
    /// no Space or goal, and one with a long name, goal and Space name. The producer is the owner's own create; nothing is typed in.
    @Test(arguments: ["gamecards", "bare", "long"])
    func boardOverviewWindow(state: String) async throws {
        let long = String(repeating: "Gamecards platform ", count: 6), goal = String(repeating: "Launch a gift card reseller API for game partners. ", count: 4)
        let (world, projects) = try await world(spaces: state == "long" ? 0 : 3, projects: [state == "bare" ? ("Latency budget", "") : state == "long" ? (long, goal) : ("Gamecards", "Launch a gift card reseller API for game partners")],
                                                link: state == "gamecards")
        defer { world.stop() }
        let vm = world.vm
        if state == "long" {
            // A Space whose own name is long, linked through the owner's own request.
            let folder = world.dir.appendingPathComponent(String(repeating: "gift-card-reseller-", count: 4))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let space = Space(name: folder.lastPathComponent, path: folder.path)
            try await world.server.addSpace(space)
            let shown = try #require(vm.state.projects.first)
            _ = try await world.server.logicalProjects(.linkSpace(projectID: shown.id, expectedRevision: shown.revision, spaceID: space.id, host: nil))
            try await eventuallyOnMain("the Space is linked") { vm.state.projects.first?.linkedSpaces.count == 1 }
        }
        vm.openLogicalProject(LogicalProjectRef(home: .local, id: projects[0].id))
        try await Preview.renderMatrix("board-overview-\(state)", size: CGSize(width: 1600, height: 900), scales: [1, 1.3]) { window(vm, style: .projects) }
    }

    /// Long task title and long file names from a real publishing worker, a reply that links the task, at 1x and 1.3 in a wide and a
    /// narrow window: the chips ellipsize inside the card, never overlap its title or the pane, and the link wraps.
    @Test func boardLongTitleAndFileNamesFromARealPublisher() async throws {
        try StubPi.installAsEngine()
        let (world, projects) = try await world(projects: [("Gamecards", "Launch a gift card reseller API for game partners"), ("Latency budget", "")])
        defer { world.stop() }
        let vm = world.vm
        let ref = LogicalProjectRef(home: .local, id: projects[0].id)
        let space = try #require(vm.state.spaces.last { !$0.hidden })
        let title = "Compare how every gift card marketplace handles partner payouts, refunds and chargebacks"
        let names = ["gift-card-marketplace-payout-refund-and-chargeback-comparison-2026-final-v3.md", "partner-share-schedule.csv"]
        let ask = "start the long one"
        try Self.write(["prompts": ["long job": [["publish": ["source": "a.md", "name": names[0], "content": "# Comparison"]],
                                                 ["publish": ["source": "b.csv", "name": names[1], "content": "a,b"]],
                                                 ["text": "Done."]]], "socket": world.scratch.socketPath], to: URL(fileURLWithPath: space.path))
        let folder = world.dir.appendingPathComponent("logical-projects/\(ref.id.rawValue)")
        try Self.write(["prompts": [ask: [["text": "Starting that now."], ["owner": ["project_assign": ["title": title, "prompt": "long job"]]]]], "socket": world.scratch.socketPath], to: folder)
        #expect(await vm.logicalProjects.sendMessage(ref, text: ask))
        try await eventuallyOnMain("the task settled with two ready files", timeout: .seconds(60)) {
            vm.state.projects.first?.tasks.first?.phase == .settled && vm.state.projects.first?.artifacts.filter { $0.state == .ready }.count == 2
        }
        let task = try #require(vm.state.projects.first?.tasks.first)
        try Self.write(["prompts": [ask: [["text": "Starting that now."], ["owner": ["project_assign": ["title": title, "prompt": "long job"]]]],
                                    "and?": [["text": "The [whatever I called it](\(ProjectTaskLinks.url(project: ref.id, task: task.id))) is finished, and a quick note follows so the line has to wrap around the chip."]]],
                        "socket": world.scratch.socketPath], to: folder)
        // The owner takes the next message once the first one has been delivered to the coordinator.
        try await eventuallyOnMain("the first message was delivered", timeout: .seconds(30)) { vm.state.projects.first?.messages.allSatisfy { $0.phase == .delivered } == true }
        #expect(await vm.logicalProjects.sendMessage(ref, text: "and?"))
        let coordinator = try #require(vm.state.projects.first?.coordinatorAgentID)
        let server = vm.server
        Task { await vm.threadStores.store(for: coordinator).run(request: { try await server.nativeThread(agentID: coordinator, request: $0) }) }
        vm.openLogicalProject(ref)
        let ready: @MainActor () -> Bool = {
            let rows = vm.projectCoordinator.conversationStore(agentID: coordinator)?.rows.flatMap(\.turn.messages) ?? []
            return rows.contains { $0.projectAction?.taskID != nil } && rows.contains { $0.blocks.contains { $0.text.hasPrefix("The [whatever") } }
        }
        vm.logicalProjectPaneOpen = false
        try await Preview.renderMatrix("board-long-chips", size: CGSize(width: 1600, height: 900), scales: [1, 1.3], ready: ready) { window(vm, style: .projects) }
        vm.logicalProjectPaneOpen = true
        try await Preview.renderMatrix("board-long-chips-narrow", size: CGSize(width: 1000, height: 900), scales: [1, 1.3], ready: ready) {
            HStack(spacing: 0) { LogicalProjectDestination(vm: vm) }.frame(width: 1000, height: 900)
        }
    }
}

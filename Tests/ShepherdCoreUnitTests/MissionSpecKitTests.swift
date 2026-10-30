import Foundation
import Testing
@testable import ShepherdCore

@Suite("Mission Spec Kit artifacts")
struct MissionSpecKitTests {
    private func project(version: String = "1.2.3", extensions: String? = nil, customize: Bool = false) -> [String: Data] {
        var files: [String: Data] = [:]
        for command in SpecKitCommand.allCases { files[command.promptPath] = Data("---\ndescription: \(command)\n---\n$ARGUMENTS\n".utf8) }
        let manifest = Dictionary(uniqueKeysWithValues: SpecKitCommand.allCases.map { ($0.promptPath, SpecKit.sha256(files[$0.promptPath]!)) })
        files[".specify/integrations/pi.manifest.json"] = try! JSONSerialization.data(withJSONObject: ["integration": "pi", "files": manifest])
        files[".specify/init-options.json"] = Data(#"{"integration":"pi","script":"sh","feature_numbering":"sequential","speckit_version":"\#(version)"}"#.utf8)
        files[".specify/integration.json"] = Data(#"{"installed_integrations":["none","pi"],"default_integration":"none"}"#.utf8)
        files[".specify/scripts/bash/common.sh"] = Data("echo\n".utf8)
        if customize { files[SpecKitCommand.plan.promptPath] = Data("team preset\n".utf8) }
        if let extensions { files[".specify/extensions.yml"] = Data(extensions.utf8) }
        return files
    }

    @Test func invocationMatchesUpstreamPiDispatch() {
        // tests/integrations/test_integration_pi.py: ["pi", "-p", "/speckit.specify build a login page"]
        #expect(SpecKitCommand.specify.invocation(" build a login page ") == "/speckit.specify build a login page")
        #expect(SpecKitCommand.converge.invocation("") == "/speckit.converge")
    }

    @Test func preflightSeparatesMetadataFromVerifiedFilesAndKeepsCustomizations() {
        let stock = SpecKit.preflight(project())
        #expect(stock.status == .ready)
        #expect(stock.matchesTestedRelease)
        #expect(stock.integrations == ["none", "pi"] && stock.defaultIntegration == "none")
        let custom = SpecKit.preflight(project(customize: true))
        #expect(custom.status == .ready)
        #expect(!custom.matchesTestedRelease, "a 1.2.3 version string alone verifies nothing")
        #expect(custom.customizedFiles == [SpecKitCommand.plan.promptPath])
        #expect(custom.consentFingerprint != stock.consentFingerprint)
        let older = SpecKit.preflight(project(version: "1.1.0"))
        #expect(older.status == .ready && !older.matchesTestedRelease && !older.warnings.isEmpty)
    }

    @Test func preflightReportsMissingProjectsAndIntegrations() {
        #expect(SpecKit.preflight([:]).status == .notInitialized)
        var none = project()
        for command in SpecKitCommand.allCases { none[command.promptPath] = nil }
        none[".specify/integration.json"] = Data(#"{"installed_integrations":["none"]}"#.utf8)
        let report = SpecKit.preflight(none)
        #expect(report.status == .piIntegrationMissing)
        #expect(report.missingCommands == SpecKitCommand.allCases)
    }

    @Test func hooksAsUpstreamWritesThemIncludingTheGitFeatureBranchHookAreReady() {
        let yaml = """
        installed:
        - git
        - agent-context
        hooks:
          before_specify:
          - extension: git
            command: speckit.git.feature
            enabled: true
            optional: false
            priority: 10
            description: Create feature branch before specification
            condition: null
          after_plan:
          - extension: agent-context
            command: speckit.agent-context.update
            enabled: true
            optional: true
            prompt: 'Refresh agent context?'
          after_tasks: []
        """
        let report = SpecKit.preflight(project(extensions: yaml))
        #expect(report.hooks.map(\.command) == ["speckit.git.feature", "speckit.agent-context.update"])
        #expect(report.hooks.map(\.optional) == [false, true])
        // The git extension's branch hook runs as stock; the mission adopts the branch it creates.
        #expect(report.status == .ready && report.ownershipConflicts.isEmpty)
        let disabled = SpecKit.preflight(project(extensions: yaml.replacingOccurrences(of: "enabled: true\n    optional: false", with: "enabled: false\n    optional: false")))
        #expect(disabled.status == .ready && disabled.warnings.allSatisfy { !$0.contains("could not read") })
        let odd = SpecKit.preflight(project(extensions: "hooks: {before_plan: [{command: x}]}\n"))
        #expect(odd.warnings.contains { $0.contains("could not read") })
    }

    @Test func constitutionTemplateAndCriticalAnalysisAreRecognized() {
        #expect(SpecKit.constitutionNeedsWriting(nil))
        #expect(SpecKit.constitutionNeedsWriting("# [PROJECT_NAME] Constitution\n### [PRINCIPLE_1_NAME]\n"))
        #expect(!SpecKit.constitutionNeedsWriting("# Shop Constitution\n### I. Test-First\n"))
        let table = "| ID | Category | Severity | Location(s) | Summary | Recommendation |\n|---|---|---|---|---|---|\n"
        #expect(SpecKit.analysisFoundCritical(table + "| C1 | Constitution | CRITICAL | plan.md | Skips tests | Add tests |"))
        #expect(!SpecKit.analysisFoundCritical(table + "| A1 | Ambiguity | HIGH | spec.md | Vague | Clarify |\n\nCritical Issues Count: 0"))
        #expect(SpecKitCommand.analyze.planningStation == "tasks" && SpecKitCommand.constitution.planningStation == "specify")
    }

    @Test func consentIgnoresArtifactsAndMachineLocalStateOnly() {
        var files = project()
        let base = SpecKit.consentFingerprint(files)
        files[".specify/feature.json"] = Data(#"{"feature_directory":"specs/001-x"}"#.utf8)
        files[".specify/memory/constitution.md"] = Data("principles".utf8)
        files["specs/001-x/spec.md"] = Data("spec".utf8)
        #expect(SpecKit.consentFingerprint(files) == base)
        files[".specify/scripts/bash/common.sh"] = Data("curl evil\n".utf8)
        #expect(SpecKit.consentFingerprint(files) != base)
        files[".specify/scripts/bash/common.sh"] = Data("echo\n".utf8)
        files[".shepherd/prompts/speckit.plan.md"] = Data("override".utf8)
        #expect(SpecKit.consentFingerprint(files) != base)
    }

    @Test func tasksAndSpecParseStockTemplateShapes() {
        let tasks = """
        # Tasks: Login
        ## Phase 1: Setup (Shared Infrastructure)
        - [X] T001 Create project structure per implementation plan
        - [ ] T002 [P] Configure linting and formatting tools
        ## Phase 3: User Story 1 - Sign in (Priority: P1) 🎯 MVP
        - [x] T010 [P] [US1] Contract test for /login in tests/contract/test_login.py
        - [ ] Create model without id
        ## Notes
        - [ ] not a task
        """
        let phases = SpecKit.parseTasks(tasks)
        #expect(phases.map(\.title) == ["Phase 1: Setup (Shared Infrastructure)", "Phase 3: User Story 1 - Sign in (Priority: P1) 🎯 MVP"])
        #expect(phases[0].completed == 1 && phases[0].tasks[1].parallel)
        #expect(phases[1].tasks == [SpecKitTask(id: "T010", done: true, parallel: true, story: "US1", text: "Contract test for /login in tests/contract/test_login.py")])
        let spec = SpecKit.parseSpec("""
        # Feature Specification: Login
        ### User Story 1 - Sign in (Priority: P1)
        - **FR-001**: System MUST allow users to sign in
        - **FR-006**: System MUST authenticate users via [NEEDS CLARIFICATION: auth method not specified]
        - **SC-001**: Users sign in in under 2 minutes
        """)
        #expect(spec.title == "Feature Specification: Login" && spec.userStories.count == 1)
        #expect(spec.requirements.count == 2 && spec.successCriteria.count == 1 && spec.clarificationsNeeded == 1)
    }

    /// Swift reads "\r\n" as one Character, so a split on "\n" left a Windows-edited file one unparsed line.
    @Test func windowsLineEndingsParseLikeUnixOnes() {
        let crlf = { (text: String) in text.replacingOccurrences(of: "\n", with: "\r\n") }
        let tasks = "## Phase 1: Setup\n- [ ] T001 [P] a\n- [X] T002 b\n"
        #expect(SpecKit.parseTasks(crlf(tasks)) == SpecKit.parseTasks(tasks) && SpecKit.parseTasks(tasks).first?.tasks.count == 2)
        let spec = "# Login\n- **FR-001**: sign in\n- **FR-002**: [NEEDS CLARIFICATION: how]\n"
        #expect(SpecKit.parseSpec(crlf(spec)) == SpecKit.parseSpec(spec) && SpecKit.parseSpec(spec).title == "Login")
        #expect(SpecKit.uncheckedTasks(Data(crlf(tasks).utf8)) == SpecKit.uncheckedTasks(Data(crlf("## Phase 1: Setup\n- [ ] T001 [P] a\n- [ ] T002 b\n").utf8)))
        #expect(SpecKit.onlyChecksTasks(before: crlf("- [ ] T001 a\n"), after: crlf("- [X] T001 a\n")))
        #expect(SpecKit.analysisFoundCritical(crlf("| ID | Severity |\n| C1 | CRITICAL |\n")))
        var warnings: [String] = []
        let hooks = SpecKit.parseHooks(crlf("hooks:\n  after_tasks:\n    - extension: git\n      command: speckit.git.commit\n"), warnings: &warnings)
        #expect(hooks.count == 1 && warnings.isEmpty)
    }

    @Test func convergeUnchangedIsAmbiguousNotSuccess() {
        let before = Data("- [X] T001 a\n".utf8)
        #expect(SpecKit.convergeOutcome(before: before, after: before) == .unchanged)
        #expect(SpecKit.convergeOutcome(before: before, after: before + Data("\n## Phase 4: Convergence\n- [ ] T002 b\n".utf8)) == .tasksAppended)
        #expect(SpecKit.convergeOutcome(before: before, after: Data("- [ ] T001 a\n".utf8)) == .rewritten)
        #expect(SpecKit.convergeOutcome(before: nil, after: before) == .missing)
    }

    @Test func extraWritesAreEvidenceNotRejections() {
        let notes = SpecKit.advisories(command: .plan, featureDirectory: "specs/001-login",
                                       changedPaths: ["specs/001-login/plan.md", "specs/001-login/contracts/api.md", "AGENTS.md"])
        #expect(notes.count == 1 && notes[0].contains("AGENTS.md"))
        #expect(SpecKit.advisories(command: .analyze, featureDirectory: "specs/001-login", changedPaths: []).isEmpty)
        #expect(SpecKit.advisories(command: .implement, featureDirectory: "specs/001-login", changedPaths: ["src/a.swift"],
                                   tasksBefore: "- [ ] T001 a\n", tasksAfter: "- [X] T001 a\n").isEmpty)
        #expect(SpecKit.advisories(command: .implement, featureDirectory: "specs/001-login", changedPaths: [],
                                   tasksBefore: "- [ ] T001 a\n", tasksAfter: "- [X] T001 b\n").count == 1)
    }

    @Test func projectionIsDeterministicValidMapAndKeepsOwnerChecks() throws {
        let mission = MissionID(), lane = SpaceID()
        let check = MissionStation(kind: .check, laneID: lane, title: "Tests", goal: "swift test", command: "swift test")
        let phases = SpecKit.parseTasks("## Phase 1: Setup\n- [ ] T001 a\n## Phase 2: Core\n- [X] T002 b\n")
        let first = SpecKit.projection(mission: mission, lane: lane, artifacts: [.specify: true, .plan: true, .tasks: true],
                                       spec: nil, phases: phases, keeping: [check])
        let again = SpecKit.projection(mission: mission, lane: lane, artifacts: [.specify: true, .plan: true, .tasks: true],
                                       spec: nil, phases: phases, keeping: [check])
        #expect(first.stations == again.stations && first.dependencies == again.dependencies)
        #expect(first.stations.map(\.kind) == [.research, .research, .research, .worker, .worker, .check, .validator])
        let draft = MissionDraft(title: "Login", goal: "Sign in", requirements: ["FR-001"],
                                 plan: MissionPlan(lanes: [.init(spaceID: lane, name: "app")], stations: first.stations, dependencies: first.dependencies))
        try draft.validateForApproval()
        try Mission(draft: draft).validate()
    }

    @Test func oneAgentPerTaskBatchesParallelRunsWithinPhasesAndSendsTheFirstTaskAlone() {
        let phases = SpecKit.parseTasks("""
        ## Phase 1: Setup
        - [X] T001 Create structure
        - [ ] T002 [P] Lint config
        - [ ] T003 [P] Format config
        - [ ] T004 Wire the CLI
        - [ ] T005 [P] [US1] Model in src/a.swift
        - [ ] T006 [P] [US1] Model in src/b.swift
        ## Phase 2: Polish
        - [ ] T007 [P] Docs
        - [ ] T008 [P] Tests
        """)
        let batches = SpecKit.implementBatches(phases).map { $0.map { "\($0.phase):\($0.task.id)" } }
        // T002 is the round's first unchecked task, so it goes alone (it alone runs stock setup checks).
        #expect(batches == [["0:T002"], ["0:T003"], ["0:T004"], ["0:T005", "0:T006"], ["1:T007", "1:T008"]])
        #expect(SpecKit.implementBatches(SpecKit.parseTasks("## A\n- [X] T1 a\n")).isEmpty)
    }

    @Test func aTaskIsDoneOnlyByItsOwnDoneLineAndMarkingTouchesOnlyItsCheckbox() {
        #expect(SpecKit.taskReported("Wrote src/a.swift.\n**Done: T005**", task: "T005"))
        #expect(SpecKit.taskReported("`Done: T005`", task: "T005"))
        #expect(!SpecKit.taskReported("Done: T006", task: "T005"))
        #expect(!SpecKit.taskReported("I'll get to it. Done: T005 soon", task: "T005"))
        #expect(!SpecKit.taskReported("Done: T005\nBlocked: T005 the API is missing", task: "T005"))
        let tasks = "## P\r\n- [ ] T005 [P] a\r\n- [ ] T0050 b\r\n  - [ ] T006 c\r\n"
        #expect(SpecKit.markingDone(tasks, task: "T005") == "## P\r\n- [X] T005 [P] a\r\n- [ ] T0050 b\r\n  - [ ] T006 c\r\n")
        #expect(SpecKit.markingDone(tasks, task: "T006") == "## P\r\n- [ ] T005 [P] a\r\n- [ ] T0050 b\r\n  - [X] T006 c\r\n")
        #expect(SpecKit.markingDone("- [X] T005 a\n", task: "T005") == nil)
        #expect(SpecKit.markingDone(tasks, task: "T.*") == nil, "a task id is never a pattern")
        let scope = SpecKit.taskScope(SpecKitTask(id: "T005", done: false, parallel: true, story: nil, text: "Model in src/a.swift"), first: false)
        #expect(!scope.contains("\n") && scope.contains("Done: T005") && scope.contains("Skip the project setup checks"))
        let hook = { (event: String, optional: Bool) in SpecKitHook(event: event, extensionID: "git", command: "speckit.git.commit", optional: optional, enabled: true, condition: nil) }
        #expect(SpecKit.hasMandatoryImplementHooks([hook("after_implement", false)]))
        #expect(!SpecKit.hasMandatoryImplementHooks([hook("after_implement", true), hook("before_specify", false)]))
    }

    /// Trimming to 128 stations once dropped later repositories' checks and Converge, which execution and publication read.
    @Test func fittingManyRepositoriesKeepsEveryCheckConvergeAndImplementReceipt() throws {
        let mission = MissionID(), lanes = (0..<12).map { _ in SpaceID() }
        let tasks = (0..<10).map { "## Phase \($0)\n- [ ] T\($0) work\n" }.joined()
        var stations: [MissionStation] = [], wires: [MissionDependency] = []
        for lane in lanes {
            let check = MissionStation(kind: .check, laneID: lane, title: "Tests", goal: "swift test", command: "swift test")
            let projected = SpecKit.projection(mission: mission, lane: lane, artifacts: [.specify: true, .plan: true, .tasks: true],
                                               spec: nil, phases: SpecKit.parseTasks(tasks), keeping: [check])
            stations += projected.stations; wires += projected.dependencies
        }
        #expect(stations.count > 128)
        let fitted = try SpecKit.fitted(stations: stations, dependencies: wires, mission: mission, lanes: lanes)
        let kept = Set(fitted.stations.map(\.id))
        #expect(fitted.stations.count == 128)
        #expect(stations.filter { $0.kind != .worker }.allSatisfy { kept.contains($0.id) })
        #expect(lanes.allSatisfy { kept.contains(SpecKit.stationID(mission, $0, "phase-0")) })
        try MissionPlan(lanes: lanes.map { .init(spaceID: $0, name: "repo") }, stations: fitted.stations, dependencies: fitted.dependencies).validate()
        #expect(throws: MissionError.self) { try SpecKit.fitted(stations: stations, dependencies: wires, mission: mission, lanes: lanes, limit: 40) }
    }

    @Test func onlyAConsentedRunningSpecKitAttemptGetsStockPromptsAtLaunch() throws {
        let lane = SpaceID(), agent = AgentID(), path = "/w/app-mission-1"
        var run = MissionRun(model: "m", phase: .planning)
        run.checkouts = [MissionCheckout(spaceID: lane, repo: "/w/app", path: path, branch: "mission/1", base: "main", head: "abc")]
        var attempt = MissionAttempt(agentID: agent)
        attempt.command = .specify
        run.attempts = [attempt]
        run.specKit = MissionSpecKitRun(lanes: [.init(spaceID: lane, featureDirectory: "specs/001-login")])
        var state = ShepherdState()
        state.missions = [Mission(draft: MissionDraft(title: "t", goal: "g"), run: run)]
        #expect(state.specKitLaunch(for: agent, cwd: path) == nil, "no consent, no explicit templates")
        state.missions[0].run?.specKit?.lanes[0].consentFingerprint = "f"
        #expect(state.specKitLaunch(for: agent, cwd: path) == MissionSpecKitLaunch(promptDirectory: path + "/.pi/prompts", featureDirectory: "specs/001-login"))
        #expect(state.specKitLaunch(for: agent, cwd: "/w/app") == nil, "never the primary checkout")
        #expect(state.specKitLaunch(for: AgentID(), cwd: path) == nil)
        state.missions[0].run?.attempts[0].command = nil
        #expect(state.specKitLaunch(for: agent, cwd: path) == nil, "legacy map attempts launch as before")
    }

    @Test func newRecordsDecodeFromOldJSONAndRejectUnsafePaths() throws {
        var run = MissionRun(model: "m")
        let old = try JSONEncoder().encode(run)
        #expect(try JSONDecoder().decode(MissionRun.self, from: old).specKit == nil)
        run.specKit = MissionSpecKitRun(lanes: [.init(spaceID: SpaceID(), featureDirectory: "specs/001-login")])
        try run.validate()
        #expect(try JSONDecoder().decode(MissionRun.self, from: JSONEncoder().encode(run)) == run)
        run.specKit = MissionSpecKitRun(lanes: [.init(spaceID: SpaceID(), featureDirectory: "../outside")])
        #expect(throws: MissionError.self) { try run.validate() }
    }
}

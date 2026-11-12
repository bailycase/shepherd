import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// A host's hooks as the phone reads them: one catalog in memory, every request recorded, and a
/// switch that can be refused.
private final class FakeHooksHost: SettingsClient, HooksClient, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: HookCatalogSnapshot
    private var log: [RemoteHooksRequest] = []
    var refuses = false

    init(_ snapshot: HookCatalogSnapshot) { self.snapshot = snapshot }
    var requests: [RemoteHooksRequest] { lock.withLock { log } }

    func hooks(_ request: RemoteHooksRequest) async throws -> RemoteHooksResult {
        try lock.withLock {
            log.append(request)
            if refuses, request.changesHooks { throw RemoteHostClientError.rejected(code: "hook_changed", message: "Reload and try again.") }
            switch request {
            case .setOn(let hash, let on):
                snapshot.settings.off.removeAll { $0 == hash }
                if !on { snapshot.settings.off.append(hash) }
                for i in snapshot.entries.indices { snapshot.entries[i].on = snapshot.settings.isOn(snapshot.entries[i].hash) }
            case .test: return .tested(HookTestResult(exit: 2, stdout: "", stderr: "no", milliseconds: 41, outcome: .blocked(reason: "no")))
            default: break
            }
            return .hooks(snapshot)
        }
    }

    func skills(_ request: RemoteSkillsRequest) async throws -> RemoteSkillsResult { throw CancellationError() }
    func hostSettings(_ request: RemoteHostSettingsRequest) async throws -> HostSettings { HostSettings() }
    func instructions(_ request: RemoteInstructionsRequest) async throws -> InstructionsSnapshot { InstructionsSnapshot(directory: "~/i") }
    func suggestions(_ request: RemoteSuggestionsRequest) async throws -> SuggestionsSnapshot { SuggestionsSnapshot() }
}

@MainActor
@Suite("Client hooks")
struct ClientHooksTests {
    static let home = "/Users/sam"
    static let space = "/Users/sam/code/payments"

    static func entry(_ file: String, scope: HookScope, event: String, matcher: String = "", command: String, editable: Bool = true) -> HookEntry {
        let handler = HookHandler.command(command, timeout: 10)
        return HookEntry(slot: "\(file)#\(event)/0/0", scope: scope, file: file, format: .shepherd, event: event, matcher: matcher,
                         groupIndex: 0, handlerIndex: 0, handler: handler, hash: "h-\(command)", canonical: handler.raw.canonical,
                         editable: editable, on: true)
    }

    static var snapshot: HookCatalogSnapshot {
        let mac = home + "/.shepherd/hooks.json", spaceFile = space + "/.shepherd/hooks.json"
        return HookCatalogSnapshot(
            sources: [
                HookSource(path: mac, scope: .mac, format: .shepherd, isTOML: false, state: .loaded(count: 1)),
                HookSource(path: home + "/.codex/config.toml", scope: .mac, format: .codex, isTOML: true, state: .loaded(count: 1)),
                HookSource(path: spaceFile, scope: .space(root: space), format: .shepherd, isTOML: false, state: .notFound),
                HookSource(path: space + "/.claude/settings.json", scope: .space(root: space), format: .claude, isTOML: false, state: .readerOff),
            ],
            entries: [
                entry(mac, scope: .mac, event: "Stop", command: "npm test"),
                entry(mac, scope: .mac, event: "PreToolUse", matcher: "Edit|Write", command: "./no-env.sh"),
                entry(home + "/.codex/config.toml", scope: .mac, event: "SessionStart", command: "notes", editable: false),
            ],
            settings: HookSettings(), home: home)
    }

    static func host(_ client: (any SettingsClient)?, capable: Bool = true) -> SettingsHost {
        SettingsHost(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Studio", client: client,
                     capabilities: capable ? [RemoteProtocol.hooksCapability] : [])
    }

    @Test func aHostsHooksGroupByEventInSettingsOrderWithTheirSources() async {
        let fake = FakeHooksHost(Self.snapshot)
        let model = ClientHooks()
        model.use([Self.host(fake)])
        #expect(model.state == .loading)
        await model.refresh()
        let page = try! #require(model.state.page)
        #expect(page.groups.map(\.event) == ["SessionStart", "PreToolUse", "Stop"])
        #expect(page.groups[1].rows[0].source == "This Mac · ~/.shepherd/hooks.json")
        #expect(page.groups[2].rows[0].matcher == "always" && page.groups[2].rows[0].matcherIsAny)
        #expect(page.hookCount == 3 && page.fileCount == 3)
        #expect(page.sections.map(\.name) == ["This Mac", "payments"])
        #expect(page.sections[1].files.map(\.state) == ["Not read: switched off above"])
    }

    @Test func offlineAndOlderHostsSayWhyAndTheFirstHostThatServesHooksIsTheOneRead() {
        let model = ClientHooks()
        #expect(model.state == .offline, "no host, no hooks")
        let offline = SettingsHost(id: UUID(), name: "Air", client: nil, capabilities: [])
        let old = Self.host(FakeHooksHost(Self.snapshot), capable: false)
        model.use([offline])
        #expect(model.state == .offline)
        model.use([offline, old])
        #expect(model.host?.name == "Air" && model.state == .offline)
        model.use([old])
        #expect(model.state == .unsupported)
        let capable = SettingsHost(id: UUID(), name: "build-01", client: FakeHooksHost(Self.snapshot), capabilities: [RemoteProtocol.hooksCapability])
        model.use([offline, old, capable])
        #expect(model.host?.name == "build-01" && model.state == .loading)
    }

    @Test func aDifferentHostStartsWithNothingOfTheLastOnesPage() async {
        let model = ClientHooks()
        let first = Self.host(FakeHooksHost(Self.snapshot))
        model.use([first])
        await model.refresh()
        #expect(model.state.page != nil)
        model.use([first])
        #expect(model.state.page != nil, "the same host keeps what it showed")
        model.use([SettingsHost(id: UUID(), name: "build-01", client: FakeHooksHost(Self.snapshot), capabilities: [RemoteProtocol.hooksCapability])])
        #expect(model.state == .loading)
    }

    @Test func aSwitchShowsAtOnceAndARefusalPutsTheHostsStateBack() async throws {
        let fake = FakeHooksHost(Self.snapshot)
        let model = ClientHooks()
        model.use([Self.host(fake)])
        await model.refresh()
        let row = try #require(model.state.page?.groups[2].rows.first)
        await model.setOn(row, false)
        #expect(model.state.page?.groups[2].rows.first?.on == false)
        #expect(fake.requests.last == .setOn(hash: "h-npm test", on: false))

        fake.refuses = true
        await model.setOn(row, true)
        #expect(model.problem == "Reload and try again.")
        #expect(model.state.page?.groups[2].rows.first?.on == false)
        #expect(fake.requests.last == .fetch)
    }

    @Test func theEditorSavesInPlaceWithTheGuardAndAddsToASpace() async throws {
        let fake = FakeHooksHost(Self.snapshot)
        let model = ClientHooks()
        model.use([Self.host(fake)])
        let entry = Self.snapshot.entries[1]
        let editor = ClientHookEditor(editing: entry, in: Self.snapshot)
        #expect(editor.title == "Edit hook" && !editor.readOnly)
        #expect(editor.matched == ["edit", "write"])
        #expect(editor.targets.map { editor.targetName($0) } == ["This Mac", "payments"])
        editor.handlers[0].statusMessage = "Checking the path"
        editor.addHandler()
        editor.handlers[1].command = "echo second"
        #expect(await editor.save(with: model))
        guard case .save(let drafts, let file, let ref, let kept) = fake.requests.last else { Issue.record("expected a save"); return }
        #expect(file == entry.file && ref == HookRef(entry) && kept == 0)
        #expect(drafts.map(\.handler.statusMessage) == ["Checking the path", nil])
        #expect(drafts[0].handler.timeout == 10)

        let adding = ClientHookEditor(adding: Self.snapshot)
        adding.target = Self.space + "/.shepherd/hooks.json"
        #expect(await adding.save(with: model) == false)
        #expect(adding.problem == "Enter the command the hook runs.")
        adding.handlers[0].command = "npm run lint"
        #expect(await adding.save(with: model))
        guard case .save(_, let spaceFile, nil, nil) = fake.requests.last else { Issue.record("expected an add"); return }
        #expect(spaceFile == Self.space + "/.shepherd/hooks.json")
    }

    @Test func theJSONPaneRoundTripsAndSaysTheLineThatDoesntParse() throws {
        let editor = ClientHookEditor(editing: Self.snapshot.entries[1], in: Self.snapshot)
        editor.pane = .json
        #expect(editor.jsonText.contains("\"Edit|Write\""))
        #expect(editor.targetFile == "~/.shepherd/hooks.json")
        editor.jsonText = editor.jsonText.replacingOccurrences(of: "Edit|Write", with: "Bash")
        editor.pane = .form
        #expect(editor.matcher == "Bash" && editor.handlers[0].original)
        editor.pane = .json
        editor.jsonText = "{\n  \"hooks\": {"
        editor.pane = .form
        #expect(editor.pane == .json)
        #expect(editor.jsonError?.hasPrefix("Line ") == true, "\(editor.jsonError ?? "")")
    }

    @Test func codexTomlOpensReadOnlyAndATestRunsOnTheHost() async {
        let fake = FakeHooksHost(Self.snapshot)
        let model = ClientHooks()
        model.use([Self.host(fake)])
        let toml = ClientHookEditor(editing: Self.snapshot.entries[2], in: Self.snapshot)
        #expect(toml.readOnly && toml.title == "Hook")
        #expect(await toml.save(with: model) == false)
        #expect(fake.requests.isEmpty)

        let editor = ClientHookEditor(editing: Self.snapshot.entries[1], in: Self.snapshot)
        await editor.test(with: model)
        #expect(fake.requests.last == .test(command: "./no-env.sh", event: .preToolUse, matcher: "Edit|Write", timeout: 10, root: nil))
        let result = try! #require(editor.testResult)
        #expect(editor.testMeta(result, host: "Studio") == "sample edit · exit 2 · 41 ms · on Studio")
        #expect(HookTestOutput(result)?.streams == [.init(label: "stderr", text: "no", note: nil)])
    }

    /// Output lists only the streams the hook printed, says a stream was cut, and is gone when both are empty.
    @Test func aTestsOutputLabelsEachPrintedStreamAndSaysWhenOneWasCut() {
        func output(_ out: String, _ err: String, outCut: Bool = false, errCut: Bool = false) -> [HookTestOutput.Stream]? {
            HookTestOutput(HookTestResult(exit: 0, stdout: out, stderr: err, milliseconds: 1, outcome: .allowed, stdoutCut: outCut, stderrCut: errCut))?.streams
        }
        #expect(output("", "") == nil)
        #expect(output("\n", "\n\n") == nil)
        #expect(output("ok\n\nmore\n\n", "") == [.init(label: "stdout", text: "ok\n\nmore", note: nil)])
        #expect(output("a", "b", errCut: true) == [.init(label: "stdout", text: "a", note: nil), .init(label: "stderr", text: "b", note: "cut at 64 KiB")])
        #expect(output("x", "", outCut: true)?.first?.note == "cut at 64 KiB")
    }
}

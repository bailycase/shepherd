import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestKit
@testable import ShepherdRemote

/// A host as the phone's Settings reads it: its settings, root instructions and suggestions kept
/// in memory, every request recorded.
final class FakeSettingsClient: SettingsClient, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: HostSettings
    private var files: InstructionsSnapshot
    private var suggestionsSnapshot: SuggestionsSnapshot
    private var log: [String] = []
    var refusesChanges = false
    var beforeInstructions: (@Sendable (RemoteInstructionsRequest) async throws -> Void)?
    var beforeHostSettings: (@Sendable () async -> Void)?
    var beforeSuggestions: (@Sendable () async -> Void)?
    /// Saved versions a restore can put back (their entries are in the files' history).
    var revisions: [InstructionRevision] = []

    init(settings: HostSettings = HostSettings(), files: InstructionsSnapshot = InstructionsSnapshot(directory: "~/i"),
         suggestions: SuggestionsSnapshot = SuggestionsSnapshot()) {
        self.settings = settings
        self.files = files
        self.suggestionsSnapshot = suggestions
    }

    var requests: [String] { lock.withLock { log } }
    var saved: InstructionsSnapshot { lock.withLock { files } }

    /// Settings' pages never ask for skills (ClientSkillsTests has a host that answers them).
    func skills(_ request: RemoteSkillsRequest) async throws -> RemoteSkillsResult {
        throw RemoteHostClientError.rejected(code: "unsupported", message: "No skills here.")
    }

    func hostSettings(_ request: RemoteHostSettingsRequest) async throws -> HostSettings {
        await beforeHostSettings?()
        return try lock.withLock {
            log.append("settings.\(request)")
            if case .change(let change) = request {
                if refusesChanges { throw RemoteHostClientError.rejected(code: "settings_failed", message: "The host said no.") }
                settings.apply(change)
            }
            return settings
        }
    }

    func instructions(_ request: RemoteInstructionsRequest) async throws -> InstructionsSnapshot {
        try await beforeInstructions?(request)
        return lock.withLock {
            switch request {
            case .fetch:
                log.append("instructions.fetch")
            case .save(let file, let content, let origin, let sync):
                log.append("instructions.save(\(file.fileName), sync: \(sync), origin: \(origin))")
                files[file] = content
            case .restore(let revisionID, _):
                log.append("instructions.restore")
                if let revision = revisions.first(where: { $0.id == revisionID }) { files[revision.file] = revision.content }
            }
            return files
        }
    }

    func suggestions(_ request: RemoteSuggestionsRequest) async throws -> SuggestionsSnapshot {
        await beforeSuggestions?()
        return lock.withLock {
            log.append("suggestions.\(String(describing: request).prefix { $0 != "(" })")
            switch request {
            case .fetch:
                break
            case .configure(let settings):
                suggestionsSnapshot.settings = settings
                if !settings.enabled { suggestionsSnapshot.waiting = [] }
            case .add(let id, let line, let file):
                if let index = suggestionsSnapshot.waiting.firstIndex(where: { $0.id == id }) {
                    let suggestion = suggestionsSnapshot.waiting.remove(at: index)
                    suggestionsSnapshot.added.insert(AddedSuggestion(id: id, line: line ?? suggestion.line, file: file ?? suggestion.file,
                                                                     sourceName: suggestion.source.name, addedAt: 0), at: 0)
                }
            case .addAll:
                for suggestion in suggestionsSnapshot.waiting.reversed() {
                    suggestionsSnapshot.added.insert(AddedSuggestion(id: suggestion.id, line: suggestion.line, file: suggestion.file,
                                                                     sourceName: suggestion.source.name, addedAt: 0), at: 0)
                }
                suggestionsSnapshot.waiting = []
            case .dismiss(let id):
                suggestionsSnapshot.waiting.removeAll { $0.id == id }
            case .undo(let id):
                suggestionsSnapshot.added.removeAll { $0.id == id }
            }
            return suggestionsSnapshot
        }
    }
}

/// A host's inventory and configuration in memory: one server, a sign-in that finishes on its
/// first poll.
final class FakeConfigClient: SettingsClient, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var server = HostMCPServer(name: "github", kind: .remote, endpoint: "https://x", status: .connected)
    private var signedIn = false
    var refuses = false
    var requests: [String] { lock.withLock { log } }

    func skills(_ request: RemoteSkillsRequest) async throws -> RemoteSkillsResult { throw RemoteHostClientError.disconnected }
    func hostSettings(_ request: RemoteHostSettingsRequest) async throws -> HostSettings { HostSettings() }
    func instructions(_ request: RemoteInstructionsRequest) async throws -> InstructionsSnapshot { InstructionsSnapshot(directory: "~") }
    func suggestions(_ request: RemoteSuggestionsRequest) async throws -> SuggestionsSnapshot { SuggestionsSnapshot() }
    func listModels() async throws -> ModelListing {
        ModelListing(models: ["anthropic/claude-opus", "openai/gpt-5"], defaultModel: nil)
    }

    func hostInventory(_ request: RemoteHostInventoryRequest) async throws -> RemoteHostInventoryResult {
        lock.withLock {
            log.append("inventory.\(request)")
            switch request {
            case .providers: return .providers([HostProviderStatus(id: "anthropic", name: "Anthropic", badge: "Subscription",
                                                                   auth: signedIn ? .signedIn : .notSignedIn)])
            default: return .mcp(HostMCPInventory(servers: [server], configPath: "~/mcp.json"))
            }
        }
    }

    func hostConfig(_ request: RemoteHostConfigRequest) async throws -> RemoteHostConfigResult {
        try lock.withLock {
            log.append("config.\(String(describing: request).prefix { $0 != "(" })")
            if refuses { throw RemoteHostClientError.rejected(code: "config_failed", message: "The host said no.") }
            let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
            switch request {
            case .mcpSetEnabled(_, let on):
                server.enabled = on
                return .mcp(HostMCPInventory(servers: [server], configPath: "~/mcp.json"))
            case .providerSignIn:
                return .signIn(HostSignInProgress(id: id, phase: .waiting, name: "Anthropic", authorizationURL: "https://claude.ai", wantsCode: true))
            case .signIn:
                signedIn = true
                return .signIn(HostSignInProgress(id: id, phase: .done, name: "Anthropic"))
            default:
                return .providers([])
            }
        }
    }
}

/// Deterministic request boundary: no timers, polling, sockets or UI.
actor SettingsRequestGate {
    private var held = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { continuation in
            waiting = continuation
            held = true
            entered?.resume()
            entered = nil
        }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { entered = $0 }
    }

    func release() {
        waiting?.resume()
        waiting = nil
    }
}

@Suite("Client settings")
@MainActor
struct ClientSettingsTests {
    static let all: Set<String> = [RemoteProtocol.hostSettingsCapability, RemoteProtocol.instructionsCapability,
                                   RemoteProtocol.suggestionsCapability]

    static func host(_ name: String, _ client: FakeSettingsClient?, capabilities: Set<String> = all, id: UUID = UUID()) -> SettingsHost {
        SettingsHost(id: id, name: name, client: client, capabilities: capabilities)
    }

    // MARK: Host settings

    @Test func goalsCanBeToggledOnlyOnHostsThatAdvertiseTheExperiment() async {
        let client = FakeSettingsClient()
        let model = ClientHostSettings()
        let old = Self.host("old", client)
        await model.refresh(old)
        #expect(model.post(.goalsEnabled(true), on: old) == nil)
        #expect(model.settings(of: old)?.goalsEnabled == false)
        #expect(client.requests == ["settings.fetch"])
        let live = Self.host("new", client, capabilities: Self.all.union([RemoteProtocol.goalExperimentCapability]))
        await model.refresh(live)
        await model.change(.goalsEnabled(true), on: live)
        #expect(model.settings(of: live)?.goalsEnabled == true)
        await model.change(.goalsEnabled(false), on: live)
        #expect(model.settings(of: live)?.goalsEnabled == false)
        #expect(client.requests.count == 4, "two fetches and only the capable host's two changes")
    }

    @Test func projectsCanBeToggledOnlyOnHostsThatAdvertiseTheExperiment() async {
        let client = FakeSettingsClient()
        let model = ClientHostSettings()
        let old = Self.host("old", client)
        await model.refresh(old)
        #expect(model.post(.projectsEnabled(true), on: old) == nil)
        #expect(model.settings(of: old)?.projectsEnabled == false)
        #expect(client.requests == ["settings.fetch"])
        let live = Self.host("new", client, capabilities: Self.all.union([RemoteProtocol.projectsExperimentCapability]))
        await model.refresh(live)
        await model.change(.projectsEnabled(true), on: live)
        #expect(model.settings(of: live)?.projectsEnabled == true)
        await model.change(.projectsEnabled(false), on: live)
        #expect(model.settings(of: live)?.projectsEnabled == false)
        #expect(client.requests.count == 4)
    }

    /// Every change that needs a newer host waits for that host: the Design tool and Missions
    /// switches, and hostSettings.v2's rows. Missions stays on in the client under a live mission.
    @Test func newerSwitchesReachOnlyHostsThatAdvertiseThem() async {
        let client = FakeSettingsClient(settings: HostSettings(missionsEnabled: true, missionsActive: true))
        let model = ClientHostSettings()
        let old = Self.host("old", client)
        await model.refresh(old)
        for change: HostSettingChange in [.designToolEnabled(true), .missionsEnabled(false), .skillsInSlashMenu(false),
                                          .subagentDefaults(HostSettings.SubagentDefaults(concurrency: 2)), .closeOnMerge(true)] {
            #expect(model.post(change, on: old) == nil, "\(change)")
        }
        #expect(client.requests == ["settings.fetch"])
        let live = Self.host("new", client, capabilities: Self.all.union([RemoteProtocol.designToolExperimentCapability,
                                                                          RemoteProtocol.missionsExperimentCapability,
                                                                          RemoteProtocol.hostSettingsV2Capability,
                                                                          RemoteProtocol.hostSettingsCloseOnMergeCapability]))
        await model.refresh(live)
        await model.change(.designToolEnabled(true), on: live)
        #expect(model.settings(of: live)?.designToolEnabled == true)
        await model.change(.missionsEnabled(false), on: live)
        #expect(model.settings(of: live)?.missionsEnabled == true, "a live mission keeps Missions on")
        await model.change(.slashCommand(name: "review", on: false), on: live)
        #expect(model.settings(of: live)?.hiddenSlashCommands == ["review"])
        await model.change(.closeOnMerge(true), on: live)
        #expect(model.settings(of: live)?.closeOnMerge == true)
    }

    @Test func aHostsConfigurationIsReadOnlyUntilItAdvertisesHostConfig() async {
        let client = FakeConfigClient()
        let model = ClientHostConfig()
        model.pollInterval = .zero
        let old = SettingsHost(id: UUID(), name: "old", client: client, capabilities: [RemoteProtocol.hostInventoryCapability])
        await model.refresh(.mcp, on: old)
        #expect(model.mcp[old.id]?.servers.map(\.name) == ["github"])
        #expect(!model.canEdit(old))
        #expect(await model.perform(.mcpRemove(name: "github"), on: old) == nil)
        #expect(client.requests == ["inventory.mcp"])

        let live = SettingsHost(id: UUID(), name: "new", client: client,
                                capabilities: [RemoteProtocol.hostInventoryCapability, RemoteProtocol.hostConfigCapability])
        await model.perform(.mcpSetEnabled(name: "github", on: false), on: live)
        #expect(model.mcp[live.id]?.servers.first?.enabled == false)
        client.refuses = true
        await model.perform(.providerSignOut(provider: "openai"), on: live)
        #expect(model.problems[live.id] == "The host said no.")
        client.refuses = false
        await model.perform(.providerSignIn(provider: "anthropic"), on: live)
        #expect(model.signIns[live.id]?.phase == .waiting)
        await model.follow(signInOn: live, page: .providers)
        #expect(model.signIns[live.id]?.phase == .done)
        #expect(model.providers[live.id]?.first?.auth == .signedIn, "a finished sign-in reads the page again")
    }

    /// A host's model menus offer its own catalog, keeping a current model it no longer lists.
    @Test func aHostsModelMenusOfferItsOwnCatalog() async {
        let model = ClientHostSettings()
        let host = SettingsHost(id: UUID(), name: "studio", client: FakeConfigClient(), capabilities: Self.all)
        #expect(model.models(of: host).isEmpty)
        await model.loadModels(host)
        #expect(model.models(of: host) == ["anthropic/claude-opus", "openai/gpt-5"])
        #expect(model.models(of: host, current: "local/llama").first == "local/llama")
        #expect(model.models(of: host, current: "openai/gpt-5").count == 2)
        model.forget(host: host.id)
        #expect(model.models(of: host).isEmpty)
    }

    @Test func lateSettingsAndSuggestionReadsCannotRepopulateAForgottenHost() async {
        let client = FakeSettingsClient()
        let host = Self.host("gone", client)
        let settings = ClientHostSettings(), suggestions = ClientSuggestions()
        let settingsGate = SettingsRequestGate(), suggestionsGate = SettingsRequestGate()
        client.beforeHostSettings = { await settingsGate.hold() }
        client.beforeSuggestions = { await suggestionsGate.hold() }
        let readingSettings = Task { await settings.refresh(host) }
        let readingSuggestions = Task { await suggestions.refresh([host]) }
        await settingsGate.waitUntilHeld()
        await suggestionsGate.waitUntilHeld()
        settings.forget(host: host.id)
        suggestions.forget(host: host.id)
        await settingsGate.release()
        await suggestionsGate.release()
        await readingSettings.value
        await readingSuggestions.value
        #expect(settings.state(of: host) == .offline)
        #expect(suggestions.hosts([host]).isEmpty)
        client.beforeHostSettings = nil
        client.beforeSuggestions = nil
        let count = client.requests.count
        await settings.refresh(host)
        await suggestions.refresh([host])
        #expect(client.requests.count == count)
    }

    @Test func aHostsSettingsSayWhetherTheyCanBeShown() async {
        let model = ClientHostSettings()
        let offline = Self.host("horizon", nil)
        let old = Self.host("studio", FakeSettingsClient(), capabilities: [])
        let live = Self.host("demo-mac", FakeSettingsClient(settings: HostSettings(piVersion: "0.87.1")))
        #expect(model.state(of: offline) == .offline)
        #expect(model.state(of: old) == .unsupported)
        #expect(model.state(of: live) == .loading)
        await model.refresh([offline, old, live])
        #expect(model.settings(of: live)?.piVersion == "0.87.1")
    }

    @Test func aChangeShowsAtOnceAndAHostThatRefusesPutsItsOwnBack() async {
        let client = FakeSettingsClient(settings: HostSettings(fetchBeforeCreating: true))
        let host = Self.host("demo-mac", client)
        let model = ClientHostSettings()
        await model.refresh(host)
        await model.change(.fetchBeforeCreating(false), on: host)
        #expect(model.settings(of: host)?.fetchBeforeCreating == false)
        #expect(model.problem == nil)

        client.refusesChanges = true
        await model.change(.fetchBeforeCreating(true), on: host)
        #expect(model.settings(of: host)?.fetchBeforeCreating == false)
        #expect(model.problem == "The host said no.")
    }

    @Test func aSwitchShowsAtOnceAndTheHostFollows() async {
        let client = FakeSettingsClient(settings: HostSettings(updatePiDaily: false))
        let host = Self.host("demo-mac", client)
        let model = ClientHostSettings()
        await model.refresh(host)
        let sent = model.post(.updatePiDaily(true), on: host)
        // Before the host answers.
        #expect(model.settings(of: host)?.updatePiDaily == true)
        await sent?.value
        #expect(client.requests.count == 2)
        #expect(model.settings(of: host)?.updatePiDaily == true)
    }

    // MARK: Instructions

    /// The files are the fleet's: the page edits the first host that answers, and the fleet carries a
    /// save to the other Macs. Nothing here writes to any other host.
    @Test func theFirstHostThatAnswersIsEditedAndOnlyItIsWritten() async throws {
        let first = FakeSettingsClient(files: InstructionsSnapshot(agents: "- a\n", directory: "~/i"))
        let second = FakeSettingsClient(files: InstructionsSnapshot(agents: "- old\n", appendSystem: "rule\n", directory: "~/i"))
        let hosts = [Self.host("demo-mac", first), Self.host("studio", second), Self.host("horizon", nil)]
        let model = ClientInstructions(origin: "iPhone")
        await model.refresh(hosts)
        #expect(model.edited(in: hosts)?.name == "demo-mac")
        #expect(model.text(.agents, in: hosts) == "- a\n")

        model.setText("- a\n- b\n", file: .agents, in: hosts)
        #expect(model.isEdited(.agents))
        await model.save(.agents, in: hosts)
        #expect(!model.isEdited(.agents))
        #expect(first.saved.agents == "- a\n- b\n")
        #expect(first.requests.last == "instructions.save(AGENTS.md, sync: false, origin: iPhone)")
        #expect(second.saved.agents == "- old\n" && !second.requests.contains { $0.hasPrefix("instructions.save") },
                "no fan-out and nothing owed: the hosts' sync does the rest")
        #expect(model.saved(.agents, in: hosts) == "- a\n- b\n")
    }

    @Test func whenTheEditedHostGoesAwayTheNextOneIsEdited() async {
        let first = FakeSettingsClient(files: InstructionsSnapshot(agents: "from first", directory: "~/i"))
        let second = FakeSettingsClient(files: InstructionsSnapshot(agents: "from second", directory: "~/i"))
        let model = ClientInstructions(origin: "iPad")
        let (firstID, secondID) = (UUID(), UUID())
        await model.refresh([Self.host("first", first, id: firstID), Self.host("second", second, id: secondID)])
        let offlineFirst = [Self.host("first", nil, id: firstID), Self.host("second", second, id: secondID)]
        #expect(model.edited(in: offlineFirst)?.name == "second")
        #expect(model.text(.agents, in: offlineFirst) == "from second")
    }

    @Test func withNoHostThereIsNothingToEdit() async {
        let model = ClientInstructions(origin: "iPhone")
        await model.refresh([])
        #expect(model.edited(in: []) == nil)
        model.setText("x", file: .agents, in: [])
        #expect(!model.isEdited(.agents), "no host, no draft: nothing could say what a save would replace")
        let old = Self.host("old", FakeSettingsClient(), capabilities: [])
        await model.refresh([old])
        #expect(model.files(of: old) == .unsupported && model.edited(in: [old]) == nil)
    }

    @Test(arguments: [false, true], ["newer edit", "saved"])
    func instructionWritesKeepEditsMadeWhileAwaitingTheirReply(restore: Bool, newer: String) async {
        let old = InstructionRevision(file: .agents, savedAt: 1, summary: "old", content: "restored")
        let client = FakeSettingsClient(files: InstructionsSnapshot(agents: "saved", directory: "~/i"))
        client.revisions = [old]
        let hosts = [Self.host("host", client)]
        let model = ClientInstructions(origin: "iPhone")
        await model.refresh(hosts)
        model.setText("submitted", file: .agents, in: hosts)
        let gate = SettingsRequestGate()
        client.beforeInstructions = { request in
            if case .fetch = request { return }
            await gate.hold()
        }
        let writing = Task {
            if restore { await model.restore(old.entry, in: hosts) }
            else { await model.save(.agents, in: hosts) }
        }
        await gate.waitUntilHeld()
        model.setText(newer, file: .agents, in: hosts)
        await gate.release()
        await writing.value
        #expect(client.saved.agents == (restore ? "restored" : "submitted"))
        #expect(model.text(.agents, in: hosts) == newer)
        #expect(model.isEdited(.agents))
    }

    @Test func forgottenInstructionRepliesCannotRestoreFilesOrDrafts() async {
        let client = FakeSettingsClient(files: InstructionsSnapshot(agents: "old", directory: "~/i"))
        let host = Self.host("gone", client)
        let model = ClientInstructions(origin: "iPad")
        await model.refresh([host])
        model.setText("submitted", file: .agents, in: [host])
        let gate = SettingsRequestGate()
        client.beforeInstructions = { _ in await gate.hold() }
        let save = Task { await model.save(.agents, in: [host]) }
        await gate.waitUntilHeld()
        model.forget(host: host.id)
        await gate.release()
        await save.value
        #expect(model.files(of: host) == .offline)
        #expect(client.requests.filter { $0.hasPrefix("instructions.save") }.count == 1)
        #expect(model.isEdited(.agents), "the draft was never saved, so it stays")
        #expect(model.problem == nil)
        client.beforeInstructions = nil
        let count = client.requests.count
        await model.refresh([host])
        #expect(client.requests.count == count)
    }

    @Test func restoringAVersionPutsItBackOnTheEditedHost() async {
        let old = InstructionRevision(file: .agents, savedAt: 100, summary: "Added “- old”", content: "- old\n")
        let first = FakeSettingsClient(files: InstructionsSnapshot(agents: "- new\n", directory: "~/i", history: [old.entry]))
        first.revisions = [old]
        let second = FakeSettingsClient(files: InstructionsSnapshot(agents: "- new\n", directory: "~/i"))
        let hosts = [Self.host("demo-mac", first), Self.host("studio", second)]
        let model = ClientInstructions(origin: "iPad")
        await model.refresh(hosts)
        #expect(model.history(.agents, in: hosts).map(\.id) == [old.id])
        #expect(model.history(.appendSystem, in: hosts).isEmpty)
        model.setText("- draft\n", file: .agents, in: hosts)
        await model.restore(old.entry, in: hosts)
        #expect(first.saved.agents == "- old\n")
        #expect(second.saved.agents == "- new\n", "the other Macs take it from the fleet, not from this device")
        #expect(!model.isEdited(.agents))
        #expect(model.text(.agents, in: hosts) == "- old\n")
    }

    // MARK: Suggestions

    static func suggestion(_ line: String, at time: Double, file: InstructionFile = .agents) -> InstructionSuggestion {
        InstructionSuggestion(line: line, reason: "It failed twice.", file: file,
                              source: SuggestionSource(kind: .thread, name: "Ledger cleanup"), suggestedAt: time)
    }

    @Test func everyHostsLinesWaitTogetherNewestFirst() async {
        let on = SuggestedInstructionsSettings(enabled: true, since: 1)
        let first = FakeSettingsClient(suggestions: SuggestionsSnapshot(settings: on, waiting: [Self.suggestion("- a", at: 10)]))
        let second = FakeSettingsClient(suggestions: SuggestionsSnapshot(settings: on, waiting: [Self.suggestion("- b", at: 20)]))
        let hosts = [Self.host("demo-mac", first), Self.host("studio", second), Self.host("horizon", nil)]
        let model = ClientSuggestions()
        await model.refresh(hosts)
        #expect(model.isOn(hosts))
        #expect(model.waiting(hosts).map(\.suggestion.line) == ["- b", "- a"])
        #expect(model.waiting(hosts).map(\.hostName) == ["studio", "demo-mac"])

        let newest = try! #require(model.waiting(hosts).first)
        await model.add(newest, line: "- b, edited", in: hosts)
        #expect(second.requests.last == "suggestions.add")
        let added = try! await second.suggestions(.fetch).added
        #expect(added.map(\.line) == ["- b, edited"])
        #expect(added.map(\.id) == [newest.suggestion.id])
        #expect(try! await first.suggestions(.fetch).added.isEmpty)
        #expect(model.waiting(hosts).map(\.suggestion.line) == ["- a"])
        await model.addAll(hosts)
        #expect(model.waiting(hosts).isEmpty)
        // Only the host with lines waiting was asked.
        #expect(!second.requests.contains("suggestions.addAll"))
    }

    @Test func theExperimentChangesOnEveryHost() async {
        let first = FakeSettingsClient(suggestions: SuggestionsSnapshot())
        let second = FakeSettingsClient(suggestions: SuggestionsSnapshot())
        let hosts = [Self.host("demo-mac", first), Self.host("studio", second)]
        let model = ClientSuggestions()
        await model.refresh(hosts)
        #expect(!model.isOn(hosts))
        await model.configure(hosts) { $0.enabled = true }
        await model.configure(hosts) { $0.sources.remove(.automation) }
        #expect(model.isOn(hosts))
        #expect(model.settings(hosts)?.sources == [.thread])
        #expect(first.requests.filter { $0 == "suggestions.configure" }.count == 2)
        #expect(second.requests.filter { $0 == "suggestions.configure" }.count == 2)
    }

    @Test func theExperimentsSwitchShowsAtOnce() async {
        let on = SuggestedInstructionsSettings(enabled: true)
        let client = FakeSettingsClient(suggestions: SuggestionsSnapshot(settings: on, waiting: [Self.suggestion("- a", at: 10)]))
        let hosts = [Self.host("demo-mac", client)]
        let model = ClientSuggestions()
        await model.refresh(hosts)
        let sent = model.post(hosts) { $0.enabled = false }
        // Off drops what waits, before the host answers.
        #expect(!model.isOn(hosts))
        #expect(model.waiting(hosts).isEmpty)
        await sent.value
        #expect(client.requests.contains("suggestions.configure"))
        #expect(!model.isOn(hosts))
    }

    @Test func anEditedLineMustBeOneLine() async {
        let on = SuggestedInstructionsSettings(enabled: true)
        let client = FakeSettingsClient(suggestions: SuggestionsSnapshot(settings: on, waiting: [Self.suggestion("- a", at: 10)]))
        let hosts = [Self.host("demo-mac", client)]
        let model = ClientSuggestions()
        await model.refresh(hosts)
        let waiting = try! #require(model.waiting(hosts).first)
        await model.add(waiting, line: "- one\n- two", in: hosts)
        #expect(model.problem == "Suggest one line at a time.")
        #expect(!client.requests.contains("suggestions.add"))
    }
}

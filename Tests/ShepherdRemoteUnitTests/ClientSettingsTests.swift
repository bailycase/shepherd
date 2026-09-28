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
        let live = Self.host("build-01", FakeSettingsClient(settings: HostSettings(piVersion: "0.87.1")))
        #expect(model.state(of: offline) == .offline)
        #expect(model.state(of: old) == .unsupported)
        #expect(model.state(of: live) == .loading)
        await model.refresh([offline, old, live])
        #expect(model.settings(of: live)?.piVersion == "0.87.1")
    }

    @Test func aChangeShowsAtOnceAndAHostThatRefusesPutsItsOwnBack() async {
        let client = FakeSettingsClient(settings: HostSettings(fetchBeforeCreating: true))
        let host = Self.host("build-01", client)
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
        let host = Self.host("build-01", client)
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

    @Test func sameOnEveryHostEditsTheFirstHostsFilesAndSavesThemEverywhere() async throws {
        let first = FakeSettingsClient(files: InstructionsSnapshot(agents: "- a\n", directory: "~/i"))
        let second = FakeSettingsClient(files: InstructionsSnapshot(agents: "- old\n", appendSystem: "rule\n", directory: "~/i"))
        let offlineID = UUID()
        var hosts = [Self.host("build-01", first), Self.host("studio", second), Self.host("horizon", nil, id: offlineID)]
        let model = ClientInstructions(defaults: ScratchDefaults(), origin: "iPhone")
        await model.refresh(hosts)
        #expect(model.reference(in: hosts)?.name == "build-01")
        #expect(model.text(.agents, in: hosts) == "- a\n")
        #expect(model.saveTitle(in: hosts) == "Save to 3 hosts")
        #expect(model.chip(for: hosts[1], file: .agents, in: hosts) == InstructionsChip(.attention, "differs · 2 lines"))

        model.setText("- a\n- b\n", file: .agents, in: hosts)
        #expect(model.isEdited(.agents, in: hosts))
        await model.save(.agents, in: hosts)
        #expect(!model.isEdited(.agents, in: hosts))
        #expect(first.saved.agents == "- a\n- b\n")
        #expect(first.requests.last == "instructions.save(AGENTS.md, sync: false, origin: iPhone)")
        // Both files: the other host matches the first one's now.
        #expect(second.saved.agents == "- a\n- b\n" && second.saved.appendSystem.isEmpty)
        #expect(model.chip(for: hosts[1], file: .agents, in: hosts).tone == .done)
        #expect(model.chip(for: hosts[2], file: .agents, in: hosts) == InstructionsChip(.quiet, "offline · will sync"))

        // Back online, the host takes what it is owed the next time the page reads it.
        let third = FakeSettingsClient(files: InstructionsSnapshot(agents: "- stale\n", directory: "~/i"))
        hosts[2] = Self.host("horizon", third, id: offlineID)
        await model.refresh(hosts)
        #expect(third.saved.agents == "- a\n- b\n")
        #expect(model.chip(for: hosts[2], file: .agents, in: hosts).tone == .done)
    }

    @Test func deferredInstructionsKeepTheirSavedContentWhenOnlyRecipientsReconnect() async {
        let defaults = ScratchDefaults()
        let a = UUID(), b = UUID(), c = UUID()
        let source = FakeSettingsClient(files: InstructionsSnapshot(agents: "old", appendSystem: "saved rules", directory: "~/i"))
        let hosts = [Self.host("A", nil, id: a), Self.host("B", source, id: b), Self.host("C", nil, id: c)]
        let model = ClientInstructions(defaults: defaults, origin: "iPad")
        await model.refresh(hosts)
        model.setText("saved", file: .agents, in: hosts)
        await model.save(.agents, in: hosts)

        let first = FakeSettingsClient(files: InstructionsSnapshot(agents: "stale A", appendSystem: "stale rules A", directory: "~/i"))
        let third = FakeSettingsClient(files: InstructionsSnapshot(agents: "stale C", appendSystem: "stale rules C", directory: "~/i"))
        let reconnected = [Self.host("A", first, id: a), Self.host("B", nil, id: b), Self.host("C", third, id: c)]
        let relaunched = ClientInstructions(defaults: defaults, origin: "iPad")
        await relaunched.refresh(reconnected)
        #expect(first.saved.agents == "saved" && first.saved.appendSystem == "saved rules")
        #expect(third.saved.agents == "saved" && third.saved.appendSystem == "saved rules")
        #expect(relaunched.text(.agents, in: reconnected) == "saved")
        let offline = Self.host("A", nil, id: a)
        #expect(relaunched.chip(for: offline, file: .agents, in: [offline]).word == "offline")
    }

    @Test func aPartialInstructionSyncStaysOwedUntilBothFilesAreAcknowledged() async {
        let defaults = ScratchDefaults()
        let source = FakeSettingsClient(files: InstructionsSnapshot(agents: "old", appendSystem: "rules", directory: "~/i"))
        let target = FakeSettingsClient()
        target.beforeInstructions = { request in
            if case .save(.appendSystem, _, _, _) = request { throw RemoteHostClientError.timeout }
        }
        let hosts = [Self.host("source", source), Self.host("target", target)]
        let model = ClientInstructions(defaults: defaults, origin: "iPhone")
        await model.refresh(hosts)
        model.setText("new", file: .agents, in: hosts)
        await model.save(.agents, in: hosts)
        #expect(target.saved.agents == "new" && target.saved.appendSystem.isEmpty)
        let offline = Self.host("target", nil, id: hosts[1].id)
        let relaunched = ClientInstructions(defaults: defaults, origin: "iPhone")
        #expect(relaunched.chip(for: offline, file: .agents, in: [offline]).word == "offline · will sync")
        target.beforeInstructions = nil
        await relaunched.refresh([hosts[1]])
        #expect(target.saved.appendSystem == "rules")
        #expect(relaunched.chip(for: offline, file: .agents, in: [offline]).word == "offline")
    }

    @Test func legacyInstructionMarkersNeverCopyAnOwedRecipientsStaleFiles() async {
        let defaults = ScratchDefaults()
        let a = UUID(), b = UUID()
        defaults.set([a.uuidString, b.uuidString], forKey: "shepherd.ios.instructions.pendingSync")
        let first = FakeSettingsClient(files: InstructionsSnapshot(agents: "A", directory: "~/i"))
        let second = FakeSettingsClient(files: InstructionsSnapshot(agents: "B", directory: "~/i"))
        let hosts = [Self.host("A", first, id: a), Self.host("B", second, id: b)]
        let model = ClientInstructions(defaults: defaults, origin: "iPhone")
        await model.refresh(hosts)
        #expect(first.requests == ["instructions.fetch"] && second.requests == ["instructions.fetch"])
        #expect(model.problem != nil)
        let offline = Self.host("A", nil, id: a)
        #expect(model.chip(for: offline, file: .agents, in: [offline]).word == "offline · will sync")
    }

    @Test(arguments: [false, true], ["newer edit", "saved"])
    func instructionWritesKeepEditsMadeWhileAwaitingTheirReply(restore: Bool, newer: String) async {
        let old = InstructionRevision(file: .agents, savedAt: 1, summary: "old", content: "restored")
        let client = FakeSettingsClient(files: InstructionsSnapshot(agents: "saved", directory: "~/i"))
        client.revisions = [old]
        let hosts = [Self.host("host", client)]
        let model = ClientInstructions(defaults: ScratchDefaults(), origin: "iPhone")
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
        #expect(model.isEdited(.agents, in: hosts))
    }

    @Test(arguments: [false, true], [false, true])
    func anInstructionWriteKeepsTheScopeChosenBeforeAwait(restore: Bool, sameEverywhere: Bool) async {
        let revision = InstructionRevision(file: .agents, savedAt: 1, summary: "old", content: "restored")
        let first = FakeSettingsClient(files: InstructionsSnapshot(agents: "A", directory: "~/i"))
        first.revisions = [revision]
        let second = FakeSettingsClient(files: InstructionsSnapshot(agents: "B", directory: "~/i"))
        let hosts = [Self.host("A", first), Self.host("B", second)]
        let model = ClientInstructions(defaults: ScratchDefaults(), origin: "iPad")
        await model.refresh(hosts)
        model.sameEverywhere = sameEverywhere
        model.setText("submitted", file: .agents, in: hosts)
        let gate = SettingsRequestGate()
        first.beforeInstructions = { _ in await gate.hold() }
        let writing = Task {
            if restore { await model.restore(revision.entry, in: hosts) }
            else { await model.save(.agents, in: hosts) }
        }
        await gate.waitUntilHeld()
        model.sameEverywhere.toggle()
        await gate.release()
        await writing.value
        #expect(first.saved.agents == (restore ? "restored" : "submitted"))
        #expect(second.saved.agents == (sameEverywhere ? first.saved.agents : "B"))
    }

    @Test func explicitInstructionSelectionsKeepEachWindowsDraftAndSaveTarget() async {
        let first = FakeSettingsClient(files: InstructionsSnapshot(agents: "A", directory: "~/i"))
        let second = FakeSettingsClient(files: InstructionsSnapshot(agents: "B", directory: "~/i"))
        let hosts = [Self.host("A", first), Self.host("B", second)]
        let model = ClientInstructions(defaults: ScratchDefaults(), origin: "iPad")
        await model.refresh(hosts)
        model.sameEverywhere = false
        model.setText("draft A", file: .agents, in: hosts, selectedHost: hosts[0].id)
        model.setText("draft B", file: .agents, in: hosts, selectedHost: hosts[1].id)
        await model.save(.agents, in: hosts, selectedHost: hosts[0].id)
        #expect(first.saved.agents == "draft A" && second.saved.agents == "B")
        #expect(model.text(.agents, in: hosts, selectedHost: hosts[1].id) == "draft B")
        #expect(model.isEdited(.agents, in: hosts, selectedHost: hosts[1].id))
    }

    @Test func forgettingInstructionsDuringASaveDropsOnlyThatRecipientsPendingCopy() async {
        let defaults = ScratchDefaults()
        let source = FakeSettingsClient()
        let gone = UUID(), kept = UUID()
        let hosts = [Self.host("source", source), Self.host("gone", nil, id: gone), Self.host("kept", nil, id: kept)]
        let model = ClientInstructions(defaults: defaults, origin: "iPad")
        await model.refresh(hosts)
        let gate = SettingsRequestGate()
        source.beforeInstructions = { request in if case .save = request { await gate.hold() } }
        model.setText("intended", file: .agents, in: hosts)
        let save = Task { await model.save(.agents, in: hosts) }
        await gate.waitUntilHeld()
        model.forget(host: gone)
        await gate.release()
        await save.value
        let restored = ClientInstructions(defaults: defaults, origin: "iPad")
        #expect(restored.chip(for: hosts[1], file: .agents, in: hosts).word == "offline")
        #expect(restored.chip(for: hosts[2], file: .agents, in: hosts).word == "offline · will sync")
        let target = FakeSettingsClient()
        await restored.refresh([Self.host("kept", target, id: kept)])
        #expect(target.saved.agents == "intended")
    }

    @Test func forgettingADeliveryStopsBeforeItsSecondInstructionFile() async {
        let defaults = ScratchDefaults()
        let source = FakeSettingsClient(files: InstructionsSnapshot(agents: "old", appendSystem: "rules", directory: "~/i"))
        let target = FakeSettingsClient()
        let hosts = [Self.host("source", source), Self.host("gone", target), Self.host("kept", nil)]
        let model = ClientInstructions(defaults: defaults, origin: "iPad")
        await model.refresh(hosts)
        let gate = SettingsRequestGate()
        target.beforeInstructions = { request in if case .save(.agents, _, _, _) = request { await gate.hold() } }
        model.setText("new", file: .agents, in: hosts)
        let saving = Task { await model.save(.agents, in: hosts) }
        await gate.waitUntilHeld()
        model.forget(host: hosts[1].id)
        await gate.release()
        await saving.value
        #expect(target.saved.agents == "new") // Already sent; Forget is not a rollback.
        #expect(target.saved.appendSystem.isEmpty) // Never send the unattempted suffix.
        let restored = ClientInstructions(defaults: defaults, origin: "iPad")
        let gone = Self.host("gone", nil, id: hosts[1].id)
        #expect(restored.chip(for: gone, file: .agents, in: [gone]).word == "offline")
        #expect(restored.chip(for: hosts[2], file: .agents, in: hosts).word == "offline · will sync")
    }

    @Test func explicitForgetPrunesOnlyItsPersistedInstructionObligation() async {
        let defaults = ScratchDefaults()
        let source = FakeSettingsClient()
        let hosts = [Self.host("source", source), Self.host("gone", nil), Self.host("kept", nil)]
        let model = ClientInstructions(defaults: defaults, origin: "iPad")
        await model.refresh(hosts)
        model.setText("intended", file: .agents, in: hosts)
        await model.save(.agents, in: hosts)
        let beforeOpeningSettings = ClientInstructions(defaults: defaults, origin: "iPad")
        beforeOpeningSettings.forget(host: hosts[1].id)
        let restored = ClientInstructions(defaults: defaults, origin: "iPad")
        #expect(restored.chip(for: hosts[1], file: .agents, in: hosts).word == "offline")
        #expect(restored.chip(for: hosts[2], file: .agents, in: hosts).word == "offline · will sync")
    }

    @Test func forgottenInstructionRepliesCannotRestoreFilesOrDrafts() async {
        let client = FakeSettingsClient(files: InstructionsSnapshot(agents: "old", directory: "~/i"))
        let host = Self.host("gone", client)
        let model = ClientInstructions(defaults: ScratchDefaults(), origin: "iPad")
        await model.refresh([host])
        model.sameEverywhere = false
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
        #expect(!model.isEdited(.agents, in: [host]))
        #expect(model.problem == nil)
        client.beforeInstructions = nil
        let count = client.requests.count
        await model.refresh([host])
        #expect(client.requests.count == count)
    }

    @Test func perHostEditsTheChosenHostAlone() async {
        let first = FakeSettingsClient(files: InstructionsSnapshot(agents: "- a\n", directory: "~/i"))
        let second = FakeSettingsClient(files: InstructionsSnapshot(agents: "- docker\n", directory: "~/i"))
        let hosts = [Self.host("build-01", first), Self.host("studio", second)]
        let model = ClientInstructions(defaults: ScratchDefaults(), origin: "iPad")
        await model.refresh(hosts)
        model.sameEverywhere = false
        model.chosenHost = hosts[1].id
        #expect(model.text(.agents, in: hosts) == "- docker\n")
        #expect(model.saveTitle(in: hosts) == "Save to studio")
        model.setText("- docker\n- compose\n", file: .agents, in: hosts)
        await model.save(.agents, in: hosts)
        #expect(second.saved.agents == "- docker\n- compose\n")
        #expect(first.saved.agents == "- a\n")
        // A draft belongs to its host.
        model.chosenHost = hosts[0].id
        #expect(!model.isEdited(.agents, in: hosts))
    }

    @Test func restoringAVersionPutsItBackOnEveryHost() async {
        let old = InstructionRevision(file: .agents, savedAt: 100, summary: "Added “- old”", content: "- old\n")
        let first = FakeSettingsClient(files: InstructionsSnapshot(agents: "- new\n", directory: "~/i", history: [old.entry]))
        first.revisions = [old]
        let second = FakeSettingsClient(files: InstructionsSnapshot(agents: "- new\n", directory: "~/i"))
        let hosts = [Self.host("build-01", first), Self.host("studio", second)]
        let model = ClientInstructions(defaults: ScratchDefaults(), origin: "iPad")
        await model.refresh(hosts)
        #expect(model.history(.agents, in: hosts).map(\.id) == [old.id])
        #expect(model.history(.appendSystem, in: hosts).isEmpty)
        model.setText("- draft\n", file: .agents, in: hosts)
        await model.restore(old.entry, in: hosts)
        #expect(first.saved.agents == "- old\n")
        #expect(second.saved.agents == "- old\n")
        #expect(!model.isEdited(.agents, in: hosts))
        #expect(model.text(.agents, in: hosts) == "- old\n")
    }

    @Test func syncNowGivesADifferingHostTheFirstHostsFiles() async {
        let first = FakeSettingsClient(files: InstructionsSnapshot(agents: "- a\n", directory: "~/i"))
        let second = FakeSettingsClient(files: InstructionsSnapshot(agents: "- mine\n", directory: "~/i"))
        let hosts = [Self.host("build-01", first), Self.host("studio", second), Self.host("horizon", nil)]
        let model = ClientInstructions(defaults: ScratchDefaults(), origin: "iPhone")
        await model.refresh(hosts)
        #expect(model.differing(in: hosts).map(\.name) == ["studio"])
        #expect(model.syncLine(in: hosts) == "build-01 synced · studio differs")
        await model.syncNow(in: hosts)
        #expect(second.saved.agents == "- a\n")
        #expect(second.requests.last == "instructions.save(AGENTS.md, sync: true, origin: iPhone)")
        #expect(model.differing(in: hosts).isEmpty)
        #expect(model.syncLine(in: hosts) == "build-01, studio synced")
        // Per host there is nothing to sync, and nothing to say.
        model.sameEverywhere = false
        #expect(model.syncLine(in: hosts) == nil)
        #expect(model.scope(in: hosts) == "build-01")
    }

    @Test func sameOnEveryHostIsRememberedPerDevice() {
        let defaults = ScratchDefaults()
        let model = ClientInstructions(defaults: defaults, origin: "iPhone")
        #expect(model.sameEverywhere)
        model.sameEverywhere = false
        #expect(!ClientInstructions(defaults: defaults, origin: "iPhone").sameEverywhere)
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
        let hosts = [Self.host("build-01", first), Self.host("studio", second), Self.host("horizon", nil)]
        let model = ClientSuggestions()
        await model.refresh(hosts)
        #expect(model.isOn(hosts))
        #expect(model.waiting(hosts).map(\.suggestion.line) == ["- b", "- a"])
        #expect(model.waiting(hosts).map(\.hostName) == ["studio", "build-01"])

        let newest = try! #require(model.waiting(hosts).first)
        await model.add(newest, line: "- b, edited", in: hosts)
        #expect(second.requests.last == "suggestions.add")
        #expect(model.waiting(hosts).map(\.suggestion.line) == ["- a"])
        await model.addAll(hosts)
        #expect(model.waiting(hosts).isEmpty)
        // Only the host with lines waiting was asked.
        #expect(!second.requests.contains("suggestions.addAll"))
    }

    @Test func theExperimentChangesOnEveryHost() async {
        let first = FakeSettingsClient(suggestions: SuggestionsSnapshot())
        let second = FakeSettingsClient(suggestions: SuggestionsSnapshot())
        let hosts = [Self.host("build-01", first), Self.host("studio", second)]
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
        let hosts = [Self.host("build-01", client)]
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
        let hosts = [Self.host("build-01", client)]
        let model = ClientSuggestions()
        await model.refresh(hosts)
        let waiting = try! #require(model.waiting(hosts).first)
        await model.add(waiting, line: "- one\n- two", in: hosts)
        #expect(model.problem == "Suggest one line at a time.")
        #expect(!client.requests.contains("suggestions.add"))
    }
}

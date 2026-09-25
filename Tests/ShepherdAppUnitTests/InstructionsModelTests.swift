import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestKit
@testable import ShepherdApp

/// Settings ▸ Instructions on the Mac: drafts, what Save says and writes, what a host that can't
/// take a save is owed, and what the page remembers between launches.
@Suite("Instructions model")
@MainActor
struct InstructionsModelTests {
    let store: InstructionsStore
    let defaults = Fixture.defaults()

    init() throws {
        store = InstructionsStore(directory: try makeScratchDirectory("instructions"))
    }

    func makeModel(_ hosts: RemoteHostStore? = nil) async -> InstructionsModel {
        let model = InstructionsModel(store: store, remoteHosts: hosts ?? RemoteHostStore(defaults: defaults), defaults: defaults)
        await model.refresh()
        return model
    }

    /// A host that is configured but never answers (nothing listens on port 1).
    func offlineHost(_ name: String = "horizon") -> (RemoteHostStore, UUID) {
        let hosts = RemoteHostStore(defaults: defaults)
        hosts.addHost(name: name, host: "127.0.0.1", port: 1, token: "x")
        return (hosts, hosts.connections[0].id)
    }

    @Test func anEditIsADraftUntilItMatchesTheSavedFileAgain() async throws {
        try store.save(.agents, content: "- a\n")
        let model = await makeModel()
        #expect(model.text(.agents, on: .local) == "- a\n")
        model.setText("- a\n- b\n", file: .agents, on: .local)
        #expect(model.isEdited(.agents, on: .local))
        #expect(model.canSave)
        // The other file has no draft of its own.
        #expect(!model.isEdited(.appendSystem, on: .local))
        model.setText("- a\n", file: .agents, on: .local)
        #expect(!model.isEdited(.agents, on: .local))
        #expect(!model.canSave)
    }

    @Test func saveWritesThisMacsFileAndRecordsIt() async throws {
        let model = await makeModel()
        model.setText("- Never force-push.\n", file: .agents, on: .local)
        await model.save()
        #expect(store.snapshot().agents == "- Never force-push.\n")
        #expect(!model.isEdited(.agents, on: .local))
        #expect(model.history(on: .local).map(\.summary) == ["Added “Never force-push.”"])
        #expect(model.problem == nil)
    }

    @Test func revertDropsTheDraft() async throws {
        try store.save(.appendSystem, content: "rule\n")
        let model = await makeModel()
        model.file = .appendSystem
        model.setText("other\n", file: .appendSystem, on: .local)
        model.revert()
        #expect(model.text(.appendSystem, on: .local) == "rule\n")
        #expect(store.snapshot().appendSystem == "rule\n")
    }

    @Test func restorePutsASavedVersionBack() async throws {
        try store.save(.agents, content: "- a\n")
        try store.save(.agents, content: "- b\n")
        let model = await makeModel()
        let first = try #require(model.history(on: .local).last)
        await model.restore(first, on: .local)
        #expect(store.snapshot().agents == "- a\n")
        #expect(model.text(.agents, on: .local) == "- a\n")
        #expect(model.history(on: .local).first?.summary.hasPrefix("Restored the ") == true)
    }

    @Test func saveNamesWhereItWrites() async throws {
        let alone = await makeModel()
        #expect(alone.saveTitle == "Save")

        let (hosts, hostID) = offlineHost()
        defer { hosts.removeHost(id: hostID) }
        let model = await makeModel(hosts)
        // An offline host still takes the save later, so it counts.
        #expect(model.saveTitle == "Save to 2 hosts")
        model.sameEverywhere = false
        model.machine = .remote(hostID)
        #expect(model.saveTitle == "Save to horizon")
    }

    @Test func anOfflineHostIsOwedTheFilesOfASave() async throws {
        let (hosts, hostID) = offlineHost()
        defer { hosts.removeHost(id: hostID) }
        let model = await makeModel(hosts)
        #expect(model.files(of: hostID) == .offline)
        model.setText("- a\n", file: .agents, on: .local)
        await model.save()
        #expect(store.snapshot().agents == "- a\n")
        #expect(model.chip(for: .remote(hostID)) == InstructionsChip(.quiet, "offline · will sync"))
        // Owed across launches.
        let relaunched = InstructionsModel(store: store, remoteHosts: hosts, defaults: defaults)
        #expect(relaunched.chip(for: .remote(hostID)) == InstructionsChip(.quiet, "offline · will sync"))
    }

    @Test func sameOnEveryHostIsRememberedAndEditsThisMac() async throws {
        let (hosts, hostID) = offlineHost()
        defer { hosts.removeHost(id: hostID) }
        let model = await makeModel(hosts)
        #expect(model.sameEverywhere)
        model.sameEverywhere = false
        model.machine = .remote(hostID)
        #expect(!InstructionsModel(store: store, remoteHosts: hosts, defaults: defaults).sameEverywhere)
        model.sameEverywhere = true
        #expect(model.machine == .local)
    }

    /// A host that can't be read can't be edited: nothing could say what a save would replace.
    @Test func anUnreadHostHasNoTextToEdit() async throws {
        let (hosts, hostID) = offlineHost()
        defer { hosts.removeHost(id: hostID) }
        let model = await makeModel(hosts)
        #expect(model.saved(.agents, on: .remote(hostID)) == nil)
        #expect(model.path(of: .agents, on: .remote(hostID)) == nil)
        #expect(model.row(for: .remote(hostID)).detail == "offline")
        #expect(model.comparing == nil)
    }

    /// Lets the model's own tasks run until `condition` holds; here they finish at once, since
    /// nothing waits on a host.
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
    }

    /// A suggestion added while AGENTS.md is being edited stays when the draft is saved.
    @Test func aLineAddedUnderADraftStaysInIt() async throws {
        try store.save(.agents, content: "- a\n")
        let model = await makeModel()
        model.setText("- a\n- edited\n", file: .agents, on: .local)
        model.localChanged(try store.save(.agents, content: "- a\n- added\n"))
        #expect(model.saved(.agents, on: .local) == "- a\n- added\n")
        #expect(model.text(.agents, on: .local) == "- a\n- edited\n- added\n")
    }

    /// With Same on every host on, a change to This Mac's files from elsewhere goes to every
    /// host too; one that is offline is owed it.
    @Test func aChangeOnThisMacIsOwedToAnOfflineHost() async throws {
        let (hosts, hostID) = offlineHost()
        defer { hosts.removeHost(id: hostID) }
        let model = await makeModel(hosts)
        model.localChanged(try store.save(.agents, content: "- from the iPhone\n"))
        await settle { model.chip(for: .remote(hostID)).word == "offline · will sync" }
        #expect(model.chip(for: .remote(hostID)) == InstructionsChip(.quiet, "offline · will sync"))
    }

    @Test func thisMacReadsAsThisMacInAHostsHistory() async {
        let model = await makeModel()
        let synced = InstructionHistoryEntry(id: UUID(), file: .agents, savedAt: 0,
                                             summary: "Synced from \(InstructionsModel.machineName)")
        #expect(model.summary(of: synced) == "Synced from This Mac")
        let other = InstructionHistoryEntry(id: UUID(), file: .agents, savedAt: 0, summary: "Synced from studio")
        #expect(model.summary(of: other) == "Synced from studio")
    }
}

import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestKit
@testable import ShepherdApp

/// Settings ▸ Instructions on the Mac: drafts, what Save writes, and what stays when a save lands
/// under an edit. The files are the fleet's: the page edits this Mac's copy and knows no other host.
@Suite("Instructions model")
@MainActor
struct InstructionsModelTests {
    let store: InstructionsStore
    let defaults = Fixture.defaults()

    init() throws {
        store = InstructionsStore(directory: try makeScratchDirectory("instructions"))
    }

    func makeModel() async -> InstructionsModel {
        let model = InstructionsModel(store: store, remoteHosts: RemoteHostStore(defaults: defaults, connects: false))
        await model.refresh()
        return model
    }

    /// L9: the AGENTS.md and APPEND_SYSTEM.md that came over into Shepherd's pi home are named on
    /// the page while Shepherd's own file is empty, and Use it here makes the copy the draft.
    @Test func importedInstructionsAreOfferedWhileShepherdsFileIsEmpty() async throws {
        let piHome = try makeScratchDirectory("pi-home")
        try "# Your rules\n".write(to: piHome.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "".write(to: piHome.appendingPathComponent("APPEND_SYSTEM.md"), atomically: true, encoding: .utf8)
        let model = InstructionsModel(store: store, remoteHosts: RemoteHostStore(defaults: defaults, connects: false))
        model.piHome = piHome
        await model.refresh()
        #expect(model.imported.keys.sorted { $0.rawValue < $1.rawValue } == [.agents], "an empty APPEND_SYSTEM.md offers nothing")
        #expect(model.adoptable(.agents)?.name == "AGENTS.md" && model.adoptable(.appendSystem) == nil)
        model.adoptImported(.agents)
        #expect(model.text(.agents) == "# Your rules\n" && model.isEdited(.agents))
        #expect(model.adoptable(.agents) == nil, "once adopted (or edited) the offer is gone")
        await model.save()
        #expect(store.snapshot().agents == "# Your rules\n" && model.adoptable(.agents) == nil)
    }

    @Test func anEditIsADraftUntilItMatchesTheSavedFileAgain() async throws {
        try store.save(.agents, content: "- a\n")
        let model = await makeModel()
        #expect(model.text(.agents) == "- a\n")
        model.setText("- a\n- b\n", file: .agents)
        #expect(model.isEdited(.agents))
        #expect(model.canSave)
        // The other file has no draft of its own.
        #expect(!model.isEdited(.appendSystem))
        model.setText("- a\n", file: .agents)
        #expect(!model.isEdited(.agents))
        #expect(!model.canSave)
    }

    @Test func saveWritesThisMacsFileAndRecordsIt() async throws {
        let model = await makeModel()
        model.setText("- Never force-push.\n", file: .agents)
        await model.save()
        #expect(store.snapshot().agents == "- Never force-push.\n")
        #expect(!model.isEdited(.agents))
        #expect(model.history().map(\.summary) == ["Added “Never force-push.”"])
        #expect(model.problem == nil)
    }

    @Test(arguments: [false, true])
    func savingOrRestoringKeepsNewerEdits(restore: Bool) async throws {
        let entry = InstructionHistoryEntry(id: UUID(), file: .agents, savedAt: 0, summary: "older")
        let (requests, arrivals) = AsyncStream<RemoteInstructionsRequest>.makeStream()
        let (replies, resume) = AsyncStream<InstructionsSnapshot>.makeStream()
        let model = InstructionsModel(store: store, remoteHosts: RemoteHostStore(defaults: defaults, connects: false)) { request in
            arrivals.yield(request)
            for await snapshot in replies { return snapshot }
            throw RemoteHostClientError.disconnected
        }
        model.setText("submitted", file: .agents)
        let writing = Task {
            if restore { await model.restore(entry) } else { await model.save() }
        }
        for await request in requests {
            // The page is the Mac's own: the host's history says "This Mac" for an empty origin, and the fleet carries the rest.
            if restore {
                #expect(request == .restore(revisionID: entry.id, origin: ""))
            } else {
                #expect(request == .save(file: .agents, content: "submitted", origin: "", sync: false))
            }
            break
        }
        model.setText("newer edit", file: .agents)
        resume.yield(InstructionsSnapshot(agents: restore ? "restored" : "submitted", directory: "~/i"))
        await writing.value
        arrivals.finish()
        resume.finish()
        #expect(model.text(.agents) == "newer edit")
        #expect(model.isEdited(.agents))
        #expect(model.problem == nil)
        #expect(model.saved(.agents) == (restore ? "restored" : "submitted"))
    }

    @Test func revertDropsTheDraft() async throws {
        try store.save(.appendSystem, content: "rule\n")
        let model = await makeModel()
        model.file = .appendSystem
        model.setText("other\n", file: .appendSystem)
        model.revert()
        #expect(model.text(.appendSystem) == "rule\n")
        #expect(store.snapshot().appendSystem == "rule\n")
    }

    @Test func restorePutsASavedVersionBack() async throws {
        try store.save(.agents, content: "- a\n")
        try store.save(.agents, content: "- b\n")
        let model = await makeModel()
        let first = try #require(model.history().last)
        await model.restore(first)
        #expect(store.snapshot().agents == "- a\n")
        #expect(model.text(.agents) == "- a\n")
        #expect(model.history().first?.summary.hasPrefix("Restored the ") == true)
    }

    /// A suggestion added while AGENTS.md is being edited stays when the draft is saved.
    @Test func aLineAddedUnderADraftStaysInIt() async throws {
        try store.save(.agents, content: "- a\n")
        let model = await makeModel()
        model.setText("- a\n- edited\n", file: .agents)
        model.localChanged(try store.save(.agents, content: "- a\n- added\n"))
        #expect(model.saved(.agents) == "- a\n- added\n")
        #expect(model.text(.agents) == "- a\n- edited\n- added\n")
    }

    /// A save another Mac made arrives through the host's sync: the open page shows it at once.
    @Test func aSyncedSaveShowsAtOnceAndLeavesTheOtherFilesDraftAlone() async throws {
        let model = await makeModel()
        model.setText("my draft of APPEND_SYSTEM", file: .appendSystem)
        model.localChanged(try store.save(.agents, content: "from the Mac mini\n", origin: "Mac mini", sync: true))
        #expect(model.saved(.agents) == "from the Mac mini\n" && !model.isEdited(.agents))
        #expect(model.text(.appendSystem) == "my draft of APPEND_SYSTEM")
        #expect(model.history().map(\.summary) == ["Synced from Mac mini"])
    }
}

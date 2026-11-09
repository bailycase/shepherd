import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import Testing
import ShepherdUI
@testable import ShepherdApp

/// Sheets and dialogs: how errors read, and stable footer actions.
@Suite("Dialogs")
struct DialogTests {
    /// The error sheet's body reads as a sentence, never as a Swift value dump.
    @Test func actionErrorsAreWordedForAPerson() {
        struct Plain: Error, CustomStringConvertible { var description: String { "the branch is checked out elsewhere" } }
        struct Localized: LocalizedError { var errorDescription: String? { "The host refused the rename." } }
        enum Dump: Error { case noSuchAgent(AgentID) }
        #expect(ActionError.describe(ChangesError("busy", "A turn is still running.")) == "A turn is still running.")
        #expect(ActionError.describe(Localized()) == "The host refused the rename.")
        #expect(ActionError.describe(Plain()) == "the branch is checked out elsewhere")
        #expect(!ActionError.describe(Dump.noSuchAgent(AgentID(rawValue: "a"))).contains("rawValue"))
        let subtitle = AgentDeleteDialog.subtitle(Fixture.agent("Rename the API", in: Fixture.space("one", path: "/tmp/one")).agent)
        #expect(subtitle.hasPrefix("Removes “Rename the API”"))
    }

    /// A host's agent: the dialog names the host and says the thread closes on every device; This Mac's
    /// wording is unchanged.
    @Test func aHostsAgentsDeleteDialogNamesItsHost() {
        var agent = Fixture.agent("Rename the API", in: Fixture.space("one", path: "/tmp/one")).agent
        #expect(AgentDeleteDialog.subtitle(agent, host: "build-01")
                == "Removes “Rename the API” on build-01. Its conversation stays on build-01, but the thread closes on every device and cannot be reopened.")
        agent.status = .working
        #expect(AgentDeleteDialog.subtitle(agent, host: "build-01").hasPrefix("Stops and removes “Rename the API” on build-01."))
        #expect(AgentDeleteDialog.subtitle(agent) == "Stops and removes “Rename the API”. Its conversation stays on disk, but the thread leaves the sidebar and cannot be reopened here.")
    }

    /// The background host on this Mac holds This Mac's own threads: its dialog names no host.
    @Test func theBackgroundHostsThreadsTakeThisMacsWords() {
        #expect(RemoteDeleteItem.hostName(.init(name: "build-01", host: "10.0.0.2", port: 7800, token: "t")) == "build-01")
        #expect(RemoteDeleteItem.hostName(.init(name: "This Mac", host: "", port: 0, token: "t", localSocket: "/tmp/h.sock")) == nil)
    }

    /// A fresh identity per render rebuilds every footer button; the label is stable.
    @Test func dialogActionsKeepTheirIdentityAcrossRenders() {
        let first = DialogAction("Delete agent only") {}
        let second = DialogAction("Delete agent only", kind: .destructive) {}
        #expect(first.id == second.id)
        #expect(DialogAction("Cancel", kind: .cancel) {}.id != first.id)
    }
}

import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// What a remote client sees of this Mac's settings, and a client's change applied as the Mac's
/// own Settings would apply it.
@Suite("Host settings")
@MainActor
struct HostSettingsMappingTests {
    @Test func aClientSeesWhatTheMacsSettingsSay() {
        let app = AppSettings(store: Fixture.defaults())
        app.defaultModel = "anthropic/claude-opus"
        app.defaultThinking = .high
        app.goalCrossProviderEvaluation = true
        app.goalsEnabled = true
        app.worktreeBaseMode = .head
        app.worktreeAutoMergePR = true
        app.worktreeMergeMethod = .rebase
        app.piReviewExtension = false
        let settings = HostSettingsMapping.settings(from: app, shepherdVersion: "0.4.2", piVersion: "0.87.1")
        #expect(settings.shepherdVersion == "0.4.2" && settings.piVersion == "0.87.1")
        #expect(settings.defaultModel == "anthropic/claude-opus")
        #expect(settings.defaultThinking == .high)
        #expect(settings.goalCrossProviderEvaluation && settings.goalsEnabled)
        #expect(settings.worktreeBase == .head)
        #expect(settings.mergePRAutomatically && settings.mergeMethod == .rebase)
        #expect(settings.bundledExtensions.map(\.id) == ["namer", "panes", "review", "nativeSubagents", "subagents", "mcp", "browser", "context"])
        #expect(settings.bundledExtensions.first { $0.id == "review" }?.on == false)
        #expect(settings.bundledExtensions.first { $0.id == "review" }?.name == "Diff review tool")
        // The extension keeps its stored id; it reads as terminals to the user.
        #expect(settings.bundledExtensions.first { $0.id == "panes" }?.name == "Terminals and agent tools")
        // pi's own default reads as none.
        app.defaultModel = ""
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil).defaultModel == nil)
    }

    @Test func aClientExplainsEveryBundledExtensionTheMacServes() {
        for bundled in HostSettingsMapping.bundled {
            #expect(HostSettingsPresentation.note(forBundled: bundled.id) != nil, "no note for \(bundled.id)")
        }
        #expect(HostSettingsPresentation.note(forBundled: "someday") == nil)
    }

    /// There is no pane to control: the row and its note, on the Mac and in every client, speak of
    /// terminals.
    @Test func noBundledExtensionsNameOrNoteSaysPane() {
        for bundled in HostSettingsMapping.bundled where bundled.id == "panes" {
            let note = HostSettingsPresentation.note(forBundled: bundled.id) ?? ""
            #expect(bundled.name == "Terminals and agent tools")
            #expect(note.contains("terminals"))
            for text in [bundled.name, note] {
                #expect(!text.lowercased().contains("pane"), "\(text)")
            }
        }
    }

    /// Trimming old tool output is Settings ▸ Agents on the Mac and one more switch in a client's list.
    @Test func aClientCanSwitchOldToolOutputTrimmingOffAndOn() {
        let app = AppSettings(store: Fixture.defaults())
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil).bundledExtensions.first { $0.id == "context" }?.on == true)
        HostSettingsMapping.apply(.bundledExtension(id: "context", on: false), to: app)
        #expect(!app.trimToolOutput)
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil).bundledExtensions.first { $0.id == "context" }?.on == false)
    }

    @Test func aClientsChangeLandsInTheMacsSettings() {
        let app = AppSettings(store: Fixture.defaults())
        HostSettingsMapping.apply(.defaultModel("  openai/gpt-5 "), to: app)
        #expect(app.defaultModel == "openai/gpt-5")
        HostSettingsMapping.apply(.defaultModel(nil), to: app)
        #expect(app.defaultModel.isEmpty)
        #expect(!app.goalCrossProviderEvaluation)
        HostSettingsMapping.apply(.goalCrossProviderEvaluation(true), to: app)
        #expect(app.goalCrossProviderEvaluation)
        HostSettingsMapping.apply(.goalCrossProviderEvaluation(false), to: app)
        #expect(!app.goalCrossProviderEvaluation)
        HostSettingsMapping.apply(.queueDelivery(.oneAtATime), to: app)
        #expect(app.queueDelivery == .oneAtATime)
        HostSettingsMapping.apply(.worktreeBase(.head), to: app)
        #expect(app.worktreeBaseMode == .head)
        HostSettingsMapping.apply(.mergeMethod(.merge), to: app)
        #expect(app.worktreeMergeMethod == .merge)
        HostSettingsMapping.apply(.bundledExtension(id: "panes", on: false), to: app)
        #expect(!app.piPanesExtension)
        HostSettingsMapping.apply(.bundledExtension(id: "namer", on: false), to: app)
        #expect(!app.autoNameAgents)
        HostSettingsMapping.apply(.bundledExtension(id: "browser", on: false), to: app)
        #expect(!app.piBrowserExtension, "a remote client can switch Browser tools")
        // An extension the Mac doesn't bundle changes nothing.
        let before = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        HostSettingsMapping.apply(.bundledExtension(id: "missiles", on: true), to: app)
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil) == before)
    }

    /// Every change the protocol names reaches the setting it names, as the snapshot reads back.
    @Test(arguments: [
        HostSettingChange.defaultThinking(.low), .goalCrossProviderEvaluation(true), .goalCrossProviderEvaluation(false),
        .goalsEnabled(true), .goalsEnabled(false),
        .fetchBeforeCreating(false), .commitRemainingWork(false),
        .generatePRDescriptions(false), .deleteLocalBranch(false), .mergePRAutomatically(true),
        .bundledExtension(id: "review", on: false), .bundledExtension(id: "nativeSubagents", on: false), .bundledExtension(id: "context", on: false),
    ])
    func aChangeReadsBackAsTheProtocolAppliesIt(_ change: HostSettingChange) {
        let app = AppSettings(store: Fixture.defaults())
        var expected = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        expected.apply(change)
        HostSettingsMapping.apply(change, to: app)
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil) == expected)
    }
}

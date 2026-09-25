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
        app.worktreeBaseMode = .head
        app.worktreeAutoMergePR = true
        app.worktreeMergeMethod = .rebase
        app.piReviewExtension = false
        let settings = HostSettingsMapping.settings(from: app, shepherdVersion: "0.4.2", piVersion: "0.87.1")
        #expect(settings.shepherdVersion == "0.4.2" && settings.piVersion == "0.87.1")
        #expect(settings.defaultModel == "anthropic/claude-opus")
        #expect(settings.defaultThinking == .high)
        #expect(settings.worktreeBase == .head)
        #expect(settings.mergePRAutomatically && settings.mergeMethod == .rebase)
        #expect(settings.bundledExtensions.map(\.id) == ["namer", "theme", "panes", "review", "nativeSubagents", "subagents"])
        #expect(settings.bundledExtensions.first { $0.id == "review" }?.on == false)
        #expect(settings.bundledExtensions.first { $0.id == "review" }?.name == "Diff review tool")
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

    @Test func aClientsChangeLandsInTheMacsSettings() {
        let app = AppSettings(store: Fixture.defaults())
        HostSettingsMapping.apply(.defaultModel("  openai/gpt-5 "), to: app)
        #expect(app.defaultModel == "openai/gpt-5")
        HostSettingsMapping.apply(.defaultModel(nil), to: app)
        #expect(app.defaultModel.isEmpty)
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
        // An extension the Mac doesn't bundle changes nothing.
        let before = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        HostSettingsMapping.apply(.bundledExtension(id: "missiles", on: true), to: app)
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil) == before)
    }

    /// Every change the protocol names reaches the setting it names, as the snapshot reads back.
    @Test(arguments: [
        HostSettingChange.defaultThinking(.low), .fetchBeforeCreating(false), .commitRemainingWork(false),
        .generatePRDescriptions(false), .deleteLocalBranch(false), .mergePRAutomatically(true),
        .bundledExtension(id: "theme", on: false), .bundledExtension(id: "nativeSubagents", on: false),
    ])
    func aChangeReadsBackAsTheProtocolAppliesIt(_ change: HostSettingChange) {
        let app = AppSettings(store: Fixture.defaults())
        var expected = HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil)
        expected.apply(change)
        HostSettingsMapping.apply(change, to: app)
        #expect(HostSettingsMapping.settings(from: app, shepherdVersion: nil, piVersion: nil) == expected)
    }
}

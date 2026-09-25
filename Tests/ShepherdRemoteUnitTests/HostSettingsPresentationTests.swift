import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// Settings rows on the iPhone and the iPad say what the host's settings say.
@Suite("Host settings presentation")
struct HostSettingsPresentationTests {
    @Test func rowsSayTheirValueShort() {
        var settings = HostSettings(defaultModel: "anthropic/claude-opus",
                                    bundledExtensions: [HostSettings.BundledExtension(id: "panes", name: "Panes", on: true),
                                                        HostSettings.BundledExtension(id: "review", name: "Review", on: false)],
                                    installedExtensions: ["npm:@example/pi-tools", "~/pi/checks.ts"])
        #expect(HostSettingsPresentation.defaultsValue(settings) == "claude-opus")
        #expect(HostSettingsPresentation.extensionsValue(settings) == "3")
        settings.defaultModel = nil
        #expect(HostSettingsPresentation.defaultsValue(settings) == "pi's default")
        settings.piVersion = "0.87.1"
        #expect(HostSettingsPresentation.piVersion(settings) == "pi 0.87.1")
        #expect(HostSettingsPresentation.piVersion(nil) == nil)
        #expect(HostSettingsPresentation.experimentsValue(on: true) == "1 on")
        #expect(HostSettingsPresentation.experimentsValue(on: false) == "Off")
    }

    @Test(arguments: [
        (InstructionsSnapshot(agents: "- a\n", appendSystem: "rule\n", directory: "~"), "AGENTS.md, APPEND"),
        (InstructionsSnapshot(agents: "- a\n", directory: "~"), "AGENTS.md"),
        (InstructionsSnapshot(appendSystem: "rule\n", directory: "~"), "APPEND"),
        (InstructionsSnapshot(agents: " \n", directory: "~"), "None"),
    ])
    func instructionsSayWhichFilesHoldAnything(snapshot: InstructionsSnapshot, value: String) {
        #expect(HostSettingsPresentation.instructionsValue(snapshot) == value)
    }

    @Test func optionsReadAsTheMacNamesThem() {
        #expect(HostSettingsPresentation.title(ThinkingLevel.medium) == "Medium")
        #expect(HostSettingsPresentation.title(NativeQueueMode.oneAtATime) == "One per turn")
        #expect(HostSettingsPresentation.title(HostSettings.WorktreeBase.fresh) == "Remote default")
        #expect(HostSettingsPresentation.title(HostSettings.MergeMethod.squash) == "Squash")
    }
}

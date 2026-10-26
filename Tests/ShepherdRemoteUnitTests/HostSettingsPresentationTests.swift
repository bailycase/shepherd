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
        #expect(HostSettingsPresentation.defaultsValue(settings) == "Agent’s default")
        settings.piVersion = "0.87.1"
        #expect(HostSettingsPresentation.agentVersion(settings) == "agent 0.87.1")
        #expect(HostSettingsPresentation.agentVersion(settings, namingPi: true) == "pi 0.87.1")
        #expect(HostSettingsPresentation.agentVersion(nil) == nil)
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
        #expect(HostSettingsPresentation.title(ThinkingLevel.xhigh) == "Extra high")
        #expect(HostSettingsPresentation.title(NativeQueueMode.oneAtATime) == "One per turn")
        #expect(HostSettingsPresentation.title(HostSettings.WorktreeBase.fresh) == "Remote default")
        #expect(HostSettingsPresentation.title(HostSettings.MergeMethod.squash) == "Squash")
    }

    // MARK: Update presentation

    @Test func updateVersionLineIncludesChannel() {
        let main = HostUpdateStatus(version: "1.4.2", build: "142", channel: "main", phase: .upToDate)
        #expect(HostSettingsPresentation.versionLine(main) == "Shepherd 1.4.2")
        let nightly = HostUpdateStatus(version: "1.5.0-beta.3", build: "503", channel: "nightly", phase: .upToDate)
        #expect(HostSettingsPresentation.versionLine(nightly) == "Shepherd 1.5.0-beta.3 Nightly")
    }

    @Test func updateSummaryCoversEveryPhase() {
        let base = HostUpdateStatus(version: "1.0", build: "1", channel: "main", phase: .upToDate)
        #expect(HostSettingsPresentation.updateSummary(base) == "Up to date")
        #expect(HostSettingsPresentation.updateSummary(.init(version: "1.0", build: "1", channel: "main", phase: .checking)) == "Checking for updates\u{2026}")
        #expect(HostSettingsPresentation.updateSummary(.init(version: "1.0", build: "1", channel: "main", phase: .available, offeredVersion: "2.0")) == "Update available: 2.0")
        #expect(HostSettingsPresentation.updateSummary(.init(version: "1.0", build: "1", channel: "main", phase: .downloading)) == "Downloading update\u{2026}")
        #expect(HostSettingsPresentation.updateSummary(.init(version: "1.0", build: "1", channel: "main", phase: .installing)) == "Installing update\u{2026}")
        #expect(HostSettingsPresentation.updateSummary(.init(version: "1.0", build: "1", channel: "main", phase: .failed, error: "Bad sig")) == "Bad sig")
        #expect(HostSettingsPresentation.updateSummary(.init(version: "1.0", build: "1", channel: "main", phase: .unsupported)) == "Updates not available")
        #expect(HostSettingsPresentation.updateSummary(.init(version: "1.0", build: "1", channel: "main", phase: .idle)) == "Up to date")
    }

    @Test func canCheckOnlyInTerminalPhases() {
        #expect(HostSettingsPresentation.canCheck(.init(version: "1", build: "1", channel: "m", phase: .upToDate)) == true)
        #expect(HostSettingsPresentation.canCheck(.init(version: "1", build: "1", channel: "m", phase: .available)) == true)
        #expect(HostSettingsPresentation.canCheck(.init(version: "1", build: "1", channel: "m", phase: .failed)) == true)
        #expect(HostSettingsPresentation.canCheck(.init(version: "1", build: "1", channel: "m", phase: .checking)) == false)
        #expect(HostSettingsPresentation.canCheck(.init(version: "1", build: "1", channel: "m", phase: .downloading)) == false)
        #expect(HostSettingsPresentation.canCheck(.init(version: "1", build: "1", channel: "m", phase: .installing)) == false)
        #expect(HostSettingsPresentation.canCheck(.init(version: "1", build: "1", channel: "m", phase: .unsupported)) == false)
    }

    @Test func canInstallRequiresAvailableAndCapableAndOffer() {
        let offer = UUID()
        #expect(HostSettingsPresentation.canInstall(.init(version: "1", build: "1", channel: "m", phase: .available, offerID: offer, offeredVersion: "2", canInstall: true)) == true)
        // Missing offer
        #expect(HostSettingsPresentation.canInstall(.init(version: "1", build: "1", channel: "m", phase: .available, canInstall: true)) == false)
        // canInstall false (busy agents)
        #expect(HostSettingsPresentation.canInstall(.init(version: "1", build: "1", channel: "m", phase: .available, offerID: offer, canInstall: false)) == false)
        // Wrong phase
        #expect(HostSettingsPresentation.canInstall(.init(version: "1", build: "1", channel: "m", phase: .upToDate, offerID: offer, canInstall: true)) == false)
    }

    @Test func installBlockReasonOnlyWhenAvailableButBlocked() {
        #expect(HostSettingsPresentation.installBlockReason(.init(version: "1", build: "1", channel: "m", phase: .available, error: "2 agents busy", canInstall: false)) == "2 agents busy")
        // Available and can install: no block
        #expect(HostSettingsPresentation.installBlockReason(.init(version: "1", build: "1", channel: "m", phase: .available, canInstall: true)) == nil)
        // Not available: no block shown
        #expect(HostSettingsPresentation.installBlockReason(.init(version: "1", build: "1", channel: "m", phase: .upToDate, canInstall: false)) == nil)
    }

    @Test func updateTonesMapped() {
        #expect(HostSettingsPresentation.updateTone(.init(version: "1", build: "1", channel: "m", phase: .upToDate)) == .idle)
        #expect(HostSettingsPresentation.updateTone(.init(version: "1", build: "1", channel: "m", phase: .checking)) == .running)
        #expect(HostSettingsPresentation.updateTone(.init(version: "1", build: "1", channel: "m", phase: .available)) == .attention)
        #expect(HostSettingsPresentation.updateTone(.init(version: "1", build: "1", channel: "m", phase: .failed)) == .failed)
    }
}

import Foundation
import ShepherdCore
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// Settings are per-user chrome in UserDefaults; every test uses its own scratch suite.
@Suite("App settings")
@MainActor
struct AppSettingsTests {
    @Test func freshSettingsUseThePublishedDefaults() {
        let settings = AppSettings(store: Fixture.defaults())

        #expect(settings.terminalFontFamily == "SF Mono")
        #expect(settings.terminalFontSize == 12.5)
        #expect(settings.defaultModel.isEmpty)
        #expect(settings.defaultThinking == .medium)
        #expect(settings.autoNameAgents)
        #expect(settings.piPanesExtension && settings.piReviewExtension)
        #expect(settings.piSubagentsExtension && settings.piNativeSubagents)
        #expect(!settings.autoUpdatePi && !settings.autoUpdateExtensions)
        #expect(settings.uiDensity == 1 && settings.uiTextScale == 1)
        #expect(settings.sidebarWidth == AppSettings.defaultSidebarWidth)
        #expect(!settings.remoteListenerEnabled && settings.remoteListenerPort == 7433)
        #expect(settings.worktreeBaseMode == .fresh && settings.worktreeFetchBeforeCreate)
        #expect(settings.worktreeAutoCommit && settings.worktreeGeneratePRDescription && settings.worktreeDeleteLocalBranch)
        #expect(!settings.worktreeAutoMergePR, "merging is strictly opt-in")
        #expect(settings.worktreeMergeMethod == .squash)
        #expect(settings.childConcurrency == 4 && settings.childContext == "fresh" && settings.childScope == "both")
        #expect(settings.childModel.isEmpty && settings.childThinking.isEmpty)
        #expect(settings.returnWhileWorking == .queue, "↩ queues while pi works")
        #expect(settings.queueDelivery == .all, "the queue arrives as one turn")
    }

    /// While pi works: what ↩ does and how the queue goes persist, reset, and a new delivery
    /// default reaches the server.
    @Test func theQueueSettingsPersistResetAndReachTheServer() {
        let store = Fixture.defaults()
        let settings = AppSettings(store: store)
        var delivered: [NativeQueueMode] = []
        settings.onQueueDeliveryChange = { delivered.append($0) }
        settings.returnWhileWorking = .steer
        settings.queueDelivery = .oneAtATime
        settings.queueDelivery = .oneAtATime

        let reloaded = AppSettings(store: store)
        #expect(reloaded.returnWhileWorking == .steer && reloaded.queueDelivery == .oneAtATime)
        #expect(delivered == [.oneAtATime], "only a change is handed on")

        settings.resetToDefaults()
        #expect(settings.returnWhileWorking == .queue && settings.queueDelivery == .all)
        #expect(delivered == [.oneAtATime, .all])
        #expect(store.object(forKey: AppSettings.Key.returnWhileWorking) == nil)
        #expect(store.object(forKey: AppSettings.Key.queueDelivery) == nil)
    }

    /// Shepherd Nightly listens one port up, so both apps can serve this Mac at once; a port the
    /// user chose still wins.
    @Test(arguments: [(ShepherdEdition.main, 7433), (.nightly, 7434)])
    func theListenerPortDefaultsPerEdition(edition: ShepherdEdition, port: Int) {
        #expect(AppSettings(store: Fixture.defaults(), edition: edition).remoteListenerPort == port)

        let store = Fixture.defaults()
        store.set(9000, forKey: AppSettings.Key.remoteListenerPort)
        #expect(AppSettings(store: store, edition: edition).remoteListenerPort == 9000)
    }

    @Test func everySettingPersistsAcrossInstances() {
        let store = Fixture.defaults()
        let settings = AppSettings(store: store)
        settings.terminalFontFamily = "Menlo"
        settings.terminalFontSize = 15
        settings.defaultModel = "anthropic/claude-sonnet-4"
        settings.defaultThinking = .high
        settings.autoNameAgents = false
        settings.piPanesExtension = false
        settings.piReviewExtension = false
        settings.piSubagentsExtension = false
        settings.piNativeSubagents = false
        settings.autoUpdatePi = true
        settings.autoUpdateExtensions = true
        settings.shellPath = "/bin/bash"
        settings.uiDensity = 1.2
        settings.uiTextScale = 1.1
        settings.sidebarWidth = 275
        settings.remoteListenerEnabled = true
        settings.remoteListenerPort = 9000
        settings.worktreeBaseMode = .head
        settings.worktreeFetchBeforeCreate = false
        settings.worktreeAutoCommit = false
        settings.worktreeGeneratePRDescription = false
        settings.worktreeDeleteLocalBranch = false
        settings.worktreeAutoMergePR = true
        settings.worktreeMergeMethod = .rebase

        let reloaded = AppSettings(store: store)
        #expect(reloaded.terminalFontFamily == "Menlo" && reloaded.terminalFontSize == 15)
        #expect(reloaded.defaultModel == "anthropic/claude-sonnet-4" && reloaded.defaultThinking == .high)
        #expect(!reloaded.autoNameAgents)
        #expect(!reloaded.piPanesExtension && !reloaded.piReviewExtension)
        #expect(!reloaded.piSubagentsExtension && !reloaded.piNativeSubagents)
        #expect(reloaded.autoUpdatePi && reloaded.autoUpdateExtensions)
        #expect(reloaded.shellPath == "/bin/bash")
        #expect(reloaded.uiDensity == 1.2 && reloaded.uiTextScale == 1.1 && reloaded.sidebarWidth == 275)
        #expect(reloaded.remoteListenerEnabled && reloaded.remoteListenerPort == 9000)
        #expect(reloaded.worktreeBaseMode == .head && !reloaded.worktreeFetchBeforeCreate)
        #expect(!reloaded.worktreeAutoCommit && !reloaded.worktreeGeneratePRDescription && !reloaded.worktreeDeleteLocalBranch)
        #expect(reloaded.worktreeAutoMergePR && reloaded.worktreeMergeMethod == .rebase)
    }

    /// Hand-edited or stale defaults must not reach ghostty or the layout as unusable values.
    @Test func outOfRangeStoredValuesAreClamped() {
        let store = Fixture.defaults()
        store.set(400.0, forKey: AppSettings.Key.terminalFontSize)
        store.set(9.0, forKey: AppSettings.Key.uiDensity)
        store.set(0.1, forKey: AppSettings.Key.uiTextScale)
        store.set(5_000.0, forKey: AppSettings.Key.sidebarWidth)
        store.set(99, forKey: AppSettings.Key.childConcurrency)
        store.set(70_000, forKey: AppSettings.Key.remoteListenerPort)

        let settings = AppSettings(store: store)
        #expect(settings.terminalFontSize == AppSettings.fontSizeRange.upperBound)
        #expect(settings.uiDensity == AppSettings.uiDensityRange.upperBound)
        #expect(settings.uiTextScale == AppSettings.uiTextScaleRange.lowerBound)
        #expect(settings.sidebarWidth == AppSettings.sidebarWidthRange.upperBound)
        #expect(settings.childConcurrency == 16)
        #expect(settings.remoteListenerPort == 7433)
    }

    @Test func unknownStoredChoicesFallBackToDefaults() {
        let store = Fixture.defaults()
        store.set("gigantic", forKey: AppSettings.Key.defaultThinking)
        store.set("sideways", forKey: AppSettings.Key.worktreeBaseMode)
        store.set("octopus", forKey: AppSettings.Key.worktreeMergeMethod)
        store.set("invalid", forKey: AppSettings.Key.childContext)
        store.set("galaxy", forKey: AppSettings.Key.childScope)
        store.set("ultra", forKey: AppSettings.Key.childThinking)

        let settings = AppSettings(store: store)
        #expect(settings.defaultThinking == .medium)
        #expect(settings.worktreeBaseMode == .fresh && settings.worktreeMergeMethod == .squash)
        #expect(settings.childContext == "fresh" && settings.childScope == "both" && settings.childThinking.isEmpty)
    }

    @Test(arguments: [(100.0, 190.0), (275, 275), (500, 340)])
    func sidebarWidthClampsToItsDragRange(width: Double, clamped: Double) {
        #expect(AppSettings.clampSidebarWidth(width) == clamped)
    }

    @Test func resetRestoresDefaultsInMemoryAndClearsEveryStoredKey() {
        let store = Fixture.defaults()
        let settings = AppSettings(store: store)
        settings.terminalFontSize = 20
        settings.defaultModel = "openai/gpt-5"
        settings.autoNameAgents = false
        settings.uiDensity = 1.3
        settings.uiTextScale = 1.2
        settings.sidebarWidth = 300
        settings.worktreeAutoMergePR = true
        settings.childConcurrency = 9

        settings.resetToDefaults()

        #expect(settings.terminalFontSize == 12.5 && settings.defaultModel.isEmpty && settings.autoNameAgents)
        #expect(settings.uiDensity == 1 && settings.uiTextScale == 1)
        #expect(settings.sidebarWidth == AppSettings.defaultSidebarWidth)
        #expect(!settings.worktreeAutoMergePR && settings.childConcurrency == 4)
        for key in AppSettings.Key.resettable {
            #expect(store.object(forKey: key) == nil, "\(key) survived reset")
        }
    }

    /// Serve this Mac is Remote's own switch: a reset leaves the listener as it is, now and at
    /// the next launch.
    @Test func resetLeavesTheListenerServing() {
        let store = Fixture.defaults()
        let settings = AppSettings(store: store)
        settings.remoteListenerEnabled = true

        settings.resetToDefaults()

        #expect(settings.remoteListenerEnabled)
        #expect(AppSettings(store: store).remoteListenerEnabled)
        #expect(Set(AppSettings.Key.all).subtracting(AppSettings.Key.resettable)
                == [AppSettings.Key.remoteListenerEnabled, AppSettings.Key.remoteListenerPort])
    }

    /// An empty model launches pi without `--model` rather than with an empty argument.
    @Test(arguments: [("", nil), ("   ", nil), (" openai/gpt-5 ", "openai/gpt-5")] as [(String, String?)])
    func agentDefaultsTrimTheModelAndLeaveEmptyToPi(model: String, expected: String?) {
        let settings = AppSettings(store: Fixture.defaults())
        settings.defaultModel = model
        settings.defaultThinking = .low
        #expect(settings.agentDefaults == AgentDefaults(model: expected, thinking: .low))
    }

    @Test func nativeChildDefaultsReachTheLaunchEnvironment() {
        let settings = AppSettings(store: Fixture.defaults())
        settings.childConcurrency = 40
        settings.childModel = " provider/model "
        settings.childThinking = "high"
        settings.childContext = "fork"
        settings.childScope = "user"
        #expect(settings.childEnvironment == [
            "SHEPHERD_CHILD_CONCURRENCY": "16", "SHEPHERD_CHILD_MODEL": "provider/model",
            "SHEPHERD_CHILD_THINKING": "high", "SHEPHERD_CHILD_CONTEXT": "fork", "SHEPHERD_CHILD_SCOPE": "user",
        ])
    }

    /// The former combined toggle ran both updates; that intent survives the split.
    @Test func theLegacyCombinedPiUpdateSettingEnablesExtensionUpdates() {
        let store = Fixture.defaults()
        store.set(true, forKey: AppSettings.Key.autoUpdatePi)
        #expect(AppSettings(store: store).autoUpdateExtensions)
    }

    @Test func aShellThatIsNotExecutableFallsBackToTheDefault() {
        let settings = AppSettings(store: Fixture.defaults())
        settings.shellPath = "/definitely/not/a/shell"
        #expect(settings.shellCommand == [AppSettings.Defaults.shellPath, "-l"])
        settings.shellPath = " /bin/zsh "
        #expect(settings.shellCommand == ["/bin/zsh", "-l"])
    }

    /// A configured family passes straight through to ghostty. (Resolving the system-font
    /// sentinel and listing monospaced families walk the font registry, ~0.4s: not unit work.)
    @Test func aConfiguredFontFamilyIsUsedAsIs() {
        let settings = AppSettings(store: Fixture.defaults())
        settings.terminalFontFamily = "Iosevka"
        #expect(settings.resolvedTerminalFontFamily == "Iosevka")
    }

    @Test func theShellListIsDeduplicatedAndIncludesTheCurrentShell() {
        let shells = AppSettings.knownShells(including: "/opt/custom/shell")
        #expect(shells.contains("/opt/custom/shell"))
        #expect(Set(shells).count == shells.count)
    }
}

@Suite("Legacy terminal-era preferences")
struct LegacyPreferencesTests {
    /// The Terminal/Native switch is gone; its keys are forgotten and nothing else is touched.
    @Test func terminalEraPresentationKeysAreForgotten() {
        let defaults = Fixture.defaults()
        defaults.set(["agent": true], forKey: "shepherd.nativeAgents")
        defaults.set(true, forKey: "shepherd.nativeDefault")
        defaults.set("terminal", forKey: "shepherd.agent.defaultRuntime")
        defaults.set(["space"], forKey: "shepherd.collapsedSpaces")

        LegacyTerminalAgents.forgetPresentationPreferences(in: defaults)

        for key in LegacyTerminalAgents.obsoleteKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
        #expect(defaults.stringArray(forKey: "shepherd.collapsedSpaces") == ["space"])
    }
}

@Suite("Pi updates")
@MainActor
struct PiUpdateTests {
    @Test(arguments: [
        (false, false, [[String]]()),
        (true, false, [["update"]]),
        (false, true, [["update", "--extensions"]]),
        (true, true, [["update"], ["update", "--extensions"]]),
    ])
    func automaticUpdatesRunOnlyTheEnabledCommands(pi: Bool, extensions: Bool, commands: [[String]]) {
        #expect(PiUpdateManager.automaticUpdateArguments(updatePi: pi, updateExtensions: extensions) == commands)
    }

    @Test(arguments: [
        (false, false, [[String]]()),
        (true, false, [["update"]]),
        (false, true, [["update", "--extensions"]]),
        (true, true, [["update"], ["update", "--extensions"]]),
    ])
    func updateNowRunsWhateverThereIsToUpdateInOneRun(pi: Bool, extensions: Bool, commands: [[String]]) {
        #expect(PiUpdateManager.updateNowArguments(pi: pi, extensions: extensions) == commands)
    }

    @Test func updatingIsOfferedUntilCheckedOrWhenOutdatedButNeverWhileBusy() {
        #expect(PiUpdateManager.canUpdatePi(lastChecked: nil, isOutdated: false, isBusy: false))
        #expect(PiUpdateManager.canUpdatePi(lastChecked: Date(), isOutdated: true, isBusy: false))
        #expect(!PiUpdateManager.canUpdatePi(lastChecked: Date(), isOutdated: false, isBusy: false))
        #expect(!PiUpdateManager.canUpdatePi(lastChecked: nil, isOutdated: true, isBusy: true))
    }

    @Test(arguments: [
        ("1.2.3", "1.2.4", true),
        ("1.2.9", "1.3.0", true),
        ("v1.2", "1.2.0", false),       // missing components are zero; the prefix is ignored
        ("1.3.0", "1.2.9", false),
        ("1.2.3", "1.2.3", false),
        ("1.2.3-beta.1", "1.2.4", true),
        ("not-a-version", "1.2.0", false),
        ("1.0.0", "", false),
    ])
    func versionComparisonIsNumericPerComponent(current: String, latest: String, older: Bool) {
        #expect(PiUpdateManager.isVersion(current, olderThan: latest) == older)
    }
}

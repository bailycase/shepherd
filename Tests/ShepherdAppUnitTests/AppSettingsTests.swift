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
        #expect(settings.defaultServiceTier == .standard, "new threads start on Standard")
        #expect(settings.autoNameAgents)
        #expect(!settings.goalCrossProviderEvaluation, "cross-provider goal checks require consent")
        #expect(!settings.goalsEnabled, "Goals is an opt-in experiment")
        #expect(settings.piPanesExtension && settings.piReviewExtension && settings.piDesignReferences)
        #expect(settings.subagentDisplay && settings.piNativeSubagents)
        #expect(settings.piBrowserExtension, "Browser tools are on by default")
        #expect(settings.uiDensity == 1 && settings.uiTextScale == 1)
        #expect(settings.sidebarWidth == AppSettings.defaultSidebarWidth)
        #expect(!settings.remoteListenerEnabled && settings.remoteListenerPort == 7433)
        #expect(settings.worktreeBaseMode == .fresh && settings.worktreeFetchBeforeCreate)
        #expect(settings.worktreeAutoCommit && settings.worktreeGeneratePRDescription && settings.worktreeDeleteLocalBranch)
        #expect(!settings.worktreeAutoMergePR, "merging is strictly opt-in")
        #expect(settings.worktreeMergeMethod == .squash)
        #expect(settings.childConcurrency == 4 && settings.childContext == "fresh")
        #expect(settings.childModel.isEmpty && settings.childThinking.isEmpty)
        #expect(settings.queueDelivery == .all, "the queue arrives as one turn")
        #expect(settings.trimToolOutput, "old tool output is trimmed from the model's context until switched off")
        #expect(settings.deferTools, "rarely used tools are deferred behind tool search until switched off")
        #expect(settings.codemode, "native tool scripting is enabled until switched off")
        #expect(settings.compactAtPercent == nil, "compaction is pi's own until a share is chosen")
        #expect(settings.agentMessages == .ask, "an agent asks before it acts on another thread")
    }

    /// Settings ▸ Agents ▸ Context: Compact at is a share from the list or pi's default, only a
    /// change reaches the pi home, a stored value that is not a choice reads as pi's default, and
    /// Reset settings takes it back; the trim switch persists and resets with it.
    @Test func theContextSettingsPersistResetAndTheShareReachesThePiHome() {
        let store = Fixture.defaults()
        let settings = AppSettings(store: store)
        var written: [Int?] = []
        settings.onCompactAtChange = { written.append($0) }
        settings.compactAtPercent = 80
        settings.compactAtPercent = 80
        settings.trimToolOutput = false
        settings.deferTools = false
        settings.codemode = false

        let reloaded = AppSettings(store: store)
        #expect(reloaded.compactAtPercent == 80 && !reloaded.trimToolOutput && !reloaded.deferTools && !reloaded.codemode)
        #expect(written == [80], "only a change is handed on")

        store.set(75, forKey: AppSettings.Key.compactAtPercent)
        #expect(AppSettings(store: store).compactAtPercent == nil, "75% is not one of the choices")

        settings.resetToDefaults()
        #expect(settings.compactAtPercent == nil && settings.trimToolOutput && settings.deferTools && settings.codemode)
        #expect(written == [80, nil])
        #expect(store.object(forKey: AppSettings.Key.compactAtPercent) == nil && store.object(forKey: AppSettings.Key.trimToolOutput) == nil)
        #expect(store.object(forKey: AppSettings.Key.deferTools) == nil && store.object(forKey: AppSettings.Key.codemode) == nil)
    }

    /// Settings ▸ Pi ▸ Agent-to-agent messages: Ask me until the user chooses, kept across launches,
    /// put back by Reset settings, and only a change reaches the server.
    @Test func theAgentMessagesChoicePersistsResetsAndReachesTheServer() {
        let store = Fixture.defaults()
        let settings = AppSettings(store: store)
        var handed: [AgentMessagePolicy] = []
        settings.onAgentMessagesChange = { handed.append($0) }
        settings.agentMessages = .ask
        settings.agentMessages = .always
        settings.agentMessages = .always
        settings.agentMessages = .never

        #expect(handed == [.always, .never], "only a change is handed on")
        #expect(AppSettings(store: store).agentMessages == .never, "and it is read back on the next launch")
        #expect(store.string(forKey: AppSettings.Key.agentMessages) == "never")

        settings.resetToDefaults()
        #expect(settings.agentMessages == .ask)
        #expect(handed == [.always, .never, .ask], "the server hears it is asking again")
        #expect(store.object(forKey: AppSettings.Key.agentMessages) == nil)
    }

    /// A value from a newer or hand-edited build means nothing here: the agent asks.
    @Test(arguments: ["", "sometimes", "ALWAYS", "true"])
    func aStoredAgentMessagesChoiceThatMeansNothingFallsBackToAsk(stored: String) {
        let store = Fixture.defaults()
        store.set(stored, forKey: AppSettings.Key.agentMessages)
        #expect(AppSettings(store: store).agentMessages == .ask)
    }

    @Test func theChoicesAreWordedAsTheDesignSays() {
        #expect(AgentMessagePolicy.allCases.map(\.title) == ["Ask me", "Always allow", "Never"])
    }

    @Test func theGoalsExperimentPersistsAndResetPausesItThroughTheLiveCallback() {
        let store = Fixture.defaults()
        let settings = AppSettings(store: store)
        var changes: [Bool] = []
        settings.onGoalsChange = { changes.append($0) }
        settings.goalsEnabled = true
        settings.goalsEnabled = true
        #expect(AppSettings(store: store).goalsEnabled)
        settings.goalsEnabled = false
        #expect(!AppSettings(store: store).goalsEnabled)
        settings.goalsEnabled = true
        settings.resetToDefaults()
        #expect(changes == [true, false, true, false])
        #expect(!settings.goalsEnabled && !AppSettings(store: store).goalsEnabled)
        #expect(store.object(forKey: AppSettings.Key.goalsEnabled) == nil)
    }

    @Test func crossProviderConsentPersistsOptOutAndReset() {
        let store = Fixture.defaults()
        let settings = AppSettings(store: store)
        settings.goalCrossProviderEvaluation = true
        #expect(AppSettings(store: store).goalCrossProviderEvaluation)
        settings.goalCrossProviderEvaluation = false
        #expect(!AppSettings(store: store).goalCrossProviderEvaluation)
        settings.goalCrossProviderEvaluation = true
        settings.resetToDefaults()
        #expect(!settings.goalCrossProviderEvaluation)
        #expect(!AppSettings(store: store).goalCrossProviderEvaluation)
        #expect(store.object(forKey: AppSettings.Key.goalCrossProviderEvaluation) == nil)
    }

    /// While pi works: how the queue goes persists, resets, and a new delivery default reaches
    /// the server.
    @Test func theQueueSettingPersistsResetsAndReachesTheServer() {
        let store = Fixture.defaults()
        let settings = AppSettings(store: store)
        var delivered: [NativeQueueMode] = []
        settings.onQueueDeliveryChange = { delivered.append($0) }
        settings.queueDelivery = .oneAtATime
        settings.queueDelivery = .oneAtATime

        let reloaded = AppSettings(store: store)
        #expect(reloaded.queueDelivery == .oneAtATime)
        #expect(delivered == [.oneAtATime], "only a change is handed on")

        settings.resetToDefaults()
        #expect(settings.queueDelivery == .all)
        #expect(delivered == [.oneAtATime, .all])
        #expect(store.object(forKey: AppSettings.Key.queueDelivery) == nil)
    }

    /// Settings ▸ Pi ▸ Slash commands: every command is on until it is switched off, the switches
    /// persist as a sorted list, only a change reaches the server, and Reset settings turns them all on.
    @Test func theSlashCommandSwitchesPersistResetAndReachTheServer() {
        let store = Fixture.defaults()
        let settings = AppSettings(store: store)
        #expect(settings.hiddenSlashCommands.isEmpty, "every command starts on")
        var handed: [Set<String>] = []
        settings.onHiddenSlashCommandsChange = { handed.append($0) }

        settings.setSlashCommand("session-name", on: false)
        settings.setSlashCommand("fix-tests", on: false)
        settings.setSlashCommand("fix-tests", on: false)
        settings.setSlashCommand("never-listed", on: true)

        #expect(handed == [["session-name"], ["fix-tests", "session-name"]], "only a change is handed on")
        #expect(store.stringArray(forKey: AppSettings.Key.hiddenSlashCommands) == ["fix-tests", "session-name"], "stored sorted")
        #expect(AppSettings(store: store).hiddenSlashCommands == ["fix-tests", "session-name"], "and read back on the next launch")

        settings.setSlashCommand("session-name", on: true)
        #expect(settings.hiddenSlashCommands == ["fix-tests"])

        settings.resetToDefaults()
        #expect(settings.hiddenSlashCommands.isEmpty)
        #expect(handed.last == [], "the server hears every command is on again")
        #expect(store.object(forKey: AppSettings.Key.hiddenSlashCommands) == nil)
    }

    /// ↩ always queues while pi works, so there is no Return setting. What an earlier version
    /// stored for it is discarded on launch, and means nothing.
    @Test(arguments: ["queue", "steer", "interrupt", ""])
    func aStoredReturnChoiceIsDiscardedAndIgnored(stored: String) {
        let legacy = "shepherd.agent.returnWhileWorking"
        let store = Fixture.defaults()
        store.set(stored, forKey: legacy)

        let settings = AppSettings(store: store)

        #expect(store.object(forKey: legacy) == nil)
        #expect(!AppSettings.Key.all.contains(legacy), "Reset settings has nothing of it to clear")
        #expect(ComposerSendKey.primary.delivery == .followUp, "Return waits for the turn to end whatever was stored")
        #expect(settings.queueDelivery == .all, "the queue's own setting is untouched")
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
        settings.defaultServiceTier = .fast
        settings.autoNameAgents = false
        settings.agentMessages = .never
        settings.piPanesExtension = false
        settings.piReviewExtension = false
        settings.piDesignReferences = false
        settings.piBrowserExtension = false
        settings.subagentDisplay = false
        settings.piNativeSubagents = false
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
        #expect(reloaded.defaultServiceTier == .fast)
        #expect(!reloaded.autoNameAgents)
        #expect(reloaded.agentMessages == .never)
        #expect(!reloaded.piPanesExtension && !reloaded.piReviewExtension && !reloaded.piDesignReferences)
        #expect(!reloaded.subagentDisplay && !reloaded.piNativeSubagents)
        #expect(!reloaded.piBrowserExtension)
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
        store.set("ultrafast", forKey: AppSettings.Key.defaultServiceTier)
        store.set("sideways", forKey: AppSettings.Key.worktreeBaseMode)
        store.set("octopus", forKey: AppSettings.Key.worktreeMergeMethod)
        store.set("invalid", forKey: AppSettings.Key.childContext)
        store.set("project", forKey: "shepherd.pi.children.scope") // Retired discovery choice must not reach a launch.
        store.set("ultra", forKey: AppSettings.Key.childThinking)

        let settings = AppSettings(store: store)
        #expect(settings.defaultThinking == .medium)
        #expect(settings.defaultServiceTier == .standard, "a tier from a newer build reads as Standard")
        #expect(settings.worktreeBaseMode == .fresh && settings.worktreeMergeMethod == .squash)
        #expect(settings.childContext == "fresh" && settings.childThinking.isEmpty)
        #expect(settings.childEnvironment["SHEPHERD_CHILD_SCOPE"] == nil)
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
        settings.defaultServiceTier = .fast
        settings.autoNameAgents = false
        settings.uiDensity = 1.3
        settings.uiTextScale = 1.2
        settings.sidebarWidth = 300
        settings.worktreeAutoMergePR = true
        settings.childConcurrency = 9

        settings.resetToDefaults()

        #expect(settings.terminalFontSize == 12.5 && settings.defaultModel.isEmpty && settings.autoNameAgents)
        #expect(settings.defaultServiceTier == .standard)
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

    @Test func loadingSettingsDiscardsTheRetiredSkillsDirectoryKey() {
        let store = Fixture.defaults()
        store.set("sk-test", forKey: "shepherd.skills.directoryKey")
        let settings = AppSettings(store: store)
        #expect(store.object(forKey: "shepherd.skills.directoryKey") == nil)
        settings.skillsInSlashMenu = false
        settings.resetToDefaults()
        #expect(settings.skillsInSlashMenu)
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
        #expect(settings.childEnvironment == [
            "SHEPHERD_CHILD_CONCURRENCY": "16", "SHEPHERD_CHILD_MODEL": "provider/model",
            "SHEPHERD_CHILD_THINKING": "high", "SHEPHERD_CHILD_CONTEXT": "fork",
        ])
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

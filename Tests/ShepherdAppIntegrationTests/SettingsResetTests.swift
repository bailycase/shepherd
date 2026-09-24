import Foundation
import ShepherdCore
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Settings ▸ Advanced ▸ Reset through the view model, on isolated preference stores.
@Suite("Settings reset", .mainActorExclusive)
@MainActor
struct SettingsResetTests {
    private func customize(_ app: AppHarness) {
        app.settings.terminalFontSize = 20
        app.settings.defaultModel = "openai/gpt-5"
        app.settings.autoNameAgents = false
        _ = app.keybindings.assign(KeyChord(key: "p", command: true), to: .newAgent)
        app.themeManager.select(.light)
    }

    @Test func resettingRestoresDefaultsKeybindingsAndAppearanceButNotTheWorkspace() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        customize(app)
        let workspace = app.server.state

        vm.resetSettings()

        #expect(app.settings.terminalFontFamily == AppSettings.Defaults.terminalFontFamily)
        #expect(app.settings.terminalFontSize == AppSettings.Defaults.terminalFontSize)
        #expect(app.settings.defaultModel.isEmpty)
        #expect(app.settings.defaultThinking == AppSettings.Defaults.thinking)
        #expect(app.settings.autoNameAgents)
        #expect(app.keybindings.overrides.isEmpty)
        #expect(app.themeManager.mode == .system)
        #expect(app.server.state == workspace && vm.state == workspace)
    }

    /// The pi theme file is written first; if that fails, nothing else may change.
    @Test func aFailedThemeInstallLeavesEveryPreferenceUntouched() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        customize(app)
        let vm = ShepherdViewModel(server: app.server, settings: app.settings, keybindings: app.keybindings,
                                   themeManager: app.themeManager, remoteHosts: app.remoteHosts, sidebarDefaults: app.defaults,
                                   themeInstaller: { _ in throw CocoaError(.fileWriteNoPermission) })

        vm.resetSettings()

        #expect(app.settings.terminalFontSize == 20)
        #expect(app.settings.defaultModel == "openai/gpt-5")
        #expect(!app.settings.autoNameAgents)
        #expect(app.keybindings.overrides[.newAgent] == KeyChord(key: "p", command: true))
        #expect(app.themeManager.current.id == "night-watch-light")
    }
}

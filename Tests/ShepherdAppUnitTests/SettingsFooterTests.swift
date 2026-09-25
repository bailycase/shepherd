import Testing
@testable import ShepherdApp

/// The versions under the Settings navigation: the agent's everywhere but the Pi page, which
/// names the program (the Settings boards' footers).
@Suite("Settings footer")
struct SettingsFooterTests {
    @Test(arguments: SettingsSection.allCases)
    func theFooterNamesTheAgentExceptOnThePiPage(section: SettingsSection) {
        let word = section == .pi ? "pi" : "agent"
        #expect(SettingsView.versions(app: "Shepherd 0.1.0", agent: "0.87.1", on: section) == "Shepherd 0.1.0 · \(word) 0.87.1")
    }

    @Test func anUnknownAgentVersionShowsOnlyTheApp() {
        #expect(SettingsView.versions(app: "Shepherd Nightly 0.0.0", agent: nil, on: .pi) == "Shepherd Nightly 0.0.0")
    }
}

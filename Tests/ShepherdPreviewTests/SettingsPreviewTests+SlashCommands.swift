import AppKit
import Foundation
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdUI
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Settings ▸ Pi ▸ Slash commands in light and dark and at the largest Text size, from the
/// real producer: a `get_commands` payload through the host's own projection
/// (`RPCThreadState.projectCommands`), then the page's model.
extension SettingsPreviewTests {
    /// What pi's `get_commands` answers, in its own shape: a few extension commands, prompt templates
    /// and many skills (`skill:` names), more than a screen.
    static func listedCommands() throws -> [NativeCommand] {
        var items: [[String: Any]] = [
            ["name": "session-name", "description": "Set or clear session name", "source": "extension"],
            ["name": "shepherd-child-pause", "description": "Pause before the next model request", "source": "extension"],
            ["name": "shepherd-child-continue", "description": "Continue a paused child", "source": "extension"],
            ["name": "release-notes", "description": "Draft release notes for a tag from the merged pull requests", "source": "prompt",
             "argumentHint": "[tag]"],
            ["name": "fix-tests", "description": "Fix failing tests", "source": "prompt"],
            ["name": "review-pr", "description": "Review a pull request the way a maintainer would, file by file, with line comments", "source": "prompt",
             "argumentHint": "<number>"],
        ]
        for skill in ["brave-search", "frontend-design", "pdf", "docx", "xlsx", "pptx", "skill-creator", "browser-tools", "gh-pr-review",
                      "sentry", "linear", "figma", "notion", "datadog", "terraform", "kubernetes", "postgres", "redis", "stripe", "twilio",
                      "segment", "launchdarkly", "pagerduty", "grafana", "vercel", "cloudflare", "supabase", "prisma", "playwright", "storybook",
                      "swiftui-specialist", "app-intents-specialist", "modernize-tests", "kane-cli", "dataviz", "artifact-design",
                      "release-checklist", "incident-review", "changelog", "accessibility-audit", "performance-profile",
                      "dependency-audit", "license-check", "security-review", "docs-writer", "api-design", "schema-migration",
                      "load-test", "flaky-test-hunter", "bundle-size"] {
            items.append(["name": "skill:\(skill)", "description": "Use the \(skill) skill: what it is for, and when to reach for it in a thread.",
                          "source": "skill"])
        }
        let data = try JSONSerialization.data(withJSONObject: items)
        return RPCThreadState.projectCommands(try JSONDecoder().decode(JSONValue.self, from: data))
    }

    /// The page with 56 commands over three groups, a handful switched off (an extension command, a
    /// prompt template, skills), one hidden command no pi lists any more, and the search over it.
    @Test func settingsPiSlashCommands() async throws {
        let catalog = try Self.listedCommands()
        #expect(catalog.count == 56 && catalog.map(\.name).contains("skill:pdf"), "pi's list went through the host's projection")
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        workspace.vm.settingsSection = .piSlashCommands
        workspace.vm.slashCommands.catalog = catalog
        workspace.settings.hiddenSlashCommands = ["shepherd-child-pause", "fix-tests", "skill:sentry", "skill:linear", "skill:figma", "old-command"]
        try await Preview.renderMatrix("settings-pi-slash-commands", size: CGSize(width: 1280, height: 2600)) {
            SettingsView(vm: workspace.vm)
        }
    }

    /// The search: a query leaves the rows that match it by name or description, across the groups.
    @Test func settingsPiSlashCommandsSearching() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        workspace.vm.settingsSection = .piSlashCommands
        workspace.vm.slashCommands.catalog = try Self.listedCommands()
        workspace.settings.hiddenSlashCommands = ["fix-tests"]
        workspace.vm.slashCommands.query = "test"
        try await Preview.renderMatrix("settings-pi-slash-commands-search", size: CGSize(width: 1280, height: 900)) {
            SettingsView(vm: workspace.vm)
        }
    }

    /// Nothing listed yet (no agent has started), and a search nothing matches.
    @Test func settingsPiSlashCommandsEmpty() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        workspace.vm.settingsSection = .piSlashCommands
        try await Preview.render("settings-pi-slash-commands-empty", size: CGSize(width: 1280, height: 700)) {
            SettingsView(vm: workspace.vm)
        }
        workspace.vm.slashCommands.catalog = try Self.listedCommands()
        workspace.vm.slashCommands.query = "zzz"
        try await Preview.render("settings-pi-slash-commands-no-match", size: CGSize(width: 1280, height: 700)) {
            SettingsView(vm: workspace.vm)
        }
    }
}

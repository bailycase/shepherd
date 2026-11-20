import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension FixtureCatalog {
    static var spaceConfiguration: [FixtureScreen] {
        let root = "/demo/acme/acme-web"
        let parent = "/demo/acme"
        let name = "acme-web"
        let space = Space(id: SpaceID(rawValue: "space-acme-web"), name: name, path: root)
        let agents = ProjectFile(path: "AGENTS.md", category: .instructions, exists: true)
        let settings = ProjectFile(path: ".shepherd/settings.json", category: .pi, exists: true)
        let mcp = ProjectFile(path: ".shepherd/mcp.json", category: .mcp, exists: true)
        let skill = ProjectResource(kind: .skill, name: "checkout-review", description: "Review checkout changes.", path: ".pi/skills/checkout-review/SKILL.md")
        let inherited = ProjectResource(kind: .skill, name: "release-notes", description: "Draft notes from the changelog.", path: ".pi/skills/release-notes/SKILL.md")
        let host = FixtureHostData(id: FixtureData.studio, name: "acme-studio", state: ShepherdState(spaces: [space]), reply: { request in
            guard case .projects(let id, let action) = request else { return nil }
            let result: RemoteProjectsResult
            switch action {
            case .list:
                result = .listing(.init(projects: [.init(directory: root, name: name, displayPath: root, summary: "AGENTS.md · 1 skill")]))
            case .files(let folder) where folder == root:
                result = .files([agents, settings, mcp, .init(path: skill.path, category: .skills, exists: true)])
            case .context(let folder) where folder == root:
                result = .context(.init(resources: 1, mcpServers: 2, inheritsFrom: parent, excluded: .init()))
            case .read(let folder, let path) where folder == root && path == agents.path:
                result = .text(.init(file: agents, text: "# acme-web\n\n- Run tests before a PR.\n- Use integer cents for totals.\n"))
            case .read(let folder, let path) where folder == root && path == settings.path:
                result = .text(.init(file: settings, text: "{\n  \"codemode\": true\n}"))
            case .read(let folder, let path) where path.hasSuffix("mcp.json"):
                let text = folder == root ? #"{"mcpServers":{"catalog":{"url":"https://catalog.example.com/mcp"},"reports":{"url":"https://reports.example.com/mcp"}}}"#
                    : path == mcp.path ? #"{"mcpServers":{"docs":{"url":"https://docs.example.com/mcp"}}}"# : nil
                result = .text(.init(file: .init(path: path, category: .mcp, exists: text != nil), text: text))
            case .mcp(directory: root, file: mcp.path, action: .credentials):
                result = .mcp(.init(signedIn: ["catalog"]))
            case .resources(let folder):
                result = .resources(folder == root ? [skill] : [inherited])
            default: return nil
            }
            return .projects(id: id, result: result)
        })
        func routes(_ section: SpaceConfigurationSection? = nil) -> [MobileRoute] {
            [.settings(.root), .settings(.spaces), .settings(.spaceConfiguration(host: host.id, directory: root, name: name, section: section))]
        }
        return [
            FixtureScreen(name: "space-configuration", hosts: [host], routes: routes(), tab: .settings),
            FixtureScreen(name: "space-configuration-skills", hosts: [host], routes: routes(.skills), tab: .settings),
            FixtureScreen(name: "space-configuration-mcp", hosts: [host], routes: routes(.mcp), tab: .settings, prepare: { _ in
                SidebarAutomationsCheck.enableAccessibility()
                await FixtureCheck.wait("MCP sign-out and the unsigned server", seconds: 8) {
                    TriggerFlowCheck.element("Sign out") != nil && TriggerFlowCheck.element("reports", prefix: true) != nil
                }
                if TriggerFlowCheck.element("Sign in") != nil { FixtureCheck.fail("Space MCP must not offer sign-in") }
            }),
            FixtureScreen(name: "space-configuration-add-skills", hosts: [host], routes: routes(.skills), tab: .settings, prepare: { _ in
                SidebarAutomationsCheck.enableAccessibility()
                await FixtureCheck.wait("the enabled Add from repo button", seconds: 8) {
                    TriggerFlowCheck.element("Add from repo")?.accessibilityTraits.contains(.notEnabled) == false
                }
                await TriggerFlowCheck.press("Add from repo")
                await FixtureCheck.wait("the add skills sheet", seconds: 8) { TriggerFlowCheck.element("Revision") != nil }
            }),
            FixtureScreen(name: "space-configuration-offline", hosts: [host], routes: routes(), tab: .settings, prepare: { app in
                SidebarAutomationsCheck.enableAccessibility()
                await FixtureCheck.wait("the loaded space", seconds: 8) { TriggerFlowCheck.element("Skills", prefix: true) != nil }
                app.hosts.setForeground(false)
                await FixtureCheck.wait("the offline overview still showing its files", seconds: 8) {
                    TriggerFlowCheck.element("Host offline", prefix: true) != nil && TriggerFlowCheck.element("Skills", prefix: true) != nil
                }
            }),
            FixtureScreen(name: "space-configuration-offline-draft", hosts: [host], routes: routes(), tab: .settings, prepare: { app in
                SidebarAutomationsCheck.enableAccessibility()
                @MainActor func settingsLink() -> NSObject? {
                    SidebarAutomationsCheck.all.first {
                        $0.accessibilityLabel?.hasPrefix("settings.json") == true
                            && $0.accessibilityTraits.contains(.button) && !$0.accessibilityTraits.contains(.notEnabled)
                    }
                }
                await FixtureCheck.wait("the enabled settings file link", seconds: 8) { settingsLink() != nil }
                guard settingsLink()?.accessibilityActivate() == true else { FixtureCheck.fail("Could not open settings.json") }
                @MainActor func editor(in view: UIView) -> InstructionsTextView? {
                    if let editor = view as? InstructionsTextView, editor.accessibilityLabel == settings.path { return editor }
                    for child in view.subviews {
                        if let editor = editor(in: child) { return editor }
                    }
                    return nil
                }
                @MainActor func editor() -> InstructionsTextView? {
                    for window in FixtureWindows.shared.primary?.windows ?? [] {
                        if let editor = editor(in: window) { return editor }
                    }
                    return nil
                }
                await FixtureCheck.wait("the pushed settings editor", seconds: 8) {
                    editor()?.text == "{\n  \"codemode\": true\n}"
                }
                guard let before = editor() else { FixtureCheck.fail("Missing settings editor") }
                before.selectedRange = NSRange(location: 0, length: (before.text as NSString).length)
                // Edit in the fixture's text view without sending input to the simulator or the Mac.
                let draft = "{\n  \"codemode\": false\n}"
                before.insertText(draft)
                await FixtureCheck.wait("the unsaved draft", seconds: 8) {
                    editor()?.text == draft && TriggerFlowCheck.element("Save")?.accessibilityTraits.contains(.notEnabled) == false
                }
                app.hosts.setForeground(false)
                await FixtureCheck.wait("the pushed editor and draft survive going offline", seconds: 8) {
                    editor() === before && editor()?.text == draft && TriggerFlowCheck.element("Host offline", prefix: true) != nil
                        && TriggerFlowCheck.element("Save")?.accessibilityTraits.contains(.notEnabled) == true
                }
                app.hosts.setForeground(true)
                await FixtureCheck.wait("the same draft can be saved after reconnecting", seconds: 8) {
                    app.hosts.host(host.id)?.phase.isConnected == true && editor() === before && editor()?.text == draft
                        && TriggerFlowCheck.element("Host offline", prefix: true) == nil
                        && TriggerFlowCheck.element("Save")?.accessibilityTraits.contains(.notEnabled) == false
                }
                FixtureCheck.report("FIXTURE CHECK ok: the pushed editor kept its unsaved draft through a disconnect and reconnect")
                app.hosts.setForeground(false)
            }),
        ]
    }
}

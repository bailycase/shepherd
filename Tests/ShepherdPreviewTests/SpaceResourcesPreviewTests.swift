import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdApp

/// The space Resources tab (ProjectResources, ProjectSkills, ProjectSlashCommands, ProjectSubagents,
/// ProjectExtensions, ProjectSkillAdd, ProjectSkillEdit, ProjectCommandEdit, ProjectSubagentEdit)
/// over a real space's `.pi` files and the host's global ones in Shepherd's pi home; and the
/// Settings tab's raw JSON view (Edit JSON…).
@Suite("Space resources previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct SpaceResourcesPreviewTests {
    static let files: [String: String] = [
        ".pi/skills/ledger-review/SKILL.md": "---\nname: ledger-review\ndescription: Review ledger changes against double-entry rules.\n---\n\nCheck every ledger write for balanced entries.\nReport findings with file paths and evidence.\n",
        ".pi/skills/payments-tests/SKILL.md": "---\nname: payments-tests\ndescription: Run the payments test suite and report realistic regressions.\n---\n\nRun make test. Check refund events and idempotency.\n",
        ".pi/skills/pdf-tools/SKILL.md": "---\nname: pdf-tools\ndescription: Read and fill payment-related PDFs.\n---\n\nExtract invoice tables and check amounts.\n",
        ".pi/prompts/review.md": "---\ndescription: Review ledger changes against the space rules.\nargument-hint: \"[focus]\"\n---\n\nReview the changes. Focus on ${1:-correctness}.\n",
        ".pi/prompts/fix-tests.md": "---\ndescription: Run the tests, fix failures and rerun.\nargument-hint: \"[suite]\"\n---\n\nRun $@. Diagnose failures before changing expectations.\n",
        ".pi/agents/ledger-reviewer.md": "---\nname: ledger-reviewer\ndescription: Check ledger invariants without editing files.\ntools: [read, grep, find, ls]\nthinking: high\ndefaultContext: fresh\nsystemPromptMode: append\ninheritProjectContext: true\n---\n\nInspect ledger changes. Check balanced entries, minor units and idempotency.\nReturn findings with paths and evidence. Never edit files.\n",
        ".pi/agents/refund-worker.md": "---\nname: refund-worker\ndescription: Implement bounded refund tasks and run focused tests.\ntools: [read, grep, find, ls, bash, edit, write]\n---\n\nImplement the assigned refund task. Run make test. Never commit or push.\n",
        ".pi/extensions/outbox-guard.ts": "// Check ledger writes before tools run.\nexport default function () {}\n",
        ".pi/extensions/project-checks.ts": "// Add the space validation commands.\nexport default function () {}\n",
        ".pi/settings.json": "{\n  \"extensions\": [\"-extensions/project-checks.ts\"],\n  \"prompts\": [\"-prompts/fix-tests.md\"],\n  \"skills\": [\"-skills/pdf-tools/SKILL.md\"]\n}\n",
    ]
    static let globals: [String: String] = [
        "skills/useful-tests/SKILL.md": "---\nname: useful-tests\ndescription: Choose stable tests that protect observable behavior.\n---\n\nFocus tests on public contracts.\n",
        "skills/writing-quality/SKILL.md": "---\nname: writing-quality\ndescription: Edit documentation for plain, direct language.\n---\n\nRemove filler.\n",
        "prompts/explain.md": "---\ndescription: Explain the selected code and its callers.\n---\n\nExplain $@ with concrete examples.\n",
        "agents/scout.md": "---\nname: scout\ndescription: Find relevant code and facts; do not edit files.\ntools: [read, grep, find, ls]\n---\n\nFind relevant code.\n",
        "agents/reviewer.md": "---\nname: reviewer\ndescription: Review correctness and security with concrete evidence.\ntools: [read, grep, find, ls]\n---\n\nReport findings.\n",
        "extensions/workspace-shortcuts.ts": "// Shortcuts for common workspace tasks.\nexport default function () {}\n",
    ]

    @Test(arguments: ["skills", "skills-space", "commands", "extensions", "empty", "dirty", "remove", "leave",
                      "skill-add", "skill-edit", "command-edit", "skill-new", "offline", "settings-json"])
    func resources(state: String) async throws {
        let world = try await ProjectsPreviewWorld(detail: true, supportPi: true)
        defer { world.stop() }
        let model = world.vm.projects
        model.loadModels = { _ in ["anthropic/claude-sonnet-4-6", "anthropic/claude-opus-4-6"] }
        let project = try #require(model.rows.first { $0.project.name == "payments" && $0.host.id == "local" })
        let root = URL(fileURLWithPath: project.project.directory)
        let fm = FileManager.default
        for folder in [".shepherd/skills", ".shepherd/extensions", ".shepherd/settings.json"] { try? fm.removeItem(at: root.appendingPathComponent(folder)) }
        func write(_ base: URL, _ files: [String: String]) throws {
            for (path, text) in files {
                let url = base.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
        }
        if state != "empty" { try write(root, Self.files) }
        try write(world.local.server.pi.home, Self.globals)
        await model.open(project)
        if state == "settings-json" {
            try write(root, [".pi/settings.json": "{\n  \"defaultThinkingLevel\": \"high\",\n  \"enabledModels\": [\"claude-*\"],\n  \"packages\": [\"npm:demo-tools\"]\n}\n"])
            await model.open(project)
            await model.navigate(.category(.pi))
            try await eventuallyOnMain("the form") { model.fileLoaded }
            model.showingSettingsJSON = true
            model.draft = model.draft.replacingOccurrences(of: "\"high\"", with: "\"medium\"")
        } else {
            await model.navigate(.category(.skills))
            try await eventuallyOnMain("the resources") { model.resources.loadedOnce && !model.resources.loading }
        }
        let resources = model.resources
        switch state {
        case "skills-space": resources.scope = .space
        case "commands", "command-edit": resources.kind = .prompt
        case "extensions": resources.kind = .extension
        case "empty": resources.scope = .space
        default: break
        }
        switch state {
        case "dirty":
            await resources.toggle(resources.rows[2], on: true)
        case "remove":
            await resources.askRemove(resources.rows[0])
        case "leave":
            await resources.toggle(resources.rows[0], on: false)
            await model.navigate(.category(.mcp))
        case "skill-add":
            resources.install = .init()
        case "skill-edit", "command-edit":
            await resources.edit(resources.rows[0])
        case "skill-new":
            resources.create()
            resources.editor?.name = "Refund Checks"
            resources.saveEditor()
        case "offline":
            model.selected?.host.unavailable = "Host offline. Reconnect in Settings > Remote to edit its spaces."
        default: break
        }
        try await Preview.renderMatrix("space-resources-\(state)", size: CGSize(width: 1440, height: 900)) {
            SettingsView(vm: world.vm)
        }
    }
}

import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// The Resources tab's pure rules: what a file says, what the editor writes back, and the draft.
@Suite("Space resources")
@MainActor
struct SpaceResourcesTests {
    @Test func eachKindReadsItsNameAndDescriptionFromItsOwnFile() {
        let skill = ProjectResource(kind: .skill, path: ".pi/skills/ledger-review/SKILL.md",
                                    text: "---\nname: ledger-review\ndescription: Review ledgers.\n---\n\nCheck.\n")
        #expect(skill.name == "ledger-review" && skill.description == "Review ledgers.")
        let prompt = ProjectResource(kind: .prompt, path: ".pi/prompts/review.md", text: "---\nargument-hint: \"[focus]\"\n---\nReview the changes.\n")
        #expect(prompt.name == "review" && prompt.description == "Review the changes." && prompt.detail == "[focus]")
        let agent = ProjectResource(kind: .agent, path: ".pi/agents/scout.md", text: "---\nname: scout\ndescription: Find code.\ntools: [read, grep]\ndisabled: true\n---\n\nFind.\n")
        #expect(agent.detail == "read · grep" && !agent.enabled)
        let ext = ProjectResource(kind: .extension, path: ".pi/extensions/outbox-guard.ts", text: "// Check ledger writes before tools run.\nexport default function () {}\n")
        #expect(ext.name == "outbox-guard.ts" && ext.description == "Check ledger writes before tools run.")
    }

    @Test func theEditorRewritesOnlyItsKeysAndKeepsTheRestOfTheFile() throws {
        let text = "---\nname: ledger-review\ndescription: Old.\nlicense: MIT\n---\n\nCheck.\n"
        var editor = SpaceResourcesModel.editor(.skill, path: ".pi/skills/ledger-review/SKILL.md", text: text)
        #expect(editor.name == "ledger-review" && editor.body == "Check." && editor.automatic)
        editor.description = "Review ledger changes."
        editor.automatic = false
        let (path, written) = try SpaceResourcesModel.text(editor).get()
        #expect(path == ".pi/skills/ledger-review/SKILL.md")
        #expect(written == "---\nname: ledger-review\ndescription: \"Review ledger changes.\"\nlicense: MIT\ndisable-model-invocation: true\n---\n\nCheck.\n")
        #expect(SkillsText.frontmatter(written).disableModelInvocation)
    }

    @Test func aNewSubagentAndCommandAreWrittenAsPiAndShepherdReadThem() throws {
        var agent = SpaceResourcesModel.Editor(kind: .agent)
        agent.name = "ledger-reviewer"; agent.description = "Check ledger invariants."; agent.body = "Inspect ledger changes."
        agent.thinking = "high"
        let (agentPath, agentText) = try SpaceResourcesModel.text(agent).get()
        #expect(agentPath == ".pi/agents/ledger-reviewer.md")
        let profile = SubagentProfileText(agentText)
        #expect(profile.list("tools") == ["read", "grep", "find", "ls"] && profile.scalar("thinking") == "high")
        #expect(profile.scalar("defaultContext") == "fresh" && profile.scalar("systemPromptMode") == "append" && profile.bool("inheritProjectContext") == true)
        var command = SpaceResourcesModel.Editor(kind: .prompt)
        command.name = "review"; command.arguments = "[focus]"; command.body = "Review. Focus on ${1:-correctness}."
        let (commandPath, commandText) = try SpaceResourcesModel.text(command).get()
        #expect(commandPath == ".pi/prompts/review.md")
        #expect(commandText == "---\nargument-hint: \"[focus]\"\n---\n\nReview. Focus on ${1:-correctness}.\n")
    }

    @Test(arguments: [("Bad Name", "body", "d"), ("ok", "  ", "d"), ("ok", "body", "")])
    func theEditorRefusesWhatPiWouldNotLoad(name: String, body: String, description: String) {
        var editor = SpaceResourcesModel.Editor(kind: .skill)
        editor.name = name; editor.body = body; editor.description = description
        guard case .failure = SpaceResourcesModel.text(editor) else { Issue.record("saved an invalid skill"); return }
    }

    @Test func togglesRemovalsAndEditsStayInTheDraftUntilSave() async throws {
        let space = "/code/payments"
        var requests: [RemoteProjectsRequest] = []
        let files: [String: String] = [".pi/prompts/review.md": "Review.\n", ".pi/agents/scout.md": "---\nname: scout\ndescription: Find.\n---\n\nFind.\n"]
        let model = SpaceResourcesModel()
        await model.load(directory: space, settingsPath: ".pi/settings.json") { request in
            requests.append(request)
            switch request {
            case .resources:
                return .resources([ProjectResource(kind: .prompt, path: ".pi/prompts/review.md", text: files[".pi/prompts/review.md"]!),
                                   ProjectResource(kind: .agent, path: ".pi/agents/scout.md", text: files[".pi/agents/scout.md"]!),
                                   ProjectResource(kind: .prompt, name: "explain", path: "/support/pi/prompts/explain.md", global: true)])
            case .read(_, let file):
                return .text(ProjectFileText(file: ProjectFile(path: file, category: .skills, exists: true), text: file.hasSuffix("settings.json") ? "{\"theme\":\"dark\"}" : files[file]))
            default: return .text(ProjectFileText(file: ProjectFile(path: "", category: .skills, exists: true), text: nil))
            }
        }
        model.kind = .prompt
        #expect(model.rows.map(\.displayName) == ["/review", "/explain"])
        #expect(model.spaceCount == 1 && model.inheritedCount == 1)
        await model.toggle(model.rows[0], on: false)
        #expect(!model.rows[0].enabled && model.dirty)
        #expect(SpaceSettingsForm.parse(model.settingsDraft)?["prompts"] as? [String] == ["-prompts/review.md"])
        await model.toggle(model.rows[0], on: true)
        #expect(model.settingsDraft == "{\"theme\":\"dark\"}" && !model.dirty, "turning it back on returns the file's own text")
        model.kind = .agent
        await model.toggle(model.rows[0], on: false)
        #expect(SubagentProfileText(model.writes[".pi/agents/scout.md"]!!).bool("disabled") == true)
        model.kind = .prompt
        await model.askRemove(model.rows[0])
        model.confirmRemove()
        #expect(model.rows.map(\.displayName) == ["/explain"])
        #expect(!requests.contains { if case .save = $0 { true } else if case .delete = $0 { true } else { false } })
        model.scope = .space
        #expect(model.rows.isEmpty)
    }

    /// ProjectChildSkills: the parent's skills list after the space's own, turn off through the host
    /// record, and Override here copies one into the draft, which hides the parent's until Reset.
    @Test func aChildListsItsParentsSkillsAndOverridesOneInTheDraft() async throws {
        let parentText = "---\nname: ledger-review\ndescription: Review ledgers.\n---\n\nCheck.\n"
        var turnedOff: [(String, Bool)] = []
        let model = SpaceResourcesModel()
        model.canExcludeInherited = true
        model.setInherited = { skill, on in turnedOff.append((skill, on)) }
        await model.load(directory: "/code/payments/web", settingsPath: ".pi/settings.json", parent: ("payments", "/code/payments")) { request in
            switch request {
            case .resources("/code/payments"):
                return .resources([ProjectResource(kind: .skill, path: ".pi/skills/ledger-review/SKILL.md", text: parentText),
                                   ProjectResource(kind: .prompt, path: ".pi/prompts/release.md", text: "Release.\n")])
            case .resources:
                return .resources([ProjectResource(kind: .skill, path: ".pi/skills/web-copy/SKILL.md", text: "---\nname: web-copy\ndescription: Copy.\n---\n\nRead.\n"),
                                   ProjectResource(kind: .skill, name: "useful-tests", path: "/support/pi/skills/useful-tests/SKILL.md", global: true)])
            case .read("/code/payments", let file):
                return .text(ProjectFileText(file: ProjectFile(path: file, category: .skills, exists: true), text: parentText))
            case .read(_, let file):
                return .text(ProjectFileText(file: ProjectFile(path: file, category: .skills, exists: false), text: nil))
            default: throw ProjectFileError("unexpected", "Not in this test.")
            }
        }
        #expect(model.rows.map(\.displayName) == ["web-copy", "ledger-review", "useful-tests"], "only skills inherit")
        #expect(model.spaceCount == 1 && model.inheritedCount == 2)
        let inherited = try #require(model.rows.first { $0.inheritedFrom == "payments" })
        #expect(!inherited.local && inherited.canToggle)
        await model.toggle(inherited, on: false)
        #expect(turnedOff.map(\.0) == ["ledger-review"] && turnedOff.map(\.1) == [false] && !model.dirty)
        model.excludedSkills = ["ledger-review"]
        #expect(model.rows.first { $0.inheritedFrom != nil }?.enabled == false)

        await model.overrideInherited(inherited)
        #expect(model.writes[".pi/skills/ledger-review/SKILL.md"] == .some(parentText))
        let override = try #require(model.rows.first { $0.overrides == "payments" })
        #expect(override.local && !model.rows.contains { $0.inheritedFrom != nil })
        await model.resetToInherited(override)
        #expect(!model.dirty && model.rows.contains { $0.inheritedFrom == "payments" })
    }
}

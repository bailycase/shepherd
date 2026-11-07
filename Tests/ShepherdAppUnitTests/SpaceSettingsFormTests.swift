import Foundation
import Testing
@testable import ShepherdApp

@Suite("Space settings form")
struct SpaceSettingsFormTests {
    private let inherited = SpaceSettingsForm.merged(SpaceSettingsForm.piDefaults,
                                                     ["defaultProvider": "anthropic", "defaultModel": "claude-sonnet-4-6", "compaction": ["reserveTokens": 8000]])

    private func row(_ key: String, _ object: [String: Any]) throws -> SpaceSettingsForm.Row {
        try #require(SpaceSettingsForm.groups(object, inherited: inherited, models: []).flatMap(\.rows).first { $0.key == key })
    }

    @Test func editsKeepKeysTheFormDoesNotShow() throws {
        let object = try #require(SpaceSettingsForm.parse(#"{"packages":["npm:demo"],"compaction":{"enabled":false}}"#))
        let row = try row("compaction.reserveTokens", object)
        let next = SpaceSettingsForm.applying(row.key, "4096", control: row.control, to: object, inherited: inherited)
        #expect(next["packages"] as? [String] == ["npm:demo"])
        #expect(SpaceSettingsForm.value("compaction.enabled", in: next) as? Bool == false)
        #expect(SpaceSettingsForm.integer(SpaceSettingsForm.value("compaction.reserveTokens", in: next)) == 4096)
    }

    @Test func resettingTheLastNestedKeyRemovesItsObject() throws {
        let object: [String: Any] = ["retry": ["maxRetries": 5], "shellPath": "/bin/zsh"]
        let next = SpaceSettingsForm.applying("retry.maxRetries", "", control: .stepper, to: object, inherited: inherited)
        #expect(next["retry"] == nil)
        #expect(next["shellPath"] as? String == "/bin/zsh")
    }

    @Test func rowsSayWhereTheirValueComesFrom() throws {
        let object: [String: Any] = ["defaultThinkingLevel": "high", "compaction": ["enabled": false]]
        #expect(try row("defaultThinkingLevel", object).source == "Space override · Global: Medium")
        #expect(try row("compaction.reserveTokens", object).source == "Inherited from Global · Global: 8000")
        #expect(try row("compaction.enabled", object).value == "false")
        #expect(try row("compaction.enabled", object).source == "Space override · Global: On")
        let model = try row("defaultModel", [:])
        #expect(model.source == "Inherited from Global · Global: anthropic/claude-sonnet-4-6")
        #expect(!model.overridden)
    }

    @Test func theModelWritesProviderAndModelTogether() {
        let set = SpaceSettingsForm.applying("defaultModel", "openai/gpt-5", control: .dropdown([]), to: ["other": 1], inherited: inherited)
        #expect(set["defaultProvider"] as? String == "openai" && set["defaultModel"] as? String == "gpt-5")
        let reset = SpaceSettingsForm.applying("defaultModel", "", control: .dropdown([]), to: set, inherited: inherited)
        #expect(reset["defaultProvider"] == nil && reset["defaultModel"] == nil && reset["other"] as? Int == 1)
    }

    @Test func invalidValuesBlockSaving() throws {
        #expect(SpaceSettingsForm.invalid(["compaction": ["reserveTokens": "lots"]]))
        #expect(SpaceSettingsForm.invalid(["shellPath": "zsh"]))
        #expect(SpaceSettingsForm.invalid(["retry": ["maxRetries": true]]))
        #expect(!SpaceSettingsForm.invalid(["shellPath": "/bin/zsh", "retry": ["maxRetries": 0]]))
        #expect(try row("shellPath", ["shellPath": "zsh"]).error == "Use an absolute shell path, such as /bin/zsh.")
    }

    @Test func toolSelectionFollowsPiDeltaLists() {
        #expect(SpaceSettingsForm.resolvedTools(["+grep", "-bash"], base: ["read", "bash"]) == ["read", "grep"])
        #expect(SpaceSettingsForm.resolvedTools(["ls"], base: ["read"]) == ["ls"])
        #expect(SpaceSettingsForm.selectedTools([:], inherited: inherited) == ["read", "bash", "edit", "write"])
        // A space selection starts from the inherited one; a toggle writes a plain list and keeps tools the form doesn't list.
        let space = SpaceSettingsForm.applying("defaultTools", "project", control: .segments([]), to: [:], inherited: inherited)
        #expect(space["defaultTools"] as? [String] == ["read", "bash", "edit", "write"])
        let off = SpaceSettingsForm.toggling("bash", on: false, in: ["defaultTools": ["+codemode"]], inherited: inherited)
        #expect(off["defaultTools"] as? [String] == ["read", "edit", "write", "codemode"])
    }

    @Test func aChildSpaceFollowsItsParentForModelAndThinkingOnly() throws {
        let parent: (name: String, settings: [String: Any]) = ("shepherd", ["defaultProvider": "anthropic", "defaultModel": "claude-opus-4-6"])
        let rows = SpaceSettingsForm.groups(["defaultThinkingLevel": "low"], inherited: inherited, parent: parent, models: []).flatMap(\.rows)
        let model = try #require(rows.first { $0.key == "defaultModel" })
        #expect(model.source == "Inherited from shepherd · shepherd: anthropic/claude-opus-4-6" && model.resetTo == "parent")
        if case .dropdown(let options) = model.control { #expect(options.first?.label == "Follow parent · anthropic/claude-opus-4-6") }
        // The parent sets no thinking level, so thinking follows global; tools and the rest always do.
        let thinking = try #require(rows.first { $0.key == "defaultThinkingLevel" })
        #expect(thinking.source == "Space override · Global: Medium" && thinking.resetTo == "global")
        let tools = try #require(rows.first { $0.key == "defaultTools" })
        #expect(tools.source.hasPrefix("Inherited from Global") && tools.resetTo == "global")
    }

    @Test func onlyAnObjectIsAForm() {
        #expect(SpaceSettingsForm.parse("")?.isEmpty == true)
        #expect(SpaceSettingsForm.parse("[1]") == nil)
        #expect(SpaceSettingsForm.parse("{ broken") == nil)
    }
}

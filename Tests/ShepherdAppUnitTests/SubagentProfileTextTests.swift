import Testing
@testable import ShepherdApp

@Suite("Subagent profile text")
struct SubagentProfileTextTests {
    private static let oracle = """
    ---
    name: oracle
    description: "High-context advisor: checks decisions for drift"
    tools: [read, grep]
    model: anthropic/claude-opus-4-5
    thinking: high
    # keep this comment
    extensions:
      - ./one.ts
    ---

    You are the oracle.

    Keep the contract.
    """

    @Test func readsTheKeysTheFormDraws() {
        let profile = SubagentProfileText(Self.oracle)
        #expect(profile.scalar("name") == "oracle")
        #expect(profile.scalar("description") == "High-context advisor: checks decisions for drift")
        #expect(profile.list("tools") == ["read", "grep"])
        #expect(profile.scalar("model") == "anthropic/claude-opus-4-5")
        #expect(profile.list("extensions") == ["./one.ts"])
        #expect(profile.body == "You are the oracle.\n\nKeep the contract.")
        #expect(profile.scalar("missing") == nil && profile.bool("missing") == nil)
    }

    @Test func aRewriteChangesOnlyItsOwnKeyAndKeepsTheRest() {
        var profile = SubagentProfileText(Self.oracle)
        profile.set("thinking", scalar: "low")
        profile.set("tools", list: ["read", "bash"])
        profile.set("disabled", bool: true)
        #expect(profile.text == Self.oracle
            .replacingOccurrences(of: "thinking: high", with: "thinking: low")
            .replacingOccurrences(of: "tools: [read, grep]", with: "tools: [read, bash]")
            .replacingOccurrences(of: "\n---\n\nYou", with: "\ndisabled: true\n---\n\nYou"))
        #expect(SubagentProfileText(profile.text).body == "You are the oracle.\n\nKeep the contract.")
    }

    @Test func clearingAKeyRemovesItsWholeBlockAndNothingElse() {
        var profile = SubagentProfileText(Self.oracle)
        profile.set("extensions", scalar: nil)
        profile.set("model", scalar: nil)
        #expect(!profile.text.contains("one.ts") && !profile.text.contains("model:"))
        #expect(profile.text.contains("# keep this comment") && profile.text.contains("thinking: high"))
    }

    @Test func textYamlWouldMisreadIsQuotedAndRoundTrips() {
        var profile = SubagentProfileText(Self.oracle)
        for value in ["no", "a: b", "# not a comment", "has \"quotes\"", "true", "- dash", ""] {
            profile.set("description", scalar: value)
            #expect(SubagentProfileText(profile.text).scalar("description") == value, "\(value)")
        }
    }

    @Test func instructionsEditsKeepTheFrontmatterByteForByte() {
        var profile = SubagentProfileText(Self.oracle)
        profile.body = "New instructions.\n"
        #expect(profile.text.hasPrefix(String(Self.oracle.prefix { _ in true }.dropLast("\n\nYou are the oracle.\n\nKeep the contract.".count))))
        #expect(SubagentProfileText(profile.text).body == "New instructions.\n")
    }

    @Test func aFileWithoutFrontmatterGainsOneOnlyWhenAKeyIsSet() {
        var profile = SubagentProfileText("Just instructions.\n")
        #expect(profile.body == "Just instructions.\n" && profile.text == "Just instructions.\n")
        profile.set("name", scalar: "helper")
        #expect(profile.text == "---\nname: helper\n---\n\nJust instructions.\n")
    }

    @Test func blockScalarsAndFlowListsRead() {
        let profile = SubagentProfileText("---\nname: x\ndescription: >\n  First line\n  second line\ntools:\n  - read\n  - ls\nskills: a, b\n---\nBody\n")
        #expect(profile.scalar("description") == "First line second line")
        #expect(profile.list("tools") == ["read", "ls"])
        #expect(profile.list("skills") == ["a", "b"])
    }
}

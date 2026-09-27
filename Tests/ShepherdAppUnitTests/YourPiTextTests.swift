import Testing
import ShepherdSessions
@testable import ShepherdApp

/// What Settings ▸ Pi ▸ From your pi says about what was copied: names and counts, never a value.
@Suite("Sign-in wording")
struct YourPiTextTests {
    /// Settings ▸ Pi ▸ Copied's rows: the instructions file pi picks with its lines and the
    /// others it reads, and names, never paths of Shepherd's home.
    @Test func theCopiedRowsNameWhatCameOver() {
        var survey = YourPiSurvey(folder: "/u/.pi/agent")
        survey.copies = [YourPiCopy(kind: .instructions, name: "AGENTS.md", source: "/u/.pi/agent/AGENTS.md", destination: "AGENTS.md"),
                         YourPiCopy(kind: .instructions, name: "SYSTEM.md", source: "/u/.pi/agent/SYSTEM.md", destination: "SYSTEM.md")]
        survey.instructionLines = 38
        #expect(YourPiText.instructions(survey) == "`AGENTS.md` · 38 lines · `SYSTEM.md` · no `APPEND_SYSTEM.md`")
        #expect(YourPiText.instructions(YourPiSurvey()) == "None copied: your pi has no `AGENTS.md` or `CLAUDE.md`.")
        let prompts = (1...8).map { YourPiCopy(kind: .prompts, name: "p\($0)", source: "/p\($0).md", destination: "prompts/p\($0).md") }
        #expect(YourPiText.names(Array(prompts.prefix(2)), prefix: "/", none: "") == "`/p1` `/p2`")
        #expect(YourPiText.names(prompts, prefix: "/", none: "") == "`/p1` `/p2` `/p3` `/p4` `/p5` `/p6` and 2 more")
        #expect(YourPiText.skills([]) == "None copied.")
        let file = YourPiExtensionRow(copy: YourPiCopy(kind: .extensions, name: "gate", source: "/u/.pi/agent/extensions/gate.ts",
                                                       destination: "your-extensions/files/gate.ts"), on: true, summary: "Blocks force-pushes.")
        #expect(YourPiText.extensionPath(file) == "extensions/gate.ts")
        let folder = YourPiExtensionRow(copy: YourPiCopy(kind: .extensions, name: "web-search", source: "/u/.pi/agent/extensions/web-search",
                                                         destination: "your-extensions/files/web-search"))
        #expect(YourPiText.extensionPath(folder) == "extensions/web-search/")
        let package = YourPiExtensionRow(copy: YourPiCopy(kind: .extensions, name: "@acme/tools", source: "npm:@acme/tools@1.0.0",
                                                          destination: "your-extensions/npm/node_modules/@acme/tools"))
        #expect(YourPiText.extensionPath(package) == "npm:@acme/tools@1.0.0")
    }
}

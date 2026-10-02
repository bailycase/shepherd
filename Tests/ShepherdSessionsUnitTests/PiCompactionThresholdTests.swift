import Foundation
import ShepherdTestKit
import Testing
@testable import ShepherdSessions

/// Settings ▸ Agents ▸ Compact at, as it reaches pi: a share of each model's window written as the
/// per-model `compaction.modelOverrides` pi reads, in settings.json (a file format, so a scratch
/// file is fine), and taken back exactly. The window and the share are the Context card's mark.
@Suite("Compact at")
struct PiCompactionThresholdTests {
    static let engine = PiHomeTests.engine

    private func scratchHome() throws -> PiHome {
        PiHome(directory: try makeScratchDirectory(), engine: Self.engine)
    }

    private func settings(_ home: PiHome) throws -> [String: Any] {
        let data = try Data(contentsOf: home.settings)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func reserve(_ settings: [String: Any], _ model: String) -> Int? {
        let overrides = (settings["compaction"] as? [String: Any])?["modelOverrides"] as? [String: Any]
        return ((overrides?[model] as? [String: Any])?["reserveTokens"] as? NSNumber)?.intValue
    }

    /// pi compacts past `window - reserveTokens`, and a share never leaves less room for a reply than
    /// pi's own 16,384: so a share of a small window cannot compact later than pi would.
    @Test(arguments: [
        (272_000, 90, 27_200), (272_000, 80, 54_400), (272_000, 70, 81_600), (272_000, 60, 108_800),
        (1_000_000, 90, 100_000), (200_000, 90, 20_000), (128_000, 90, 16_384), (64_000, 80, 16_384),
    ])
    func aShareBecomesTheTokensLeftFree(window: Int, percent: Int, reserve: Int) {
        #expect(PiCompactionThreshold.reserveTokens(window: window, percent: percent) == reserve)
        #expect(PiCompactionThreshold.compactsAt(window: window, percent: percent) == window - reserve)
    }

    @Test func piDefaultCompactsWhereTheDefaultReserveSays() {
        #expect(PiCompactionThreshold.compactsAt(window: 272_000, percent: nil) == 255_616)
    }

    @Test func theChoicesAreTheSharesSettingsOffers() {
        #expect(PiCompactionThreshold.choices == [60, 70, 80, 90])
    }

    /// Each model of the catalog gets its own reserve, what pi reads for the Context card's mark too.
    @Test func aShareIsWrittenForEveryModelWithItsWindow() throws {
        let home = try scratchHome()
        try PiCompactionThreshold.apply(percent: 80, windows: ["openai/gpt-6": 272_000, "anthropic/claude": 200_000], in: home)
        let written = try settings(home)
        #expect(reserve(written, "openai/gpt-6") == 54_400)
        #expect(reserve(written, "anthropic/claude") == 40_000)
        #expect(PiCompactionThreshold.written(in: home) == 80)
        #expect(PiConfig.compactionSettings(model: "openai/gpt-6", cwd: nil, in: home.directory).reserveTokens == 54_400,
                "pi's settings, as the Context card reads them, say the same")
        #expect(PiConfig.compactionSettings(model: "other/model", cwd: nil, in: home.directory).reserveTokens == 16_384, "a model without a window keeps pi's default")
    }

    @Test func otherKeysOfTheFileAndTheKeysNextToOursStayAndTheFileStaysPrivate() throws {
        let home = try scratchHome()
        let existing: [String: Any] = ["defaultModel": "m", "compaction": ["enabled": true, "keepRecentTokens": 5000,
                                                                          "modelOverrides": ["x/y": ["keepRecentTokens": 1000]]]]
        try JSONSerialization.data(withJSONObject: existing).write(to: home.settings)
        try PiCompactionThreshold.apply(percent: 70, windows: ["x/y": 100_000, "a/b": 100_000], in: home)
        var written = try settings(home)
        #expect(written["defaultModel"] as? String == "m")
        let compaction = try #require(written["compaction"] as? [String: Any])
        #expect(compaction["enabled"] as? Bool == true && (compaction["keepRecentTokens"] as? NSNumber)?.intValue == 5000)
        #expect(reserve(written, "x/y") == 30_000)
        let overrides = try #require(compaction["modelOverrides"] as? [String: Any])
        #expect(((overrides["x/y"] as? [String: Any])?["keepRecentTokens"] as? NSNumber)?.intValue == 1000, "an override's other fields stay")
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: home.settings.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)

        try PiCompactionThreshold.apply(percent: nil, windows: ["x/y": 100_000, "a/b": 100_000], in: home)
        written = try settings(home)
        #expect(reserve(written, "x/y") == nil && reserve(written, "a/b") == nil, "pi's default takes back what was written")
        let after = try #require(written["compaction"] as? [String: Any])
        let remaining = try #require((after["modelOverrides"] as? [String: Any])?["x/y"] as? [String: Any])
        #expect(remaining.count == 1 && (remaining["keepRecentTokens"] as? NSNumber)?.intValue == 1000, "and nothing else")
        #expect(PiCompactionThreshold.written(in: home) == nil)
        #expect(!FileManager.default.fileExists(atPath: home.directory.appendingPathComponent(PiCompactionThreshold.sidecarName).path))
    }

    /// A model whose entry holds a reserve Shepherd did not write is the user's: not overwritten, not removed.
    @Test func aReserveTheUserSetIsLeftAlone() throws {
        let home = try scratchHome()
        let existing: [String: Any] = ["compaction": ["modelOverrides": ["mine/model": ["reserveTokens": 50_000]]]]
        try JSONSerialization.data(withJSONObject: existing).write(to: home.settings)
        try PiCompactionThreshold.apply(percent: 90, windows: ["mine/model": 272_000, "other/model": 272_000], in: home)
        #expect(reserve(try settings(home), "mine/model") == 50_000)
        #expect(reserve(try settings(home), "other/model") == 27_200)
        try PiCompactionThreshold.apply(percent: nil, windows: [:], in: home)
        #expect(reserve(try settings(home), "mine/model") == 50_000, "taking Shepherd's back leaves theirs")
        #expect(reserve(try settings(home), "other/model") == nil)
    }

    /// Changing the share rewrites what Shepherd wrote; a model that left the catalog is taken back.
    @Test func aNewShareReplacesTheOldOneAndAModelThatLeftTheCatalogIsTakenBack() throws {
        let home = try scratchHome()
        try PiCompactionThreshold.apply(percent: 90, windows: ["a/one": 272_000, "a/two": 272_000], in: home)
        try PiCompactionThreshold.apply(percent: 60, windows: ["a/one": 272_000], in: home)
        let written = try settings(home)
        #expect(reserve(written, "a/one") == 108_800)
        #expect(reserve(written, "a/two") == nil)
        #expect(PiCompactionThreshold.written(in: home) == 60)
    }

    @Test func writingTheSameShareTwiceChangesNothing() throws {
        let home = try scratchHome()
        try PiCompactionThreshold.apply(percent: 80, windows: ["a/one": 272_000], in: home)
        let first = try Data(contentsOf: home.settings)
        try PiCompactionThreshold.apply(percent: 80, windows: ["a/one": 272_000], in: home)
        #expect(try Data(contentsOf: home.settings) == first)
    }

    @Test func aSettingsFileThatIsNotAnObjectIsLeftAsItIs() throws {
        let home = try scratchHome()
        try Data("[1, 2]".utf8).write(to: home.settings)
        try PiCompactionThreshold.apply(percent: 80, windows: ["a/one": 272_000], in: home)
        #expect(try String(contentsOf: home.settings, encoding: .utf8) == "[1, 2]")
    }
}

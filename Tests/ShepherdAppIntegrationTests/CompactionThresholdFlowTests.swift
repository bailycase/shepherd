import Foundation
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Settings ▸ Agents ▸ Compact at, from the setting to the file pi reads: the view model asks the
/// stub engine for its catalog, and writes each model's reserve into Shepherd's pi home. The
/// controls themselves are pressed in `AgentSettingsContextTests`.
@Suite("Compact at, written for pi", .mainActorExclusive, .integrationTimeLimit)
@MainActor
struct CompactionThresholdFlowTests {
    /// A pi home of its own: the process-wide scratch home is shared with every harness that starts a view model,
    /// and each of those puts pi's default back at launch when no share is chosen.
    private static func privateSetup() throws -> (dir: URL, pi: PiSetup) {
        let dir = try makeScratchDirectory("compact")
        let user = dir.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let pi = PiSetup(engine: PiSetup.app.engine, home: dir.appendingPathComponent("support/pi", isDirectory: true),
                         yourPi: YourPiLocator(.fixed(nil)), userHome: user.path)
        return (dir, pi)
    }

    private static func reserve(_ model: String, in home: PiHome) -> Int? {
        guard let data = try? Data(contentsOf: home.settings),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let overrides = (settings["compaction"] as? [String: Any])?["modelOverrides"] as? [String: Any] else { return nil }
        return ((overrides[model] as? [String: Any])?["reserveTokens"] as? NSNumber)?.intValue
    }

    /// The stub's catalog has a 200k window (anthropic/claude-opus-4-5) and a 400k one (openai/gpt-5).
    @Test func aShareReachesPisSettingsForEveryModelAndPisDefaultTakesItBack() async throws {
        try StubPi.installAsEngine()
        let (dir, pi) = try Self.privateSetup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try AppHarness(pi: pi)
        defer { app.stop() }
        try await app.start()
        let home = app.server.pi.files

        app.settings.compactAtPercent = 80
        try await eventuallyAsync("each model's reserve in pi's settings") { Self.reserve("openai/gpt-5", in: home) != nil }
        #expect(Self.reserve("anthropic/claude-opus-4-5", in: home) == 40_000)
        #expect(Self.reserve("openai/gpt-5", in: home) == 80_000)
        #expect(PiConfig.compactionSettings(model: "openai/gpt-5", cwd: nil, in: home.directory).reserveTokens == 80_000,
                "the Context card's mark reads what pi will use")
        #expect(PiCompactionThreshold.written(in: home) == 80)

        app.settings.compactAtPercent = 60
        try await eventuallyAsync("the new share") { Self.reserve("openai/gpt-5", in: home) == 160_000 }
        #expect(Self.reserve("anthropic/claude-opus-4-5", in: home) == 80_000)

        app.settings.compactAtPercent = nil
        try await eventuallyAsync("pi's default back") { Self.reserve("openai/gpt-5", in: home) == nil }
        #expect(Self.reserve("anthropic/claude-opus-4-5", in: home) == nil)
        #expect(PiCompactionThreshold.written(in: home) == nil)
    }

    /// A launch with a share chosen covers a model added since: the view model writes it again at start.
    @Test func aShareChosenEarlierIsWrittenAgainAtStart() async throws {
        try StubPi.installAsEngine()
        let (dir, pi) = try Self.privateSetup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try AppHarness(pi: pi)
        defer { app.stop() }
        app.settings.compactAtPercent = 90
        try await app.start()
        let home = app.server.pi.files
        try await eventuallyAsync("the share at start") { Self.reserve("openai/gpt-5", in: home) == 40_000 }
    }
}

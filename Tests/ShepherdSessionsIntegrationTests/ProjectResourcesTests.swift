import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

/// The Resources tab's host side: a space's resources and the host's global ones, a new resource
/// file saved through the allowlist, a removal fenced on the text read, and skills copied into the
/// space from a repository, against a real server and real git.
@Suite("Project resources", .integrationTimeLimit)
struct ProjectResourcesTests {
    @Test func listsSavesRemovesAndInstallsSpaceResources() async throws {
        let root = try makeScratchDirectory("resources"), fm = FileManager.default
        let support = root.appendingPathComponent("support")
        let home = root.appendingPathComponent("home")
        let space = home.appendingPathComponent("code/payments")
        let pi = PiSetup(engine: PiSetup.app.engine, home: support.appendingPathComponent("pi"), userHome: home.path)
        func write(_ base: URL, _ path: String, _ text: String) throws {
            let url = base.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write(space, ".pi/skills/ledger-review/SKILL.md", "---\nname: ledger-review\ndescription: Review ledgers.\n---\n\nCheck.\n")
        try write(space, ".pi/extensions/outbox-guard.ts", "// Check ledger writes before tools run.\nexport default function () {}\n")
        try write(pi.home, "skills/useful-tests/SKILL.md", "---\nname: useful-tests\ndescription: Choose stable tests.\n---\n\nTest.\n")
        try write(pi.home, "prompts/explain.md", "---\ndescription: Explain code.\n---\nExplain $@.\n")
        try write(pi.home, "settings.json", #"{"prompts":["-prompts/explain.md"]}"#)
        let host = try ScratchServer(dir: support, pi: pi)
        defer { host.stop(); try? fm.removeItem(at: root) }
        let state = ShepherdState(spaces: [Space(name: "payments", path: space.path)])
        let projects = host.server.projects
        let directory = space.resolvingSymlinksInPath().path
        func resources() async throws -> [ProjectResource] {
            guard case .resources(let list) = try await projects.request(.resources(directory: directory), state: state) else { throw ProjectFileError("protocol", "") }
            return list
        }
        var list = try await resources()
        #expect(list.filter { !$0.global }.map(\.path) == [".pi/skills/ledger-review/SKILL.md", ".pi/extensions/outbox-guard.ts"])
        #expect(list.first { $0.kind == .extension }?.description == "Check ledger writes before tools run.")
        let explain = try #require(list.first { $0.name == "explain" })
        #expect(explain.global && !explain.enabled, "the global settings' exclusion turns it off")
        #expect(list.contains { $0.global && $0.name == "useful-tests" && $0.enabled })

        // A new prompt template and subagent pass the allowlist; nothing outside the resource shapes does.
        _ = try await projects.request(.save(directory: directory, file: ".pi/prompts/review.md", text: "Review.\n", expected: nil), state: state)
        _ = try await projects.request(.save(directory: directory, file: ".pi/agents/ledger-reviewer.md",
                                             text: "---\nname: ledger-reviewer\ndescription: Check.\n---\n\nCheck.\n", expected: nil), state: state)
        await #expect(throws: ProjectFileError.self) {
            _ = try await projects.request(.save(directory: directory, file: ".pi/prompts/nested/x.md", text: "x", expected: nil), state: state)
        }
        list = try await resources()
        #expect(list.contains { $0.kind == .prompt && $0.name == "review" && !$0.global })
        #expect(list.contains { $0.kind == .agent && $0.name == "ledger-reviewer" && !$0.global })

        // Removal is fenced on the text the client read; a skill's emptied folder goes too.
        await #expect(throws: ProjectFileError.self) {
            _ = try await projects.request(.delete(directory: directory, file: ".pi/prompts/review.md", expected: "stale"), state: state)
        }
        _ = try await projects.request(.delete(directory: directory, file: ".pi/prompts/review.md", expected: "Review.\n"), state: state)
        _ = try await projects.request(.delete(directory: directory, file: ".pi/skills/ledger-review/SKILL.md",
                                               expected: "---\nname: ledger-review\ndescription: Review ledgers.\n---\n\nCheck.\n"), state: state)
        #expect(!fm.fileExists(atPath: space.appendingPathComponent(".pi/prompts/review.md").path))
        #expect(!fm.fileExists(atPath: space.appendingPathComponent(".pi/skills/ledger-review").path))
        await #expect(throws: ProjectFileError.self) {
            _ = try await projects.request(.delete(directory: directory, file: ".pi/settings.json", expected: ""), state: state)
        }

        // Add from repo copies the whole skill folder into the space, never into the host's own skills.
        let repo = try makeScratchRepo(files: ["skills/refund-checks/SKILL.md": "---\nname: refund-checks\ndescription: Check refunds.\n---\n\nCheck.\n",
                                               "skills/refund-checks/scripts/run.sh": "echo ok\n"])
        _ = try await projects.request(.installSkills(directory: directory, repo: "file://" + repo.path, paths: ["skills/refund-checks"], commit: nil), state: state)
        #expect(fm.fileExists(atPath: space.appendingPathComponent(".pi/skills/refund-checks/scripts/run.sh").path))
        #expect(!fm.fileExists(atPath: pi.home.appendingPathComponent("skills/refund-checks").path))
        #expect(try await resources().contains { $0.name == "refund-checks" && !$0.global })
        await #expect(throws: (any Error).self, "a skill already in the space is refused") {
            _ = try await projects.request(.installSkills(directory: directory, repo: "file://" + repo.path, paths: ["skills/refund-checks"], commit: nil), state: state)
        }
    }
}

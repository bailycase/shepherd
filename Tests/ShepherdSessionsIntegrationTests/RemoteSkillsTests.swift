import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Settings ▸ Skills over the listener: a client reads the host's skills, looks up a repository,
/// installs from it on the host, turns a skill off and removes it with undo, and the host's GUI
/// hears about every change a client makes (and nothing else).
@Suite("Remote skills", .integrationTimeLimit)
struct RemoteSkillsTests {
    static func repository() throws -> URL {
        try makeScratchRepo(files: [
            "skills/pdf/SKILL.md": "---\nname: pdf\ndescription: Read, fill, merge and split PDFs.\n---\n# PDF\n",
            "skills/docx/SKILL.md": "---\nname: docx\ndescription: Create and edit Word documents.\n---\n# Word\n",
        ])
    }

    @Test func aClientInstallsTurnsOffAndRemovesTheHostsSkills() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let heard = Locked<[SkillsSnapshot]>([])
        host.server.onSkillsChanged = { snapshot in heard.withValue { $0.append(snapshot) } }
        let client = try await host.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.skillsCapability))
        let repo = try "file://" + Self.repository().path

        guard case .skills(let empty) = try await client.skills() else { Issue.record("expected the host's skills"); return }
        #expect(empty.skills.isEmpty)
        #expect(empty.directory.hasSuffix("agent-skills"))

        guard case .repo(let found) = try await client.skills(.lookUp(repo: repo)) else { Issue.record("expected the repository"); return }
        #expect(found.skills.map(\.name) == ["docx", "pdf"])

        guard case .skills(let installed) = try await client.skills(.install(repo: repo, paths: ["skills/pdf"], commit: found.commit,
                                                                          invocation: .slashOnly)) else {
            Issue.record("expected the host's skills")
            return
        }
        #expect(installed.skill("pdf")?.invocation == .slashOnly)
        let onDisk = host.host.dir.appendingPathComponent("agent-skills/pdf/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: onDisk.path))

        guard case .skills(let off) = try await client.skills(.setOn(name: "pdf", on: false)) else { Issue.record("expected skills"); return }
        #expect(off.skill("pdf")?.isOn == false)
        #expect(!FileManager.default.fileExists(atPath: onDisk.path))

        guard case .skills(let removed) = try await client.skills(.remove(name: "pdf")) else { Issue.record("expected skills"); return }
        #expect(removed.skills.isEmpty)
        guard case .skills(let restored) = try await client.skills(.restore(name: "pdf")) else { Issue.record("expected skills"); return }
        #expect(restored.skill("pdf")?.isOn == false)
        #expect(host.server.skills.snapshot() == restored)

        try await eventually("the GUI to hear all four changes") { heard.current.count == 4 }
        #expect(heard.current.last == restored)
    }

    @Test func readingOrLookingUpTellsTheGUINothing() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let heard = Locked<Int>(0)
        host.server.onSkillsChanged = { _ in heard.withValue { $0 += 1 } }
        let client = try await host.typed()
        defer { client.disconnect() }
        let repo = try "file://" + Self.repository().path
        _ = try await client.skills(.fetch)
        _ = try await client.skills(.lookUp(repo: repo))
        // A change afterwards is heard, so the two reads before it weren't.
        _ = try await client.skills(.configure(autoUpdate: true))
        try await eventually("the GUI to hear the change") { heard.current == 1 }
        #expect(heard.current == 1)
    }

    @Test func aSkillTheHostDoesntHaveIsRefused() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let raw = try await host.raw()

        try raw.send(.skills(id: 7, request: .setOn(name: "nothing", on: false)))

        guard case .error(7, let code, _) = try await raw.next() else { Issue.record("expected an error"); return }
        #expect(code == "no_such_skill")
    }
}

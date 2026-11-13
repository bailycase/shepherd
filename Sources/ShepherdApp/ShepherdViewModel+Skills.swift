import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

extension ShepherdViewModel {
    /// This Mac among Settings ▸ Skills' hosts.
    static let thisMacSkills = UUID(uuidString: "5E0A5C11-0000-4000-8000-00000000AC00")!

    /// Settings ▸ Skills' hosts: This Mac first, then every remote host in the sidebar's order. The
    /// page edits the first that is connected; the fleet carries a change to the others.
    var skillsHosts: [SkillsHost] {
        // This Mac's skills are the host's (offline while it is away).
        let thisMac: (any SkillsClient)? = localHost?.skillsClient
        return [SkillsHost(id: Self.thisMacSkills, name: "This Mac", client: thisMac, serves: true)]
            + remoteHosts.connections.map { connection in
                let connected = connection.skillsClient
                return SkillsHost(id: connection.id, name: connection.config.name, client: connected,
                                  serves: connected == nil || connection.supportsSkills)
            }
    }

    /// A remote host connected: the Skills page reads it afresh if it is the one it edits.
    func skillsHostConnected(_ hostID: UUID) {
        guard let host = skillsHosts.first(where: { $0.id == hostID }) else { return }
        Task { await skills.hostConnected(host) }
    }

    /// Where This Mac keeps a skill, on or off; nil when it isn't here.
    func skillFolder(_ name: String) -> URL? {
        // The host keeps them in its pi home, and their state in the support directory.
        let state = ShepherdPaths.supportDirectory().appendingPathComponent("skills", isDirectory: true)
        for base in [pi.home.appendingPathComponent("skills", isDirectory: true), state.appendingPathComponent("off", isDirectory: true)] {
            let folder = base.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) { return folder }
        }
        return nil
    }

    /// Opens This Mac's copy of a skill's SKILL.md in the default editor.
    func openSkillFile(_ name: String) {
        guard let folder = skillFolder(name) else { return }
        NSWorkspace.shared.open(folder.appendingPathComponent("SKILL.md"))
    }

    /// Shows This Mac's copy of a skill in Finder.
    func showSkillFolder(_ name: String) {
        guard let folder = skillFolder(name) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: pi's own skills (read-only)

    /// Shows the skills folder of the user's own pi on This Mac in Finder (its folder when it has
    /// none, Shepherd's pi home when there is no pi of theirs).
    func showPiSkillsFolder() {
        let pi = self.pi
        Task {
            let agent = await Task.detached(priority: .userInitiated) { pi.yourPi.resolve()?.agentDirectory }.value ?? pi.home
            let skills = agent.appendingPathComponent("skills", isDirectory: true)
            let target = FileManager.default.fileExists(atPath: skills.path) ? skills : agent
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    /// Opens one of This Mac's pi skills' SKILL.md (`path` as the page shows it, with `~`).
    func openPiSkillFile(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Shows one of This Mac's pi skills in Finder.
    func showPiSkillFile(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

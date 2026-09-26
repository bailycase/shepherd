import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// This Mac's skills as Settings ▸ Skills reaches them: the server's store, off the main thread
/// (installing fetches from git). A refusal reads as a host's does.
final class LocalSkillsClient: SkillsClient, @unchecked Sendable {
    let store: SkillsStore
    private let queue = DispatchQueue(label: "shepherd.skills.local", qos: .userInitiated)

    init(store: SkillsStore) {
        self.store = store
    }

    func skills(_ request: RemoteSkillsRequest) async throws -> RemoteSkillsResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [store] in
                do {
                    continuation.resume(returning: try store.perform(request))
                } catch let error as SkillsStore.StoreError {
                    continuation.resume(throwing: RemoteHostClientError.rejected(code: error.code, message: error.description))
                } catch {
                    continuation.resume(throwing: RemoteHostClientError.rejected(code: "write_failed", message: error.localizedDescription))
                }
            }
        }
    }
}

extension ShepherdViewModel {
    /// This Mac among Settings ▸ Skills' hosts.
    static let thisMacSkills = UUID(uuidString: "5E0A5C11-0000-4000-8000-00000000AC00")!

    /// Settings ▸ Skills' hosts: This Mac first, then every remote host in the sidebar's order.
    var skillsHosts: [SkillsHost] {
        [SkillsHost(id: Self.thisMacSkills, name: "This Mac", client: localSkills, serves: true)]
            + remoteHosts.connections.map { connection in
                let connected = connection.skillsClient
                return SkillsHost(id: connection.id, name: connection.config.name, client: connected,
                                  serves: connected == nil || connection.supportsSkills)
            }
    }

    /// A remote host connected: it takes the skill changes it is owed.
    func skillsHostConnected(_ hostID: UUID) {
        guard let host = skillsHosts.first(where: { $0.id == hostID }) else { return }
        Task { await skills.hostConnected(host) }
    }

    /// This Mac looks for newer commits of its skills a minute after launch, then every hour
    /// once its last check is a day old (installing them with Update automatically on).
    func startSkillChecks() {
        guard skillChecks == nil else { return }
        let store = server.skills
        skillChecks = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                let checked = await Task.detached(priority: .utility) { store.checkUpdatesIfDue() }.value
                if let checked { self?.skills.hostChanged(Self.thisMacSkills, checked) }
                try? await Task.sleep(for: .seconds(3_600))
            }
        }
    }

    /// Where This Mac keeps a skill, on or off; nil when it isn't here.
    func skillFolder(_ name: String) -> URL? {
        let store = server.skills
        for base in [store.directory, store.stateDirectory.appendingPathComponent("off", isDirectory: true)] {
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

    /// Shows the skills folder of This Mac's pi in Finder (its agent directory when it has none).
    func showPiSkillsFolder() {
        let agent = server.pi.home
        let skills = agent.appendingPathComponent("skills", isDirectory: true)
        let target = FileManager.default.fileExists(atPath: skills.path) ? skills : agent
        NSWorkspace.shared.activateFileViewerSelecting([target])
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

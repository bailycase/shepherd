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
                let connected = connection.phase == .connected ? connection.client : nil
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
}

import Foundation
import ShepherdCore
import ShepherdProtocol

/// What an agent asks of Shepherd's window, on a host with none: `review_diff` and
/// `project_delete`'s confirmation go to the app connected over `host.sock` (`relayToApp`), which
/// answers as it does in process. The other `project_*` tools change only the workspace, so the
/// host answers them itself.
extension SessionServer {
    static let reviewWindowClosed = "Shepherd's window is closed, so nothing is marked yet. The review is in this thread's "
        + "Changes tab when the user opens Shepherd; their review will arrive as a message when they submit. "
        + "Continue only if you have unrelated work."
    static let spaceDeleteWindowClosed = "Removing a space needs Shepherd's window to confirm, and it is closed. "
        + "Open Shepherd and try again."

    /// Installs the review and project handlers. Once per server, by the background host.
    @MainActor
    public func relayWindowRequestsToApp() {
        onReviewRequest = { [weak self] request, respond in
            guard case .start(let agentID, let cwd, let reference) = request else { return }
            guard let self else { return respond(.failed(code: "unavailable", message: "host is shutting down")) }
            relayToApp(.review(agentID: agentID, cwd: cwd, reference: reference)) { result in
                switch result {
                case .done(let text)?: respond(.submitted(text: text))
                case .failed(let code, let message)?: respond(.failed(code: code, message: message))
                case .hostUpdate?: respond(.failed(code: "protocol", message: "unexpected answer"))
                case nil:
                    guard self.state.agents.contains(where: { $0.id == agentID }) else {
                        return respond(.failed(code: "no_such_agent", message: "unknown agent \(agentID)"))
                    }
                    respond(.submitted(text: Self.reviewWindowClosed))
                }
            }
        }
        // A paired device's Update this Mac: Sparkle runs in this Mac's app, which asks the host
        // before it reserves or restarts (`hostUpdateGate`). With no app, nothing can install.
        onRemoteHostUpdate = { [weak self] request, authorized, completion in
            guard let self else { return }
            Task {
                guard await authorized() else { return }
                self.relayToApp(.hostUpdate(request: request)) { result in
                    guard case .hostUpdate(let status)? = result else { return completion(self.hostUpdateWithoutApp) }
                    completion(status)
                }
            }
        }
        onProjectRequest = { [weak self] request, respond in
            guard let self else { return respond(.failure(ProjectFileError("unavailable", "host is shutting down"))) }
            if case .delete(let id) = request {
                guard let space = state.spaces.first(where: { $0.id == id && !$0.hidden }) else {
                    return respond(.failure(ProjectFileError("no_such_project", "No registered local space has that ID.")))
                }
                return relayToApp(.confirmSpaceDelete(spaceID: id)) { result in
                    switch result {
                    case .done?: respond(.success((space, false)))
                    case .failed(let code, let message)?: respond(.failure(ProjectFileError(code, message)))
                    case .hostUpdate?: respond(.failure(ProjectFileError("protocol", "unexpected answer")))
                    case nil: respond(.failure(ProjectFileError("unavailable", Self.spaceDeleteWindowClosed)))
                    }
                }
            }
            Task { @MainActor in
                do {
                    switch request {
                    case .register(let path, let name):
                        let registered = try await self.registerProject(path: path, name: name)
                        respond(.success((registered.space, registered.created)))
                    case .edit(let id, let edit):
                        respond(.success((try await self.editProject(id, edit: edit), edit.folderAction == .copy)))
                    case .child(let parentPath, let path, let name, let create):
                        let registered = try await self.addChildProject(parentPath: parentPath, path: path, name: name, create: create)
                        respond(.success((registered.space, registered.created)))
                    case .refresh, .delete:
                        // The connected app adopts each change as the host pushes it.
                        respond(.success((nil, false)))
                    }
                } catch let error as ProjectFileError {
                    respond(.failure(error))
                } catch {
                    respond(.failure(ProjectFileError("failed", String(describing: error))))
                }
            }
        }
    }

    /// What a paired device's Update this Mac reads while no app is connected to install it.
    var hostUpdateWithoutApp: HostUpdateStatus {
        let info = Bundle.main.infoDictionary
        var status = HostUpdateStatus(version: info?["CFBundleShortVersionString"] as? String ?? "", build: hostBuild ?? "",
                                      channel: "", phase: .unsupported)
        status.error = Self.hostUpdateWindowClosed
        return status
    }

    static let hostUpdateWindowClosed = "Open Shepherd on this Mac to update it."
}

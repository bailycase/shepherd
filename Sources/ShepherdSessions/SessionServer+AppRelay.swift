import Foundation
import ShepherdCore
import ShepherdProtocol

/// What an agent asks of Shepherd's window, on a host with none: `review_diff` and
/// `project_delete`'s confirmation go to the app connected over `host.sock` (`relayToApp`), which
/// answers. The other `project_*` tools change only the workspace, so the
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
                case .hostUpdate?, .projectExecution?, .nativeThread?: respond(.failed(code: "protocol", message: "unexpected answer"))
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
                    case .hostUpdate?, .projectExecution?, .nativeThread?: respond(.failure(ProjectFileError("protocol", "unexpected answer")))
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

/// A background host has no connections to paired Macs: this Mac's own app does. While the app is
/// connected it says which paired Macs it reaches (`ProjectExecutorsUpdate`), and the host's
/// Projects place work there through it (`AppRelayJob.projectPlacement`). With the app quit, placing on another Mac says to open it.
extension SessionServer {
    /// Why a Project the host owns can't reach another Mac right now.
    public static let appClosedForPlacement = "Open Shepherd on this Mac to place work on another Mac."

    /// Projects on this server place work on other Macs only through this Mac's app (`Shepherd --host`).
    public func relayProjectPlacementThroughApp() {
        queue.async { self.projectPlacementThroughApp = true }
    }

    /// The paired Macs the app last said it reaches; none without the app.
    public func appProjectExecutors() async -> [ProjectHostOption] {
        (try? await enqueue { self.appRelayConnected ? self.appExecutors : [] }) ?? []
    }

    /// Server queue: a local app's `projectExecutors`.
    func applyProjectExecutors(_ update: ProjectExecutorsUpdate) {
        switch update {
        case .hosts(let options):
            appExecutors = options
            setProjectEligibleHosts([.local] + options.map(\.reference))
            setProjectExecutionSpaces(Dictionary(options.compactMap { option in option.spaces.map { (option.reference, $0) } },
                                                 uniquingKeysWith: { first, _ in first }))
        case .changed(let host, let key):
            reconcileProjectExecutions(host: host, key: key)
        }
    }

    /// Server queue: the app left; what it reached is gone with it.
    func appExecutorsLeft() {
        guard !appRelayConnected, !appExecutors.isEmpty else { return }
        applyProjectExecutors(.hosts([]))
    }
}

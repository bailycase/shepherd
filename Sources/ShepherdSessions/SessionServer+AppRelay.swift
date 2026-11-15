import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol

/// What an agent asks of Shepherd's window, on a host with none: `review_diff`,
/// `project_delete`'s confirmation and a claimed browser page's address go to the app connected over `host.sock` (`relayToApp`), which
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
        // A paired viewer claims an agent's browser: the page, and so its address, is the app's.
        onBrowserPageURL = { [weak self] agentID, answer in
            guard let self else { return answer(nil) }
            relayToApp(.browserPageURL(agentID: agentID)) { result in
                if case .done(let url)? = result { answer(url) } else { answer(nil) }
            }
        }
        // A paired device's or Mac's Update this Mac: Sparkle runs in this Mac's app, which asks the host
        // before it reserves or restarts (`hostUpdateGate`). With no app open the host opens it for a request that needs it.
        if openAppForUpdate == nil { openAppForUpdate = Self.openOwnApp }
        onRemoteHostUpdate = { [weak self] request, authorized, completion in
            guard let self else { return }
            Task {
                guard await authorized() else { return }
                completion(await self.relayHostUpdate(request))
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

    /// The app's answer to `request`. A request that needs the updater to run (a check, an install) with no app connected opens this Mac's own
    /// Shepherd and waits a few seconds for it to connect; a status or a cancel is answered at once. With no app, or one that doesn't
    /// answer, the status says to open Shepherd on this Mac.
    func relayHostUpdate(_ request: RemoteHostUpdateRequest) async -> HostUpdateStatus {
        func relay() async -> HostUpdateStatus? {
            await withCheckedContinuation { continuation in
                relayToApp(.hostUpdate(request: request)) { result in
                    if case .hostUpdate(let status)? = result { continuation.resume(returning: status) } else { continuation.resume(returning: nil) }
                }
            }
        }
        if let status = await relay() { return status }
        switch request {
        case .status, .cancel: return hostUpdateWithoutApp
        case .check, .install, .installWhenIdle: break
        }
        guard await openApp() else { return hostUpdateWithoutApp }
        return await relay() ?? hostUpdateWithoutApp
    }

    /// Opens this Mac's own Shepherd (once in a while) and waits for it to connect over `host.sock`. False when it can't be opened or doesn't connect in time.
    private func openApp() async -> Bool {
        guard let open = openAppForUpdate else { return false }
        let launch = (try? await enqueue { () -> Bool in
            guard !self.appRelayConnected else { return false }
            // One launch at a time: a second request while the app is starting only waits.
            if let at = self.appLaunchedAt, Date().timeIntervalSince(at) < 30 { return false }
            self.appLaunchedAt = Date()
            return true
        }) ?? false
        if launch, !(await open()) {
            _ = try? await enqueue { self.appLaunchedAt = nil }
            return false
        }
        let deadline = ContinuousClock.now.advanced(by: appConnectPatience)
        while ContinuousClock.now < deadline {
            if (try? await enqueue { self.appRelayConnected }) == true { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Opens the Shepherd this host belongs to, hidden and without taking focus: Sparkle runs in the app. The host is launchd's job in the person's own
    /// login session (`SMAppService.agent`), so LaunchServices can open an app from it; a host that isn't inside an app bundle opens nothing.
    @Sendable static func openOwnApp() async -> Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        return (try? await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)) != nil
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

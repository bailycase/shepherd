import Foundation
import ShepherdCore

/// What a background host's agent asks of Shepherd's window, which the host doesn't have: the host
/// hands it to the app over `host.sock` (`RemoteReply.appRelay`, only to a local client that lists
/// `RemoteProtocol.appRelayCapability`), and the app answers (`RemoteRequest.appRelayAnswer`).
public enum AppRelayJob: Codable, Hashable, Sendable {
    /// `review_diff`: the thread's Changes tab, marked for the user to open.
    case review(agentID: AgentID, cwd: String?, reference: String?)
    /// `project_delete`: the Remove space confirmation.
    case confirmSpaceDelete(spaceID: SpaceID)
    /// A paired device's Update this Mac (`RemoteRequest.hostUpdate`): Sparkle runs in the app.
    case hostUpdate(request: RemoteHostUpdateRequest)
    /// A Project the host owns places work on a paired Mac, or reads its worker's thread there:
    /// through the app's own connection to exactly that host and binding, never another.
    case projectPlacement(host: ProjectHostReference, request: ProjectExecutionRequest)
    case projectWorkerThread(host: ProjectHostReference, agentID: AgentID, request: NativeThreadRequest)
    /// A paired viewer claims the agent's browser (`RemoteRequest.browserClaim`): the address of
    /// the app's page for it, answered `.done(text:)`; anything else, no address.
    case browserPageURL(agentID: AgentID)
}

/// The app's answer to an `AppRelayJob`: the text the agent is told, or why not.
public enum AppRelayResult: Codable, Hashable, Sendable {
    case done(text: String)
    case failed(code: String, message: String)
    /// The app's update status, for `AppRelayJob.hostUpdate`.
    case hostUpdate(status: HostUpdateStatus)
    /// The paired Mac's answers, for `projectPlacement` and `projectWorkerThread`.
    case projectExecution(result: ProjectExecutionResult)
    case nativeThread(result: NativeThreadResult)
}

/// This Mac's own app tells its background host what it knows of the paired Macs a Project may
/// place work on, since only the app holds connections to them (`RemoteRequest.projectExecutors`).
public enum ProjectExecutorsUpdate: Codable, Hashable, Sendable {
    /// The connected paired hosts, each with its visible Spaces when it takes placements (nil: it doesn't).
    case hosts([ProjectHostOption])
    /// A paired host's execution changed (`key`), or it connected again (nil): its receipts are read again.
    case changed(host: ProjectHostReference, key: ProjectExecutionKey?)
}

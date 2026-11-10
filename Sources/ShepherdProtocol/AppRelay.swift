import Foundation
import ShepherdCore

/// What a background host's agent asks of Shepherd's window, which the host doesn't have: the host
/// hands it to the app over `host.sock` (`RemoteReply.appRelay`, only to a local client that lists
/// `RemoteProtocol.appRelayCapability`), and the app answers (`RemoteRequest.appRelayAnswer`) as
/// it answers the agent in process.
public enum AppRelayJob: Codable, Hashable, Sendable {
    /// `review_diff`: the thread's Changes tab, marked for the user to open.
    case review(agentID: AgentID, cwd: String?, reference: String?)
    /// `project_delete`: the Remove space confirmation.
    case confirmSpaceDelete(spaceID: SpaceID)
    /// A paired device's Update this Mac (`RemoteRequest.hostUpdate`): Sparkle runs in the app.
    case hostUpdate(request: RemoteHostUpdateRequest)
}

/// The app's answer to an `AppRelayJob`: the text the agent is told, or why not.
public enum AppRelayResult: Codable, Hashable, Sendable {
    case done(text: String)
    case failed(code: String, message: String)
    /// The app's update status, for `AppRelayJob.hostUpdate`.
    case hostUpdate(status: HostUpdateStatus)
}

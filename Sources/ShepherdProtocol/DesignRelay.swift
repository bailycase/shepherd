import Foundation

/// Drawing a background host's design off screen, which needs a web view the host doesn't have:
/// the host writes the job to a file and hands its path to the app over `host.sock`
/// (`RemoteReply.designRelay`, only to a local client that lists
/// `RemoteProtocol.designRelayCapability`), and the app answers
/// (`RemoteRequest.designRelayAnswer`). Paths in a job are the host's, which are the app's: both
/// run on this Mac.
public enum DesignRelayJob: Codable, Hashable, Sendable {
    /// `board_render`.
    case render(DesignRenderJob)
    /// `design_export`, written to the job's destination.
    case export(DesignExportJob)
    /// A design reference's copy at send, written to the request's folder.
    case capture(DesignReferenceCaptureRequest)
}

/// The app's answer to a `DesignRelayJob`.
public enum DesignRelayResult: Codable, Hashable, Sendable {
    case rendered(DesignRendered)
    case exported
    case captured(DesignReferenceCaptured)
    case failed(code: String, message: String)
}

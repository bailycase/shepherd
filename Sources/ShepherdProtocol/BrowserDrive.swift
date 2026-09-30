import Foundation
import ShepherdCore

// An agent on another Mac drives the page the viewer sees (docs/browser.md › Remote › The agent
// drives the page you see). A viewer that has a remote thread's Browser tab on screen claims that
// agent's browser on the host; while it owns it, the host hands the agent's `BrowserRequest`s to the
// viewer instead of its own page, and the viewer answers them with the driver the host's own app
// uses. This file is the wire and the host's claim rules, shared by the host's server, the Mac app and
// the iOS client. It knows nothing of sockets or WebKit.

extension RemoteProtocol {
    /// The host lets a viewer claim an agent's browser (`RemoteRequest.browserClaim`), runs the
    /// agent's browser tools on the claiming viewer's page (`BrowserDrivePush.request`, answered with
    /// `RemoteRequest.browserAnswer`), and tells the thread's viewers when its agent opens a page the
    /// host itself shows (`BrowserDrivePush.opened`). A client lists it in `hello` too: the host
    /// pushes drive frames only to a client that says it reads them. A host that offers it also
    /// offers `browserTunnelCapability` (the page the viewer runs loads through a tunnel), and a
    /// viewer claims only where both are offered. An older host lists nothing: its agent drives the
    /// host's own page, and a viewer's tab is a page of its own (docs/browser.md › Remote).
    public static let browserDriveCapability = "browser.drive.v1"
}

/// The numbers the claim rules live by.
public enum BrowserDriveLimits {
    /// Agents one viewer connection may own at once.
    public static let ownersPerViewer = 32
    /// How long a viewer keeps a claim after its tab went out of sight, in seconds: a quick look at
    /// another tab and back keeps the agent's page, leaving it for good gives the agent back its
    /// host's own.
    public static let hiddenGraceSeconds: TimeInterval = 30
    /// The longest page address a host offers a viewer to adopt or to mark the tab with.
    public static let maxURLBytes = 2048
}

/// Why a viewer's ownership ended, in `BrowserDrivePush.ended`.
public enum BrowserDriveEnd {
    /// Another viewer claimed the agent's browser after this one.
    public static let superseded = "superseded"
    /// The viewer did not answer a request in time: the host took the browser back.
    public static let unresponsive = "unresponsive"
    /// The agent no longer exists on the host.
    public static let agentGone = "agent_gone"
    /// The host stopped serving the agent's browser to viewers.
    public static let unsupported = "unsupported"
}

/// The codes a viewer's failures carry that only the drive path has.
public enum BrowserDriveCode {
    /// The viewer that was showing the page left (its tab closed, another viewer took over, or its
    /// connection dropped) before it answered: the agent's next call reaches the host's own page, or
    /// the next viewer's.
    public static let viewerGone = "viewer_gone"
}

/// What the host sends a viewer that listed `RemoteProtocol.browserDriveCapability`.
public enum BrowserDrivePush: Codable, Hashable, Sendable {
    /// Run `request` on the page you show for `agentID` and answer it with `RemoteRequest.browserAnswer`
    /// carrying `token`. Sent only to the viewer that owns the agent's browser.
    case request(token: Int, agentID: AgentID, request: BrowserRequest)
    /// The agent gave its queued requests up (Stop): the ones not yet started must not run.
    case abandoned(agentID: AgentID)
    /// You no longer own `agentID`'s browser (`BrowserDriveEnd`).
    case ended(agentID: AgentID, reason: String)
    /// The user sent the thread a message: the agent has the page back after a take over.
    case handBack(agentID: AgentID)
    /// The agent opened `url` in its own page on the host while no viewer owned its browser: mark
    /// the thread's Browser tab, as the host does for a local thread.
    case opened(agentID: AgentID, url: String)

    private enum CodingKeys: String, CodingKey {
        case type, token, agentID, request, reason, url
    }

    private enum Kind: String, Codable {
        case request, abandoned, ended, handBack, opened
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .request:
            self = .request(token: try c.decode(Int.self, forKey: .token), agentID: try c.decode(AgentID.self, forKey: .agentID),
                            request: try c.decode(BrowserRequest.self, forKey: .request))
        case .abandoned:
            self = .abandoned(agentID: try c.decode(AgentID.self, forKey: .agentID))
        case .ended:
            self = .ended(agentID: try c.decode(AgentID.self, forKey: .agentID), reason: try c.decode(String.self, forKey: .reason))
        case .handBack:
            self = .handBack(agentID: try c.decode(AgentID.self, forKey: .agentID))
        case .opened:
            self = .opened(agentID: try c.decode(AgentID.self, forKey: .agentID), url: try c.decode(String.self, forKey: .url))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .request(let token, let agentID, let request):
            try c.encode(Kind.request, forKey: .type)
            try c.encode(token, forKey: .token)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(request, forKey: .request)
        case .abandoned(let agentID):
            try c.encode(Kind.abandoned, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
        case .ended(let agentID, let reason):
            try c.encode(Kind.ended, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(reason, forKey: .reason)
        case .handBack(let agentID):
            try c.encode(Kind.handBack, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
        case .opened(let agentID, let url):
            try c.encode(Kind.opened, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(url, forKey: .url)
        }
    }

    /// The agent this push is about.
    public var agentID: AgentID {
        switch self {
        case .request(_, let agentID, _), .abandoned(let agentID), .ended(let agentID, _), .handBack(let agentID), .opened(let agentID, _):
            agentID
        }
    }
}

extension BrowserOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, image, code, message
    }

    private enum Kind: String, Codable {
        case result, failure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .result:
            self = .result(text: try c.decode(String.self, forKey: .text), image: try c.decodeIfPresent(BrowserImage.self, forKey: .image))
        case .failure:
            self = .failure(code: try c.decode(String.self, forKey: .code), message: try c.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .result(let text, let image):
            try c.encode(Kind.result, forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(image, forKey: .image)
        case .failure(let code, let message):
            try c.encode(Kind.failure, forKey: .type)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        }
    }

    /// An answer a viewer sent, made safe to hand to the agent: a code that is one short word (a
    /// viewer's own words never become what an agent's tool names as its failure), an image of a
    /// type the agent's model takes, and text and message cut as `reply(id:)` cuts them.
    public var fromViewer: BrowserOutcome {
        switch self {
        case .result(let text, let image):
            let picture = image.flatMap { Self.pictureTypes.contains($0.mimeType.lowercased()) ? $0 : nil }
            return .result(text: text, image: picture)
        case .failure(let code, let message):
            let clean = code.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
            return .failure(code: clean.isEmpty ? "unavailable" : String(clean.prefix(32)), message: message)
        }
    }

    private static let pictureTypes: Set<String> = ["image/jpeg", "image/png"]
}

/// Which viewer owns each agent's browser on a host: at most one per agent, the most recent claim
/// wins. Pure, so the rules are tested without a socket; `Viewer` is whatever names a connection.
public struct BrowserDriveOwners<Viewer: Hashable & Sendable>: Sendable {
    private var owners: [AgentID: Viewer] = [:]

    public init() {}

    /// The viewer that owns `agent`'s browser, if any.
    public func owner(of agent: AgentID) -> Viewer? { owners[agent] }

    /// The agents `viewer` owns.
    public func agents(of viewer: Viewer) -> [AgentID] {
        owners.filter { $0.value == viewer }.map(\.key)
    }

    public var isEmpty: Bool { owners.isEmpty }

    /// Every agent that has an owner.
    public var agents: Set<AgentID> { Set(owners.keys) }

    public enum Claim: Equatable, Sendable {
        /// `viewer` owns it now. `previous` is the other viewer that did, to be told.
        case owned(previous: Viewer?)
        /// `viewer` already owned it.
        case unchanged
        /// `viewer` owns as many agents as one viewer may.
        case tooMany
    }

    /// `viewer` claims `agent`: the most recent claim wins, so another owner is superseded.
    public mutating func claim(_ agent: AgentID, by viewer: Viewer) -> Claim {
        let previous = owners[agent]
        if previous == viewer { return .unchanged }
        guard agents(of: viewer).count < BrowserDriveLimits.ownersPerViewer else { return .tooMany }
        owners[agent] = viewer
        return .owned(previous: previous)
    }

    /// `viewer` lets `agent`'s browser go. False (and nothing changes) when it was not the owner.
    public mutating func release(_ agent: AgentID, by viewer: Viewer) -> Bool {
        guard owners[agent] == viewer else { return false }
        owners.removeValue(forKey: agent)
        return true
    }

    /// `viewer` is gone: the agents it owned, now owned by no one.
    public mutating func drop(viewer: Viewer) -> [AgentID] {
        let held = agents(of: viewer)
        for agent in held { owners.removeValue(forKey: agent) }
        return held
    }

    /// `agent` is gone (or its owner stopped answering): its owner, now none.
    @discardableResult
    public mutating func drop(agent: AgentID) -> Viewer? {
        owners.removeValue(forKey: agent)
    }
}

/// The page address a host offers a viewer (to adopt, or for the tab's tip): `http` or `https`
/// only, at most `BrowserDriveLimits.maxURLBytes`, else nil.
public enum BrowserDriveURL {
    public static func offered(_ url: String?) -> String? {
        guard let url, url.utf8.count <= BrowserDriveLimits.maxURLBytes,
              let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parsed.host?.isEmpty == false else { return nil }
        return url
    }
}

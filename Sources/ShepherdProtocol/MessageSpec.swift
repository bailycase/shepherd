/// What the host requires of a connection before it serves a `RemoteRequest`: one row per
/// `RemoteRequest.Kind`. `SessionServer.authorize` reads it in front of routing. A row holds the
/// checks that need only the connection and the kind; checks that read the payload (a thread's
/// visibility, the 64-thread watch cap, `HostSettingChange.capability`) stay in the route.
///
/// The host does not enforce a capability a row does not name: `RemoteHostClient` refuses a
/// request the host did not advertise before sending it, and that stays the client's check.
public struct MessageSpec: Hashable, Sendable {
    public enum Access: Hashable, Sendable {
        /// Served before `hello`, a limited number of times per connection (`FleetService.unauthenticatedRequestLimit`).
        case beforeHello
        /// Authenticates the connection; every other request waits for it.
        case hello
        /// Any authenticated connection.
        case authenticated
        /// Only this Mac's own app on the local socket; a network client is refused `unsupported`.
        case localOnly(refusal: String)
        /// Only a Mac in the fleet; anyone else is refused `forbidden`.
        case fleetPeer(refusal: String)
        /// This Mac's own app or a paired device; a Mac in the fleet is refused `forbidden`.
        case notFleetPeer(refusal: String)
    }

    /// A capability the host must offer and, when `negotiated`, the client must also have listed in
    /// `hello`. Without it the request is refused `unsupported` with `message`.
    public struct Requirement: Hashable, Sendable {
        public let capability: Capability
        public let negotiated: Bool
        public let message: String

        public static func offered(_ capability: Capability, _ message: String) -> Requirement {
            Requirement(capability: capability, negotiated: false, message: message)
        }

        public static func negotiated(_ capability: Capability, _ message: String) -> Requirement {
            Requirement(capability: capability, negotiated: true, message: message)
        }
    }

    public let access: Access
    public let requires: Requirement?

    init(_ access: Access, requires: Requirement? = nil) {
        self.access = access
        self.requires = requires
    }

    /// A kind without a row has no spec: the host refuses it and never routes it (fail closed). A test
    /// requires a row for every kind; `rows` is a parameter only so a test can look up a missing row.
    public static func spec(for kind: RemoteRequest.Kind, in rows: [RemoteRequest.Kind: MessageSpec]? = nil) -> MessageSpec? {
        (rows ?? table)[kind]
    }

    static let table: [RemoteRequest.Kind: MessageSpec] = [
        .pushRegistration: MessageSpec(.authenticated, requires: .negotiated(.pushNotifications, "Push notifications are unavailable.")),
        .pushUnregister: MessageSpec(.authenticated, requires: .negotiated(.pushNotifications, "Push notifications are unavailable.")),
        .fleetIdentify: MessageSpec(.beforeHello),
        .fleetPair: MessageSpec(.beforeHello),
        .fleetIntroduce: MessageSpec(.authenticated),
        .fleetRevoke: MessageSpec(.authenticated),
        .fleetRead: MessageSpec(.authenticated),
        .fleetAction: MessageSpec(.authenticated),
        .fleetPressure: MessageSpec(.authenticated),
        .fleetReadiness: MessageSpec(.authenticated),
        .fleetPressureNow: MessageSpec(.authenticated),
        .fleetCheck: MessageSpec(.authenticated),
        .fleetCheckNow: MessageSpec(.authenticated),
        .fleetRepoManifest: MessageSpec(.authenticated),
        .fleetSnapshotPart: MessageSpec(.authenticated),
        .fleetBlobPush: MessageSpec(.authenticated),
        .fleetDispatchCreate: MessageSpec(.authenticated),
        .fleetDispatchControl: MessageSpec(.authenticated),
        .fleetDispatchChanged: MessageSpec(.authenticated),
        .fleetDispatchResult: MessageSpec(.authenticated),
        .fleetRoutes: MessageSpec(.authenticated),
        .fleetPeerAnswer: MessageSpec(.fleetPeer(refusal: "Only a Mac in the fleet answers a call.")),
        .fleetSync: MessageSpec(.authenticated),
        .fleetPairDevice: MessageSpec(.beforeHello),
        .fleetSyncDevices: MessageSpec(.authenticated),
        .nativeThread: MessageSpec(.authenticated),
        .nativeThreadSubscribe: MessageSpec(.authenticated, requires: .negotiated(.nativeThreadRevisions, "Watch at most 64 ordinary threads.")),
        .fleetDigest: MessageSpec(.authenticated, requires: .negotiated(.nativeFleetDigest, "Fleet digests require an ordinary thread.")),
        .projectExecution: MessageSpec(.authenticated),
        .hello: MessageSpec(.hello),
        .stateFetch: MessageSpec(.authenticated),
        .attach: MessageSpec(.authenticated),
        .detach: MessageSpec(.authenticated),
        .input: MessageSpec(.authenticated),
        .resize: MessageSpec(.authenticated),
        .paste: MessageSpec(.authenticated),
        .openPane: MessageSpec(.authenticated),
        .closePane: MessageSpec(.authenticated),
        .resizePaneSplit: MessageSpec(.authenticated),
        .listDir: MessageSpec(.authenticated),
        .listModels: MessageSpec(.authenticated),
        .drain: MessageSpec(.localOnly(refusal: "This host doesn't drain on request.")),
        .hostUpdateGate: MessageSpec(.localOnly(refusal: "Only this Mac's app installs this host's updates.")),
        .addSpace: MessageSpec(.authenticated),
        .spaceAction: MessageSpec(.localOnly(refusal: "Only this Mac's own app changes its spaces.")),
        .spaceLifecycle: MessageSpec(.notFleetPeer(refusal: "Only this Mac's own app or a paired device changes its spaces."),
                                     requires: .offered(.spaceLifecycle, "Update Shepherd on the host to manage its spaces from here.")),
        .projectRequest: MessageSpec(.localOnly(refusal: "Only this Mac's own app changes its spaces.")),
        .startThread: MessageSpec(.localOnly(refusal: "Only this Mac's own app starts threads this way.")),
        .focusThread: MessageSpec(.localOnly(refusal: "Only this Mac's own app says what it shows.")),
        .projectExecutors: MessageSpec(.localOnly(refusal: "Only this Mac's own app says which Macs it reaches.")),
        .createAgent: MessageSpec(.authenticated),
        .agentAction: MessageSpec(.authenticated),
        .agentQuery: MessageSpec(.authenticated),
        .upload: MessageSpec(.authenticated),
        .creationOptions: MessageSpec(.authenticated),
        .creationBranches: MessageSpec(.authenticated),
        .automation: MessageSpec(.authenticated),
        .forge: MessageSpec(.authenticated),
        .logicalProjectRuntime: MessageSpec(.authenticated),
        .instructions: MessageSpec(.authenticated),
        .suggestions: MessageSpec(.authenticated),
        .hostSettings: MessageSpec(.authenticated),
        .hostInventory: MessageSpec(.authenticated),
        .hostUpdate: MessageSpec(.authenticated),
        .skills: MessageSpec(.authenticated),
        .projects: MessageSpec(.authenticated),
        .logicalProjects: MessageSpec(.authenticated, requires: .offered(.logicalProjects, "Logical projects are unavailable on this host.")),
        .hostConfig: MessageSpec(.authenticated),
        .hooks: MessageSpec(.authenticated),
        .apps: MessageSpec(.authenticated),
        .design: MessageSpec(.authenticated),
        .tunnel: MessageSpec(.authenticated),
        .browserClaim: MessageSpec(.authenticated),
        .browserRelease: MessageSpec(.authenticated),
        .browserAnswer: MessageSpec(.authenticated),
        .designRelayAnswer: MessageSpec(.authenticated),
        .appRelayAnswer: MessageSpec(.authenticated),
    ]
}

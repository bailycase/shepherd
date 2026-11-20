import Foundation
import ShepherdProtocol

/// A button of the composer's Can't start banner.
public enum NativeStartAction: Hashable, Sendable {
    /// Starts pi again, looking for the conversation it was resuming.
    case retry
    /// Starts pi again without looking for it (`resumedAsNew`).
    case startNewConversation
    /// The Mac's own app asks where the thread's folder went.
    case locateFolder
}

/// A stopped agent's Retry from a phone or tablet: what the host must offer, and the one way to send it.
public enum NativeStartRestart {
    /// Whether a host takes `restartPi` from this client (`RemoteHostClient.agentAction` needs both).
    public static func isOffered(by capabilities: some Collection<String>) -> Bool {
        capabilities.contains(RemoteProtocol.agentActionsCapability) && capabilities.contains(RemoteProtocol.agentRestartCapability)
    }

    /// The thread reads as restarting at once (`NativeStartRestartState`) while the problem stays, and `send` asks the host.
    /// A host that refuses or can't be reached leaves its reason beside the problem, which is fetched again now.
    @MainActor
    public static func perform(_ action: NativeStartAction, store: NativeThreadStore,
                               send: (RemoteAgentAction) async throws -> Void) async {
        guard action != .locateFolder else { return }
        store.restartRequested()
        do {
            try await send(.restartPi(newConversation: action == .startNewConversation))
            store.restartAccepted()
        } catch {
            store.restartRefused("Couldn’t start the agent: \(error.localizedDescription)")
        }
        await store.refresh(fresh: true)
    }
}

/// Where a phone's Retry stands, kept by the thread's store so it outlives the banner's views.
public enum NativeStartRestartState: Equatable, Sendable {
    /// The host is being asked.
    case asking
    /// The host took it: pi is starting, until it serves or stops again.
    case starting
    /// The host refused or couldn't be reached; the problem it didn't fix is still there.
    case failed(String)
}

/// The Can't start banner of a phone or tablet: what it says and offers, from the thread's problem and restart, whether the
/// host takes `restartPi` (`NativeStartRestart.isOffered`) and whether it is connected now.
public struct NativeStartBanner: Equatable, Sendable {
    public var title: String
    public var message: String
    public var actions: [NativeStartAction]
    /// A restart is under way: progress instead of the problem and its buttons.
    public var inProgress: Bool

    public init?(problem: NativeStartProblem?, restart: NativeStartRestartState?, offered: Bool, connected: Bool, host: String) {
        switch restart {
        case .asking?, .starting?:
            self.init(title: "Starting the agent again…", message: "", actions: [], inProgress: true)
        case let restart:
            guard let problem else { return nil }
            // A phone has no sign-in card: the Mac shows it instead of Retry (`hidesNotSignedIn`), so the advice says to sign in on the host.
            let retryHere = offered && connected && problem.kind != .notSignedIn
            var message = problem.message(host: host, retryHere: retryHere)
            if case .failed(let why)? = restart { message += "\n\n" + why }
            self.init(title: problem.title, message: message, actions: problem.actions(canRestart: retryHere, canLocateFolder: false), inProgress: false)
        }
    }

    private init(title: String, message: String, actions: [NativeStartAction], inProgress: Bool) {
        self.title = title
        self.message = message
        self.actions = actions
        self.inProgress = inProgress
    }
}

/// What the composer's Can't start banner says.
extension NativeStartProblem {
    public var title: String {
        switch kind {
        case .notSignedIn: "pi can't reach a model."
        case .extensionFailed: "An extension stopped pi from starting."
        case .engineMissing: "Shepherd can't find its pi."
        case .homeUnsafe: "Shepherd won't start pi here."
        case .resumedAsNew: "pi couldn't find this conversation."
        case .folderMissing: "This thread's folder is missing."
        case .exited: "pi exited while starting (\(ended ?? "signal"))."
        case .stopped: "The agent stopped unexpectedly" + (ended.map { " (\($0))" } ?? "") + "."
        }
    }

    /// How pi ended, when it says: "code 1", or "signal 9".
    private var ended: String? {
        exitCode.map { "code \($0)" } ?? signal.map { "signal \($0)" }
    }

    /// What to do about it, then Retry. `host` names the Mac where the agent runs when this
    /// client is not that Mac's own app. Its banner has a Retry only while `retryHere` (a phone or
    /// tablet whose host takes `restartPi`, `NativeStartRestart.isOffered`); otherwise the advice
    /// sends the person to the host.
    public func advice(host: String? = nil, retryHere: Bool? = nil) -> String {
        let here = retryHere ?? (host == nil)
        let retry = here ? "Retry" : "Retry on \(host ?? "the host")"
        let retryAgain = here ? "Retry to start it again." : "Retry on \(host ?? "the host") to start it again."
        return switch kind {
        case .notSignedIn: "Sign in to a provider for Shepherd's pi (Settings ▸ Pi), then \(retry)."
        case .extensionFailed: "Fix or remove it, then \(retry)."
        case .engineMissing: "Its copy of pi is missing from the app. Reinstall Shepherd, then \(retry)."
        case .homeUnsafe: "Its pi home and your own pi overlap. Move one of them, then \(retry)."
        case .resumedAsNew:
            "It would have started a new, empty one, so Shepherd stopped it. The conversation's file is untouched."
                + (here ? "" : " Retry on \(host ?? "the host").")
        case .folderMissing:
            "It was moved, renamed or deleted. Locate Folder… moves this thread and its conversation to where it is now"
                + (host.map { ", on \($0)." } ?? ".")
        case .exited: retryAgain
        case .stopped: retryAgain + " Its conversation is saved."
        }
    }

    /// The buttons the banner offers, in order, wherever it is drawn. `canRestart`: the client can
    /// ask the agent's host to start pi again (the Mac's own app always can; a phone or tablet
    /// when the host takes `restartPi`). `canLocateFolder`: the client has Locate Folder…, which
    /// only the Mac's app does; a missing folder is fixed on the host, never retried.
    public func actions(canRestart: Bool, canLocateFolder: Bool) -> [NativeStartAction] {
        guard canRestart else { return [] }
        switch kind {
        case .folderMissing: return canLocateFolder ? [.locateFolder] : []
        case .resumedAsNew: return [.startNewConversation, .retry]
        default: return [.retry]
        }
    }

    /// The banner's message: the advice, then pi's own lines.
    public func message(host: String? = nil, retryHere: Bool? = nil) -> String {
        ([advice(host: host, retryHere: retryHere)] + (lines.isEmpty ? [] : [lines.joined(separator: "\n")])).joined(separator: "\n\n")
    }
}

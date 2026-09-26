import Foundation
import ShepherdProtocol

/// What the composer's Can't start banner says (DESIGN.md › Composer › States › Can't start).
extension NativeStartProblem {
    public var title: String {
        switch kind {
        case .notSignedIn: "pi can't reach a model."
        case .extensionFailed: "An extension stopped pi from starting."
        case .engineMissing: "Shepherd can't find its pi."
        case .homeUnsafe: "Shepherd won't start pi here."
        case .resumedAsNew: "pi couldn't find this conversation."
        case .exited: "pi exited while starting (\(exitCode.map { "code \($0)" } ?? "signal"))."
        }
    }

    /// What to do about it, then Retry: on this Mac, or on `host`, where a remote viewer's agent
    /// runs (its banner has no Retry).
    public func advice(host: String? = nil) -> String {
        let retry = host.map { "Retry on \($0)" } ?? "Retry"
        return switch kind {
        case .notSignedIn: "Sign in to a provider for Shepherd's pi (Settings ▸ Pi), then \(retry)."
        case .extensionFailed: "Fix or remove it, then \(retry)."
        case .engineMissing: "Its copy of pi is missing from the app. Reinstall Shepherd, then \(retry)."
        case .homeUnsafe: "Its pi home and your own pi overlap. Move one of them, then \(retry)."
        case .resumedAsNew:
            "It would have started a new, empty one, so Shepherd stopped it. The conversation's file is untouched."
                + (host.map { " Retry on \($0)." } ?? "")
        case .exited: host.map { "Retry on \($0) to start it again." } ?? "Retry to start it again."
        }
    }

    /// The banner's message: the advice, then pi's own lines.
    public func message(host: String? = nil) -> String {
        ([advice(host: host)] + (lines.isEmpty ? [] : [lines.joined(separator: "\n")])).joined(separator: "\n\n")
    }
}

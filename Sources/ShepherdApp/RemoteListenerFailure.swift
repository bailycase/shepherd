import Foundation
import ShepherdSessions

/// Why the listener couldn't start, as Settings ▸ Remote says it: one plain sentence under the
/// Listener row, and the technical reason only as that line's tooltip.
struct RemoteListenerFailure: Equatable {
    let sentence: String
    let detail: String

    init(_ error: Error, port: UInt16) {
        sentence = Self.sentence(for: error, port: port)
        detail = String(describing: error)
    }

    /// As the host said it (`HostSettings.listenerProblem`).
    init(sentence: String, detail: String) {
        self.sentence = sentence
        self.detail = detail
    }

    static func sentence(for error: Error, port: UInt16) -> String {
        switch error {
        case SessionServerError.system(let call, let code) where call == "bind":
            switch code {
            case EADDRINUSE: return "Couldn't start: port \(port) is already in use."
            case EACCES: return "Couldn't start: port \(port) needs administrator rights."
            case EADDRNOTAVAIL: return "Couldn't start: this Mac has no network address to serve on."
            default: return "Couldn't start: this Mac didn't let Shepherd use port \(port)."
            }
        case SessionServerError.system(let call, _) where call == "chmod":
            return "Couldn't start: Shepherd couldn't protect its token file."
        case is CocoaError:
            return "Couldn't start: Shepherd couldn't read or write its token file."
        default:
            return "Couldn't start the listener."
        }
    }
}

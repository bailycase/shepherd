import Foundation
import ShepherdCore
import ShepherdProtocol

/// A new agent's opening prompt. The host holds it until the agent's pi serves, then sends it
/// before the thread answers anything, so the first snapshot every client gets already shows it
/// as a pending row. Its send's operation id is the agent's id, so a client that created the
/// agent draws that same row (`preview`) while pi starts, and the row keeps its identity when
/// the host's lands and when pi starts the turn. Images attached on the New thread page go to pi
/// with it.
public struct OpeningPrompt: Equatable, Sendable {
    public let text: String
    public let images: [NativeImage]
    public let operationID: UUID

    /// Nil for a blank prompt, which is never sent (nor are images without one).
    public init?(_ text: String?, images: [NativeImage] = [], agentID: AgentID) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.text = text
        self.images = images
        operationID = UUID(uuidString: agentID.rawValue) ?? UUID()
    }

    /// The pending row the host's snapshot carries for it once pi serves.
    public func pendingRow(at timestamp: Double) -> NativeThreadMessage {
        .pendingSend(operationID: operationID, text: text, images: images.count, timestamp: timestamp)
    }

    /// A new agent's thread while its pi starts: nothing but this prompt, waiting for pi. `base`
    /// is what the client knows of the thread already (the model and thinking level it launches
    /// with); a client with nothing better passes nil.
    public func preview(_ base: NativeThreadSnapshot? = nil, model: String? = nil, thinking: String? = nil,
                        at timestamp: Double = Date().timeIntervalSince1970 * 1000) -> NativeThreadSnapshot {
        var value = base ?? NativeThreadSnapshot(
            piSessionID: "", generation: "", revision: 0, running: false, model: model, thinking: thinking,
            supportedActions: [], dialogsSupported: false, dialogs: [], widgets: [], messages: [], provisional: [],
            clipped: false, runtime: "rpc")
        value.provisional = [pendingRow(at: timestamp)]
        return value
    }
}

extension NativeThreadMessage {
    /// A send pi has not started yet, as the host shows it until pi does ("pending:<id>").
    public static func pendingSend(operationID: UUID, text: String, images: Int, timestamp: Double) -> NativeThreadMessage {
        var blocks = [NativeThreadBlock(kind: .text, text: text)]
        blocks += (0..<images).map { _ in NativeThreadBlock(kind: .unsupportedImage, text: "[Image unavailable in native thread]") }
        return NativeThreadMessage(entryID: "pending:\(operationID.uuidString)", role: "user", blocks: blocks, status: "pending",
                                   timestamp: timestamp, operationID: operationID)
    }
}

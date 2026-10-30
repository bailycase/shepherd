import Foundation
import ShepherdProtocol

/// A message carrying design references to a thread nothing on screen is showing (Implement in a
/// thread…): asks for the thread's session, waiting while its pi starts, then sends at it. While
/// pi works the message waits in the host's queue, as any follow-up does. `thread` reaches the
/// thread: this Mac's server, or a host's connection.
public enum NativeReferenceSend {
    /// How long a send waits for a thread's pi to serve (one just started boots in seconds).
    public static let wait: Duration = .seconds(90)

    public static func send(_ references: [NativeAttachedReference], text: String, images: [NativeImage] = [],
                            thread: (NativeThreadRequest) async throws -> NativeThreadResult) async throws {
        let deadline = ContinuousClock.now + wait
        while true {
            switch try await thread(.snapshot()) {
            case .snapshot(let snapshot) where !snapshot.piSessionID.isEmpty:
                let message = NativeAttachedFile.message(text, files: [], references: references.count)
                let reply = try await thread(.send(
                    expectedSessionID: snapshot.piSessionID, generation: snapshot.generation, operationID: UUID(), text: message,
                    delivery: .followUp, images: images.isEmpty ? nil : images, designReferences: references.map(\.record)))
                if case .failure(_, let why) = reply { throw Failure(why) }
                return
            case .failure(let code, let why) where code != NativeThreadCode.starting:
                throw Failure(why)
            default:
                guard ContinuousClock.now < deadline else { throw Failure("The thread's pi didn't start in time. Nothing was sent.") }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}

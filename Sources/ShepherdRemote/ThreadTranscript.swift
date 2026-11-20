import Foundation
import ShepherdProtocol

public enum ThreadTranscript {
    /// Copy the current session's user and assistant text, oldest first, only after the last page.
    /// Returns false when there is no snapshot or nothing was said.
    @MainActor
    public static func copy(fetch: (NativeThreadRequest) async throws -> NativeThreadResult,
                            to paste: (String) -> Void) async throws -> Bool {
        guard case .snapshot(let first) = try await fetch(.snapshot()) else { return false }
        var seenEntries: Set<String> = []
        var seenCursors: Set<String> = []
        var pages: [[String]] = []
        var page = first
        while true {
            pages.append(page.messages.compactMap { message in
                guard seenEntries.insert(message.entryID).inserted,
                      message.role == "user" || message.role == "assistant" else { return nil }
                let text = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : "\(message.role): \(text)"
            })
            guard let cursor = page.olderCursor else { break }
            guard seenCursors.count < 512, seenCursors.insert(cursor).inserted else {
                throw RemoteHostClientError.rejected(code: "protocol", message: "Couldn't read the full transcript. Nothing was copied.")
            }
            switch try await fetch(.snapshot(expectedSessionID: first.piSessionID, beforeEntryID: cursor)) {
            case .snapshot(let older) where older.piSessionID == first.piSessionID && older.generation == first.generation:
                page = older
            case .failure(let code, let message):
                throw RemoteHostClientError.rejected(code: code, message: message)
            default:
                throw RemoteHostClientError.rejected(code: "protocol", message: "The transcript changed or is unavailable. Nothing was copied.")
            }
        }
        let text = pages.reversed().joined().joined(separator: "\n\n")
        guard !text.isEmpty else { return false }
        paste(text)
        return true
    }
}

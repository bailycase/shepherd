import Foundation
import ShepherdProtocol

public enum ThreadTranscript {
    /// Copy the current session's user and assistant text, oldest first, only after the last page.
    /// Returns false only when the host confirms there is no text to copy.
    @MainActor
    public static func copy(fetch: (NativeThreadRequest) async throws -> NativeThreadResult,
                            to paste: (String) -> Void) async throws -> Bool {
        let first = try snapshot(try await fetch(.transcriptSnapshot()))
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
            let older = try snapshot(try await fetch(.transcriptSnapshot(expectedSessionID: first.piSessionID, beforeEntryID: cursor)))
            guard older.piSessionID == first.piSessionID, older.generation == first.generation else {
                throw RemoteHostClientError.rejected(code: "stale_cursor", message: "The transcript changed. Nothing was copied.")
            }
            page = older
        }
        let text = pages.reversed().joined().joined(separator: "\n\n")
        guard !text.isEmpty else { return false }
        paste(text)
        return true
    }

    private static func snapshot(_ result: NativeThreadResult) throws -> NativeThreadSnapshot {
        switch result {
        case .failure(let code, let message):
            throw RemoteHostClientError.rejected(code: code, message: message)
        case .snapshot(let page) where page.initializing == true:
            throw RemoteHostClientError.rejected(code: NativeThreadCode.starting, message: "The thread is still loading. Try copying it again when it’s ready.")
        case .snapshot(let page) where page.clips?.history != true:
            return page
        default:
            throw RemoteHostClientError.rejected(code: "protocol", message: "Couldn't read the full transcript. Nothing was copied.")
        }
    }
}

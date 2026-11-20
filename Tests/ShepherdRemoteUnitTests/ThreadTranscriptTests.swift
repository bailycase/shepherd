import ShepherdProtocol
import ShepherdRemote
import Testing

@MainActor
struct ThreadTranscriptTests {
    @Test func aFailedOlderPageDoesNotCopyTheNewestPage() async {
        var copies: [String] = []
        let error = await #expect(throws: RemoteHostClientError.self) {
            try await ThreadTranscript.copy(fetch: { request in
                switch request {
                case .snapshot(expectedSessionID: nil, beforeEntryID: nil, afterRevision: nil):
                    return page([message("newest", "assistant", "Finished")], before: "newest")
                case .snapshot(expectedSessionID: "session", beforeEntryID: "newest", afterRevision: nil):
                    return .failure(code: "session_gone", message: "Session is gone")
                default:
                    Issue.record("Unexpected request: \(request)")
                    return .accepted(operationID: .init())
                }
            }, to: { copies.append($0) })
        }
        guard case .rejected(code: "session_gone", message: "Session is gone")? = error else {
            Issue.record("Expected the host's refusal")
            return
        }
        #expect(copies.isEmpty)
    }

    @Test func copiesAllPagesOnceInOrderWithoutToolsOrThinking() async throws {
        let middle = message("middle", "assistant", "  Working  ")
        let tool = NativeThreadMessage(entryID: "tool", role: "toolResult", blocks: [.init(kind: .text, text: "private output")], toolName: "read")
        let last = NativeThreadMessage(entryID: "newest", role: "assistant", blocks: [
            .init(kind: .thinking, text: "thinking"), .init(kind: .text, text: "Finished")
        ])
        var copies: [String] = []
        let copied = try await ThreadTranscript.copy(fetch: { request in
            #expect(copies.isEmpty)
            switch request {
            case .snapshot(expectedSessionID: nil, beforeEntryID: nil, afterRevision: nil):
                return page([last], before: "newest")
            case .snapshot(expectedSessionID: "session", beforeEntryID: "newest", afterRevision: nil):
                return page([middle, tool, last], before: "middle")
            case .snapshot(expectedSessionID: "session", beforeEntryID: "middle", afterRevision: nil):
                return page([message("oldest", "user", "Tidy the shed"), middle])
            default:
                Issue.record("Unexpected request: \(request)")
                return .accepted(operationID: .init())
            }
        }, to: { copies.append($0) })
        #expect(copied)
        #expect(copies == ["user: Tidy the shed\n\nassistant: Working\n\nassistant: Finished"])
    }

    @Test func noSnapshotOrNoSpokenTextLeavesClipboardAlone() async throws {
        for result in [NativeThreadResult.accepted(operationID: .init()), page([message("blank", "user", " \n ")])] {
            let copied = try await ThreadTranscript.copy(fetch: { _ in result }, to: { _ in
                Issue.record("Nothing should have been copied")
            })
            #expect(!copied)
        }
    }

    private func page(_ messages: [NativeThreadMessage], before: String? = nil) -> NativeThreadResult {
        .snapshot(value: .init(piSessionID: "session", generation: "generation", revision: 1, running: false,
                               supportedActions: [], dialogsSupported: false, dialogs: [], messages: messages,
                               olderCursor: before, provisional: [], clipped: false))
    }

    private func message(_ id: String, _ role: String, _ text: String) -> NativeThreadMessage {
        .init(entryID: id, role: role, blocks: [.init(kind: .text, text: text)])
    }
}

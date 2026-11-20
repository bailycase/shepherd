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
                case .transcriptSnapshot(expectedSessionID: nil, beforeEntryID: nil):
                    return page([message("newest", "assistant", "Finished")], before: "newest")
                case .transcriptSnapshot(expectedSessionID: "session", beforeEntryID: "newest"):
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
            case .transcriptSnapshot(expectedSessionID: nil, beforeEntryID: nil):
                return page([last], before: "newest")
            case .transcriptSnapshot(expectedSessionID: "session", beforeEntryID: "newest"):
                return page([middle, tool, last], before: "middle")
            case .transcriptSnapshot(expectedSessionID: "session", beforeEntryID: "middle"):
                return page([message("oldest", "user", "Tidy the shed"), middle])
            default:
                Issue.record("Unexpected request: \(request)")
                return .accepted(operationID: .init())
            }
        }, to: { copies.append($0) })
        #expect(copied)
        #expect(copies == ["user: Tidy the shed\n\nassistant: Working\n\nassistant: Finished"])
    }

    @Test func anEmptyTranscriptLeavesClipboardAlone() async throws {
        let copied = try await ThreadTranscript.copy(fetch: { _ in page([]) }, to: { _ in
            Issue.record("Nothing should have been copied")
        })
        #expect(!copied)
    }

    @Test func anUnavailableFirstPageThrowsInsteadOfCopyingOrReportingEmpty() async {
        let cases: [(NativeThreadResult, String)] = [
            (.failure(code: "session_gone", message: "Session is gone"), "session_gone"),
            (.accepted(operationID: .init()), "protocol"),
            (page([], initializing: true), NativeThreadCode.starting),
            (page([message("newest", "assistant", "Incomplete")], clips: .init(history: true)), "protocol"),
        ]
        for (result, expectedCode) in cases {
            let error = await #expect(throws: RemoteHostClientError.self) {
                try await ThreadTranscript.copy(fetch: { _ in result }, to: { _ in
                    Issue.record("Nothing should have been copied")
                })
            }
            guard case .rejected(let code, _)? = error else { Issue.record("Expected a refusal"); continue }
            #expect(code == expectedCode)
        }
    }

    @Test func pagesFromDifferentFileRevisionsAreNotCopied() async {
        await #expect(throws: RemoteHostClientError.self) {
            try await ThreadTranscript.copy(fetch: { request in
                if request == .transcriptSnapshot() {
                    return page([message("newest", "assistant", "Finished")], before: "newest")
                }
                return page([message("oldest", "user", "Unrelated")], generation: "changed")
            }, to: { _ in Issue.record("The clipboard must not mix revisions") })
        }
    }

    private func page(_ messages: [NativeThreadMessage], before: String? = nil, generation: String = "generation",
                      initializing: Bool? = nil, clips: NativeThreadClips? = nil) -> NativeThreadResult {
        .snapshot(value: .init(piSessionID: "session", generation: generation, revision: 1, running: false,
                               supportedActions: [], dialogsSupported: false, dialogs: [], messages: messages,
                               olderCursor: before, provisional: [], clipped: clips != nil, clips: clips, initializing: initializing))
    }

    private func message(_ id: String, _ role: String, _ text: String) -> NativeThreadMessage {
        .init(entryID: id, role: role, blocks: [.init(kind: .text, text: text)])
    }
}

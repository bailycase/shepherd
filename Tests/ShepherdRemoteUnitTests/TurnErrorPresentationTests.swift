import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Failed requests in a turn (TurnErrors, ThreadError): pi's retries merged, the card the turn
/// ends with, the retry line while pi retries, and folding.
@Suite("Turn errors in the thread")
struct TurnErrorPresentationTests {
    typealias F = Fixture
    static let utc = TimeZone(identifier: "UTC")!

    private func failed(_ text: String = "529 overloaded", at: Double) -> NativeThreadMessage {
        var message = F.assistant(text, status: "error")
        message.timestamp = at
        message.provider = "anthropic"
        message.model = "claude-sonnet-4-5"
        return message
    }

    private func error(_ item: NativeTurnPresentation.Item?) -> (NativeTurnError, final: Bool, folded: Bool)? {
        guard case .error(_, let error, let final, let folded)? = item else { return nil }
        return (error, final, folded)
    }

    /// pi's retries of one request are one error that says how many tries it took; the turn's
    /// last one is the card, with Retry once the turn is over.
    @Test func retriesMergeIntoTheErrorTheTurnEndsWith() throws {
        let messages = [failed(at: 0), failed(at: 20_000), failed(at: 45_000)]
        let finished = nativeTurnPresentation(messages, live: false, errors: NativeTurnErrorContext(host: "build-01", timeZone: Self.utc))
        #expect(finished.items.count == 1)
        let (value, final, folded) = try #require(error(finished.items.last))
        #expect(final && !folded)
        #expect(value.tries == "Tried 3 times over 45s" && value.title == "Anthropic is overloaded")
        #expect(value.facts.contains(.init("Host", "build-01")))
    }

    /// A request pi retried past, the turn going on, folds to a line.
    @Test func anErrorTheTurnWentOnFromFolds() throws {
        let presentation = nativeTurnPresentation([failed(at: 0), F.assistant("Recovered.")], live: false)
        let (_, final, folded) = try #require(error(presentation.items.first))
        #expect(!final && folded)
    }

    /// While pi retries, the live turn ends in the retry line and nothing else moves; without a
    /// retry the error shows as a card with no Retry until the turn is over.
    @Test func whilePiRetriesTheTurnEndsInTheRetryLine() throws {
        let retry = NativeThreadRetry(attempt: 2, maxAttempts: 3, retryAt: 90_000)
        let retrying = nativeTurnPresentation([failed(at: 0)], live: true, errors: NativeTurnErrorContext(retry: retry))
        guard case .retrying(_, let line)? = retrying.items.last else { Issue.record("expected the retry line"); return }
        #expect(line == NativeRetryLine(title: "Anthropic is overloaded", glyph: "arrow.clockwise", attempt: 2, maxAttempts: 3, retryAt: 90_000))
        #expect(!retrying.betweenTools)

        let waiting = nativeTurnPresentation([failed(at: 0)], live: true)
        let (_, final, folded) = try #require(error(waiting.items.last))
        #expect(!final && !folded && !waiting.betweenTools)

        let timeout = nativeTurnPresentation([failed("Request timed out.", at: 0)], live: true, errors: NativeTurnErrorContext(retry: retry))
        guard case .retrying(_, let slow)? = timeout.items.last else { Issue.record("expected the retry line"); return }
        #expect(slow.glyph == "hourglass" && slow.title == "Anthropic didn’t respond in time")
    }

    /// The earlier of two replies that failed the same way folds; one followed by a reply that
    /// failed differently, or worked, stays a card.
    @MainActor @Test func theNextReplyFailingTheSameWayFoldsTheEarlierOne() {
        func reply(_ messages: [NativeThreadMessage]) -> NativeThreadRow {
            NativeThreadRow(turn: NativeTurn(id: UUID().uuidString, isUser: false, messages: messages), presentation: nativeTurnPresentation(messages, live: false),
                            live: false, promptText: nil, startedAt: nil)
        }
        func user() -> NativeThreadRow {
            NativeThreadRow(turn: NativeTurn(id: UUID().uuidString, isUser: true, messages: [F.user()]), presentation: nil, live: false, promptText: nil, startedAt: nil)
        }
        var rows = [user(), reply([failed(at: 0)]), user(), reply([failed(at: 10_000)]), user(), reply([failed("500 server error", at: 20_000)]),
                    user(), reply([F.assistant("Done.")])]
        NativeThreadStore.foldRepeatedErrors(&rows)
        let folds = rows.compactMap { row -> Bool? in
            guard case .error(_, _, _, let folded)? = row.presentation?.items.last else { return nil }
            return folded
        }
        #expect(folds == [true, false, false])
    }
}

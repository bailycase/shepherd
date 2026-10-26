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

    /// Retry uses a quiet progress line; a transient error doesn't flash a card before it.
    @Test func whilePiRetriesTheTurnEndsInTheRetryLine() throws {
        let retry = NativeThreadRetry(attempt: 2, maxAttempts: 3, retryAt: 90_000)
        let retrying = nativeTurnPresentation([failed(at: 0)], live: true, errors: NativeTurnErrorContext(retry: retry))
        guard case .retrying(_, let line)? = retrying.items.last else { Issue.record("expected the retry line"); return }
        #expect(line == NativeRetryLine(title: "Reconnecting to Anthropic", glyph: "arrow.clockwise", attempt: 2, maxAttempts: 3, retryAt: 90_000))
        let typed = nativeTurnPresentation([failed(#"529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, at: 0)],
                                           live: true, errors: NativeTurnErrorContext(retry: retry))
        guard case .retrying(_, let typedLine)? = typed.items.last else { Issue.record("expected the retry line"); return }
        #expect(typedLine.text(now: 82_000) == "Reconnecting to Anthropic · retrying in 8s")
        #expect(!retrying.betweenTools)

        let waiting = nativeTurnPresentation([failed(at: 0)], live: true)
        #expect(waiting.items.isEmpty)
        #expect(waiting.betweenTools)

        let timeout = nativeTurnPresentation([failed("Request timed out.", at: 0)], live: true, errors: NativeTurnErrorContext(retry: retry))
        guard case .retrying(_, let slow)? = timeout.items.last else { Issue.record("expected the retry line"); return }
        #expect(slow.glyph == "hourglass" && slow.title == "Reconnecting to Anthropic")
    }

    @Test(arguments: ["529 overloaded", "Request timed out.", "500 server error", "429 rate limited",
                      "Connection reset", "The provider returned no answer or tool call. Retry to continue the interrupted turn."])
    func aTransientFailureStaysQuietUntilTheTurnSettles(_ text: String) throws {
        let messages = [failed(text, at: 0)]
        let live = nativeTurnPresentation(messages, live: true)
        #expect(live.items.isEmpty)
        #expect(live.betweenTools)
        let settled = nativeTurnPresentation(messages, live: false)
        let (_, final, folded) = try #require(error(settled.items.last))
        #expect(final && !folded)
    }

    @Test(arguments: ["401 authentication failed", "context length exceeded", "Unrecognized permanent failure"])
    func permanentFailuresRemainVisible(_ text: String) throws {
        let presentation = nativeTurnPresentation([failed(text, at: 0)], live: true)
        let (_, final, folded) = try #require(error(presentation.items.last))
        #expect(!final && !folded && !presentation.betweenTools)
    }

    @Test func rateLimitProgressWaitsForTheProvider() {
        let retry = NativeThreadRetry(attempt: 1, maxAttempts: 3, retryAt: 90_000)
        let presentation = nativeTurnPresentation([failed("429 rate limited", at: 0)], live: true,
                                                   errors: NativeTurnErrorContext(retry: retry))
        guard case .retrying(_, let line)? = presentation.items.last else {
            Issue.record("expected retry progress"); return
        }
        #expect(line.title == "Waiting for Anthropic")
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

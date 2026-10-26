import Foundation
import ShepherdProtocol
@testable import ShepherdRemote
import Testing

/// What the thread says about a response while it runs and once it ended (ResponseVisibility):
/// the live line before the model's first event, live thinking's shared summary, a call's
/// arguments as they arrive, and the Response timing of a finished reply. Only what the host
/// measured: nothing estimated, nothing added twice.
@Suite("Response visibility")
struct ResponseVisibilityTests {
    typealias F = Fixture

    /// The board's example: 1.4s waiting, 30.4s thinking, 13.2s writing; headers at 1.2s fall
    /// inside the wait.
    static let measured = NativeResponseTiming(sentAt: 1_000_000, headersAt: 1_001_200, firstEventAt: 1_001_400, firstThinkingAt: 1_001_400,
                                              firstTextAt: 1_031_800, endedAt: 1_045_000, inputTokens: 14_200, outputTokens: 2_900,
                                              provider: "anthropic", model: "claude-opus-4-5")

    @Test func phasesFollowOneAnotherAndAddUpToTheTotal() throws {
        let report = try #require(NativeResponseTimingReport(Self.measured, hasText: true))
        #expect(report.total == "45.0s" && report.axisEnd == "45s")
        #expect(report.segments.map(\.phase) == [.waiting, .thinking, .writing])
        #expect(report.segments.map(\.text) == ["1.4s", "30.4s", "13.2s"])
        #expect(abs(report.segments.reduce(0) { $0 + $1.seconds } - report.totalSeconds) < 0.0001, "phases add up to the total")
        #expect(report.marks.map(\.label) == ["Request sent", "Headers received", "First model event", "First visible text", "Response ended"])
        #expect(report.marks.map(\.value) == ["0s", "1.2s", "1.4s", "31.8s", "45.0s"])
        #expect(report.usage == "14.2k in · 2.9k out")
        #expect(report.source == "claude-opus-4-5 · Anthropic")
        #expect(report.note == "The phases follow one another, so they add up to the total. Times are what this Mac saw.")
    }

    /// Rounding each phase on its own would make 1.44 + 30.44 + 13.12 read 1.4 + 30.4 + 13.1 =
    /// 44.9 against a 45.0 total; rounding the moments first keeps the sum as written.
    @Test func roundedPhasesStillAddUp() throws {
        let timing = NativeResponseTiming(sentAt: 0.5, firstEventAt: 1_440.5, firstThinkingAt: 1_500, firstTextAt: 31_880.5, endedAt: 45_000.5)
        let report = try #require(NativeResponseTimingReport(timing, hasText: true))
        let shown = report.segments.compactMap { Double($0.text.dropLast()) }.reduce(0, +)
        #expect(String(format: "%.1fs", shown) == report.total)
    }

    /// What wasn't measured says so, or is left out: never a number made up for it.
    @Test func whatWasNotMeasuredIsNotInvented() throws {
        #expect(NativeResponseTimingReport(NativeResponseTiming(firstEventAt: 1, endedAt: 2), hasText: true) == nil, "no send, no report")
        #expect(NativeResponseTimingReport(NativeResponseTiming(sentAt: 1), hasText: true) == nil, "no end, no report")
        #expect(NativeResponseTimingReport(NativeResponseTiming(sentAt: .nan, endedAt: 2), hasText: true) == nil)
        #expect(NativeResponseTimingReport(NativeResponseTiming(sentAt: 1, endedAt: .greatestFiniteMagnitude), hasText: true) == nil)

        let noEvent = try #require(NativeResponseTimingReport(NativeResponseTiming(sentAt: 0, endedAt: 9_000), hasText: true))
        #expect(noEvent.segments.isEmpty, "phases can't be told apart without the first event")
        #expect(noEvent.marks.filter { !$0.measured }.map(\.value) == ["Not measured", "Not measured", "Not measured"])
        #expect(noEvent.usage == nil)
        #expect(noEvent.note.hasPrefix("The first model event wasn’t measured"))

        let noThinking = try #require(NativeResponseTimingReport(NativeResponseTiming(sentAt: 0, firstEventAt: 800, firstTextAt: 2_000, endedAt: 5_000),
                                                                 hasText: true))
        #expect(noThinking.segments.map(\.phase) == [.waiting, .starting, .writing], "no thinking seen, none claimed")

        let callsOnly = try #require(NativeResponseTimingReport(NativeResponseTiming(sentAt: 0, firstEventAt: 800, firstThinkingAt: 900, endedAt: 5_000),
                                                                hasText: false, requests: 3))
        #expect(callsOnly.segments.map(\.phase) == [.waiting, .responding])
        #expect(callsOnly.marks[3].value == "None")
        #expect(callsOnly.note.hasPrefix("The last of 3 model requests in this turn."))
    }

    @Test func phasesNeverLabelToolArgumentsOrInterleavedThinkingAsWriting() throws {
        var timing = Self.measured
        timing.mixedPhases = true
        let mixed = try #require(NativeResponseTimingReport(timing, hasText: true))
        #expect(mixed.segments.map(\.phase) == [.waiting, .responding])
        #expect(mixed.segments.map(\.text) == ["1.4s", "43.6s"])
        timing.mixedPhases = nil
        timing.firstThinkingAt = timing.sentAt! + 3_000
        let delayed = try #require(NativeResponseTimingReport(timing, hasText: true))
        #expect(delayed.segments.map(\.phase) == [.waiting, .starting, .thinking, .writing])
        #expect(delayed.segments[1].text == "1.6s", "no thinking claimed before its first observed event")
    }

    /// A finished turn offers the timing of the request that wrote its reply; a live turn, a
    /// failed one, a stopped one, and history the host never timed offer none.
    @Test func aFinishedReplyCarriesItsTiming() throws {
        var reply = F.assistant("Yes.", status: "stop")
        reply.timing = Self.measured
        var call = F.assistant("", status: "toolUse")
        call.timing = NativeResponseTiming(sentAt: 1, endedAt: 2)
        let finished = nativeTurnPresentation([call, F.tool("read", args: #"{"path":"a"}"#), reply], live: false)
        #expect(finished.timing?.total == "45.0s")
        #expect(finished.timing?.note.hasPrefix("The last of 2 model requests") == true)
        #expect(nativeTurnPresentation([reply], live: false, errors: NativeTurnErrorContext(host: "horizon")).timing?.note.contains("the agent’s host") == true)
        #expect(nativeTurnPresentation([reply], live: true).timing == nil)
        var stopped = reply
        stopped.status = "aborted"
        #expect(nativeTurnPresentation([stopped], live: false).timing == nil)
        #expect(nativeTurnPresentation([F.assistant("Old.", status: "stop")], live: false).timing == nil, "a session from before: none")
    }

    /// Live thinking opens only on what the provider shared: its summary parsed as it grows, and
    /// its clock from when the host saw it start. With nothing shared it stays the live line.
    @Test func liveThinkingOpensOnlyOnASharedSummary() throws {
        var streaming = F.assistant("", thinking: "**Choosing a screen**\n\nCompared the two.", status: "streaming")
        streaming.timing = NativeResponseTiming(sentAt: 10, firstEventAt: 20, firstThinkingAt: 30)
        let shared = nativeTurnPresentation([streaming], live: true)
        guard case .thinking(_, _, let blocks, _, true, let since)? = shared.items.last else { Issue.record("expected live thinking"); return }
        #expect(!blocks.isEmpty && since == 30)

        var hidden = F.assistant("", thinking: "  ", status: "streaming")
        hidden.timing = streaming.timing
        guard case .thinking(_, _, let none, _, true, _)? = nativeTurnPresentation([hidden], live: true).items.last else {
            Issue.record("expected live thinking"); return
        }
        #expect(none.isEmpty)

        let older = F.assistant("", thinking: "hmm", status: "streaming")
        guard case .thinking(_, _, _, _, true, let unknown)? = nativeTurnPresentation([older], live: true).items.last else {
            Issue.record("expected live thinking"); return
        }
        #expect(unknown == nil, "an older host's thinking has no clock rather than a guessed one")
    }

    /// Before the model's first event the line waits, its clock from the send; after it, the
    /// response has started. Nothing in between is called thinking.
    @Test func theLiveLineSaysOnlyWhatWasObserved() {
        #expect(NativeLiveWait(nil) == NativeLiveWait(phase: .waiting, since: nil))
        #expect(NativeLiveWait(nil).title == "Waiting for response")
        let sent = NativeLiveWait(NativeResponseTiming(sentAt: 5_000, headersAt: 5_900))
        #expect(sent == NativeLiveWait(phase: .waiting, since: 5_000), "headers are not a model event")
        #expect(sent.help == "Request sent. No model event observed yet. The model may already be processing input or thinking.")
        let started = NativeLiveWait(NativeResponseTiming(sentAt: 5_000, firstEventAt: 6_000))
        #expect(started.phase == .started && started.since == 5_000 && started.title == "Response started")
    }

    /// A call the model is still writing says how much of its arguments came; once it runs, it
    /// doesn't.
    @Test func aCallBeingWrittenCountsItsArguments() {
        var writing = F.tool("write", args: #"{"path":"App/Duo.swift"}"#, status: "streaming", startedAt: 1)
        writing.argumentBytes = 18 * 1024
        let burst = nativeActivityBursts([NativeActivityCall(writing)])
        #expect(burst.first?.received == "18 KB received" && burst.first?.label == "Writing")
        writing.status = "running"
        #expect(nativeActivityBursts([NativeActivityCall(writing)]).first?.received == nil)
        #expect(nativeReceivedText(1_572_864) == "1.5 MB received")
    }
}

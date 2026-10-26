import Foundation
import ShepherdProtocol

/// A finished reply's Response timing (ResponseVisibility › C): what the host measured of the
/// request that wrote it, read once per turn change. Phases follow one another from the send to
/// the end, so they add up to the total; marks are moments since the send, never added. A phase
/// or mark the host did not measure is left out or says so, never estimated.
public struct NativeResponseTimingReport: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        /// The send to the first model event.
        case waiting
        /// The first observed thinking event to the first visible text, for a simple stream.
        case thinking
        /// The first model event to the first visible text, with no thinking seen.
        case starting
        /// The first visible text to the end.
        case writing
        /// The first model event to the end, when no text was seen.
        case responding

        public var label: String {
            switch self {
            case .waiting: "Waiting for response"
            case .thinking: "Thinking"
            case .starting: "Before the first text"
            case .writing: "Writing the reply"
            case .responding: "Responding"
            }
        }
    }

    public struct Segment: Equatable, Sendable, Identifiable {
        public var phase: Phase
        public var seconds: Double
        /// "30.4s".
        public var text: String
        public var id: String { phase.rawValue }
    }

    public struct Mark: Equatable, Sendable, Identifiable {
        public var label: String
        /// "1.2s", "0s", "Not measured", "None".
        public var value: String
        public var measured: Bool
        public var id: String { label }
    }

    /// "claude-opus-4-5 · Anthropic"; nil when the host didn't hear which.
    public var source: String?
    /// "45.0s".
    public var total: String
    public var totalSeconds: Double
    /// The axis' end: "45s".
    public var axisEnd: String
    /// Empty when the first model event wasn't measured: the phases can't be told apart.
    public var segments: [Segment]
    public var marks: [Mark]
    /// "14.2k in · 2.9k out", as the provider reported it at the end; nil when it reported none.
    public var usage: String?
    /// The words under it all.
    public var note: String

    /// The report for `timing`, the request that wrote a reply; nil unless the host saw both its
    /// send and its end. `hasText`: the reply has words (a missing first text is then "Not
    /// measured", else "None"). `requests`: the model requests in the turn, this one the last.
    public init?(_ timing: NativeResponseTiming, hasText: Bool, requests: Int = 1) {
        guard let sent = timing.sentAt, let ended = timing.endedAt, sent.isFinite, ended.isFinite, ended >= sent,
              ended - sent < Double(Int.max / 1000) else { return nil }
        /// A moment as seconds since the send, rounded to the tenth shown, so phases made from
        /// these add up to the total exactly as written.
        func since(_ at: Double?) -> Double? {
            at.flatMap { $0.isFinite ? (max(0, min($0, ended) - sent) / 100).rounded() / 10 : nil }
        }
        let end = since(ended) ?? 0
        let first = since(timing.firstEventAt)
        let text = since(timing.firstTextAt)
        let thought = since(timing.firstThinkingAt)

        var segments: [Segment] = []
        func add(_ phase: Phase, _ from: Double, _ to: Double) {
            let seconds = ((to - from) * 10).rounded() / 10
            if seconds > 0 { segments.append(Segment(phase: phase, seconds: seconds, text: Self.seconds(seconds))) }
        }
        if let first {
            add(.waiting, 0, first)
            if timing.mixedPhases == true {
                add(.responding, first, end)
            } else if let text, text >= first {
                if let thought, thought >= first, thought <= text {
                    add(.starting, first, thought)
                    add(.thinking, thought, text)
                } else {
                    add(.starting, first, text)
                }
                add(.writing, text, end)
            } else {
                add(.responding, first, end)
            }
        }

        func mark(_ label: String, _ value: Double?, missing: String = "Not measured") -> Mark {
            Mark(label: label, value: value.map(Self.seconds) ?? missing, measured: value != nil)
        }
        marks = [
            Mark(label: "Request sent", value: "0s", measured: true),
            mark("Headers received", since(timing.headersAt)),
            mark("First model event", first),
            mark("First visible text", text, missing: hasText ? "Not measured" : "None"),
            mark("Response ended", end),
        ]

        let parts = [timing.model, timing.provider.map(NativeTurnError.providerName)].compactMap { $0 }
        source = parts.isEmpty ? nil : parts.joined(separator: " · ")
        totalSeconds = end
        total = Self.seconds(end)
        axisEnd = end < 60 ? "\(Int(end.rounded()))s" : nativeDurationText(end)
        self.segments = segments
        let usage = [timing.inputTokens.map { nativePreciseTokens($0) + " in" }, timing.outputTokens.map { nativePreciseTokens($0) + " out" }]
            .compactMap { $0 }
        self.usage = usage.isEmpty ? nil : usage.joined(separator: " · ")
        var note = segments.isEmpty
            ? "The first model event wasn’t measured, so the phases can’t be told apart. Times are what this Mac saw."
            : "The phases follow one another, so they add up to the total. Times are what this Mac saw."
        if timing.mixedPhases == true { note = "The stream mixed thinking, text or tool arguments, so only overall responding time is shown. Times are what this Mac saw." }
        if requests > 1 { note = "The last of \(requests) model requests in this turn. " + note }
        self.note = note
    }

    /// "1.4s", "45.0s", "0s" for none, and "1m 04.2s" from a minute.
    static func seconds(_ value: Double) -> String {
        if value <= 0 { return "0s" }
        if value < 60 { return String(format: "%.1fs", value) }
        let minutes = Int(value / 60)
        return String(format: "%dm %04.1fs", minutes, value - Double(minutes * 60))
    }
}

/// What the thread's live line says while nothing moves in it (ResponseVisibility › A): pi works
/// and no thinking, reply or call is streaming. Only what this host observed: before the model's
/// first event it can't tell queueing from reading the prompt or thinking, so it says it waits.
public struct NativeLiveWait: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// No model event yet for the request in flight, or no request seen.
        case waiting
        /// The response's first event came, and nothing it shows yet.
        case started
    }

    public var phase: Phase
    /// When the request was sent (ms, the host's clock): the clock runs from it. nil when the host
    /// didn't see it (an older host, or before pi sent anything).
    public var since: Double?

    public init(phase: Phase = .waiting, since: Double? = nil) {
        self.phase = phase
        self.since = since
    }

    /// The live line for the request in flight, as the host reported it.
    public init(_ request: NativeResponseTiming?) {
        self.init(phase: request?.firstEventAt == nil ? .waiting : .started, since: request?.sentAt)
    }

    public var title: String {
        switch phase {
        case .waiting: "Waiting for response"
        case .started: "Response started"
        }
    }

    /// The tooltip: what the words do and don't claim.
    public var help: String {
        switch phase {
        case .waiting: since == nil ? "No model event observed yet. The model may already be processing input or thinking." : "Request sent. No model event observed yet. The model may already be processing input or thinking."
        case .started: "The model’s response has begun. Nothing to show from it yet."
        }
    }
}

/// "18 KB received", for a call the model is still writing: the bytes of its arguments that
/// have arrived (KB and MB of 1,024).
public func nativeReceivedText(_ bytes: Int) -> String {
    if bytes >= 1024 * 1024 {
        let text = String(format: "%.1f", Double(bytes) / (1024 * 1024))
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + " MB received"
    }
    return "\(max(1, bytes / 1024)) KB received"
}

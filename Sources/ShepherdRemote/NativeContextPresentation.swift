import Foundation
import ShepherdProtocol

// The context meter (ContextIdeas, ContextDetails, ContextFull, ContextCompacted boards): the
// ring beside Send, its tooltip, the details it opens, and compactions in the thread. Derived
// once per change from the host's `NativeThreadContext`; views only read the results.

/// The ring beside Send, and what hovering it says. It never shows text in the composer.
public struct NativeContextMeter: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Under 60%: nothing to think about.
        case calm
        /// 60–85%: worth a look before a big task.
        case warning
        /// Over 85%: the agent compacts on its own soon.
        case critical
    }

    public enum Ring: Equatable, Sendable {
        /// A new thread: the agent has not replied, so there is no number.
        case empty
        case fill(Double, Tone)
        /// From `compaction_start` to `compaction_end`.
        case compacting
        /// After a compaction, until the agent's next reply gives a real number.
        case estimated
    }

    public var ring: Ring
    /// The hover text: "42k of 200k · 21%", or "about 23k of 200k" with `tooltipNote`.
    public var tooltip: String
    /// "exact after the next reply", drawn quieter after the tooltip.
    public var tooltipNote: String?
    public var accessibilityLabel: String

    public init(ring: Ring, tooltip: String, tooltipNote: String? = nil, accessibilityLabel: String) {
        self.ring = ring
        self.tooltip = tooltip
        self.tooltipNote = tooltipNote
        self.accessibilityLabel = accessibilityLabel
    }

    /// The tooltip as one line, for `.help`.
    public var helpText: String { [tooltip, tooltipNote].compactMap { $0 }.joined(separator: " · ") }

    /// Under 60% calm, 60 to 85% a warning, over 85% critical.
    public static func tone(percent: Double) -> Tone {
        percent > 85 ? .critical : percent >= 60 ? .warning : .calm
    }

    /// nil from a host that reports no context (an older one): no ring at all.
    public init?(_ context: NativeThreadContext?) {
        guard let context else { return nil }
        let window = context.window.map(nativeContextTokens)
        if let run = context.compacting {
            let size = (run.tokens ?? context.tokens).map { " " + nativeContextTokens($0) } ?? ""
            self.init(ring: .compacting, tooltip: "Compacting\(size)…", accessibilityLabel: "Context: compacting")
        } else if let tokens = context.tokens, let windowTokens = context.window, windowTokens > 0 {
            let percent = nativeContextPercent(tokens, of: windowTokens)
            self.init(ring: .fill(min(1, Double(tokens) / Double(windowTokens)), Self.tone(percent: percent)),
                      tooltip: "\(nativeContextTokens(tokens)) of \(window ?? "") · \(Int(percent.rounded()))%",
                      accessibilityLabel: "Context \(Int(percent.rounded()))% full")
        } else if let estimate = context.estimate {
            self.init(ring: .estimated, tooltip: "about \(nativeContextTokens(estimate))" + (window.map { " of \($0)" } ?? ""),
                      tooltipNote: "exact after the next reply", accessibilityLabel: "Context: updating after compaction")
        } else {
            self.init(ring: .empty, tooltip: window.map { "Nothing yet of \($0)" } ?? "Nothing yet",
                      tooltipNote: "the agent hasn't replied", accessibilityLabel: "Context: nothing yet")
        }
    }
}

/// `tokens` as a percentage of `window`, 0 for an empty window.
public func nativeContextPercent(_ tokens: Int, of window: Int) -> Double {
    window > 0 ? Double(tokens) / Double(window) * 100 : 0
}

/// Context sizes to the nearest thousand, as the boards write them: "42k", "184k" (a 200k
/// window less pi's 16,384 reserve), "1.2m", "812".
public func nativeContextTokens(_ tokens: Int) -> String {
    if tokens >= 999_500 {
        let text = String(format: "%.1f", Double(tokens) / 1_000_000)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "m"
    }
    if tokens >= 1_000 { return "\(Int((Double(tokens) / 1_000).rounded()))k" }
    return "\(tokens)"
}

/// Token counts as the details list them: "6.8k", "24.8k", "158k", "1.2m", "812".
public func nativePreciseTokens(_ tokens: Int) -> String {
    guard tokens >= 1_000, tokens < 100_000 else { return nativeContextTokens(tokens) }
    let text = String(format: "%.1f", Double(tokens) / 1_000)
    return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "k"
}

/// What the details popover shows (ContextDetails, ContextFull, and ContextIdeas' variants).
public struct NativeContextDetails: Equatable, Sendable {
    public enum Variant: Equatable, Sendable {
        /// No number yet.
        case empty
        /// The total, the mark, and Compact now (no split to show).
        case simple
        /// The split and the three largest items.
        case split
        /// Past 85%: the problem first, and a field for what to keep.
        case almostFull
        /// Nothing to press; it closes itself when the agent is done.
        case compacting(startedAt: Double)
        /// The agent's estimate until its next reply.
        case compacted
    }

    public enum Part: String, Equatable, Sendable, CaseIterable {
        case system, instructions, messages, toolResults
    }

    public struct Segment: Equatable, Sendable {
        public var part: Part?
        /// Of the window, 0...1.
        public var fraction: Double
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public var part: Part
        public var label: String
        public var value: String
        public var id: Part { part }
    }

    public struct Largest: Equatable, Sendable, Identifiable {
        public var entryID: String
        public var kind: NativeContextItem.Kind
        public var label: String
        public var value: String
        public var id: String { entryID }
    }

    public var variant: Variant
    /// "Context", "Context almost full", "Compacting".
    public var title: String
    /// "claude-opus · 200k", "just compacted".
    public var meta: String?
    /// "42k", "~23k"; nil while compacting or before any number.
    public var total: String?
    /// "of 200k".
    public var ofWindow: String?
    /// "21%", "estimate".
    public var trailing: String?
    public var segments: [Segment]
    /// Where pi compacts on its own, as a fraction of the window, and its label.
    public var mark: Double?
    public var markLabel: String?
    public var rows: [Row]
    /// "158k" free, when the window is known.
    public var free: String?
    public var largest: [Largest]
    /// The almost-full, compacting, and just-compacted text.
    public var note: String?
    /// The part of `note` the board sets in mono: the size being summarized.
    public var emphasis: String?
    public var footnote: String?
    /// The latest compaction's summary in the thread (Show summary).
    public var summaryEntryID: String?
    /// Compact now is offered (not while compacting).
    public var compactOffered: Bool

    public static let footnoteText = "The total is the agent’s. The split is Shepherd’s estimate from the messages."

    public init(context: NativeThreadContext, model: String?) {
        let window = context.window
        let windowText = window.map(nativeContextTokens)
        func fraction(_ tokens: Int) -> Double { window.map { $0 > 0 ? min(1, Double(tokens) / Double($0)) : 0 } ?? 0 }
        let split = context.split
        let modelMeta = [model.map(nativeContextModelName), windowText].compactMap { $0 }.joined(separator: " · ")
        variant = split == nil ? .simple : .split
        title = "Context"
        meta = modelMeta.isEmpty ? nil : modelMeta
        total = nil
        ofWindow = windowText.map { "of \($0)" }
        trailing = nil
        segments = []
        mark = context.autoCompactAt.map(fraction)
        markLabel = context.autoCompactAt.map { "auto-compact · \(nativeContextTokens($0)) ↑" }
        rows = []
        free = nil
        largest = []
        note = nil
        emphasis = nil
        footnote = nil
        summaryEntryID = context.summaryEntryID
        compactOffered = context.compacting == nil

        if let run = context.compacting {
            variant = .compacting(startedAt: run.startedAt)
            title = "Compacting"
            meta = nil
            ofWindow = nil
            mark = nil
            markLabel = nil
            emphasis = (run.tokens ?? context.tokens).map(nativeContextTokens)
            let size = emphasis.map { "Summarizing \($0) into a short brief." } ?? "Summarizing the conversation into a short brief."
            note = size + (context.keepRecent.map { " The last \(nativeContextTokens($0)) stay as they are." } ?? "")
            return
        }
        guard let tokens = context.tokens, let window, window > 0 else {
            if let estimate = context.estimate {
                variant = .compacted
                meta = "just compacted"
                total = "~" + nativeContextTokens(estimate)
                trailing = "estimate"
                segments = [Segment(part: nil, fraction: fraction(estimate))]
                note = "The agent reports the exact number after its next reply."
                    + (context.before.map { " Was \(nativeContextTokens($0))." } ?? "")
            } else {
                variant = .empty
                note = "The agent reports its context after its first reply."
            }
            return
        }
        let percent = nativeContextPercent(tokens, of: window)
        total = nativeContextTokens(tokens)
        trailing = "\(Int(percent.rounded()))%"
        if let split {
            segments = [Segment(part: .system, fraction: fraction(split.system)),
                        Segment(part: .instructions, fraction: fraction(split.instructions)),
                        Segment(part: .messages, fraction: fraction(split.messages)),
                        Segment(part: .toolResults, fraction: fraction(split.toolResults))].filter { $0.fraction > 0 }
        } else {
            segments = [Segment(part: nil, fraction: fraction(tokens))]
        }
        if percent > 85 {
            variant = .almostFull
            title = "Context almost full"
            meta = nil
            note = Self.almostFullNote(split: split, autoCompact: context.autoCompact ?? false, at: context.autoCompactAt)
            return
        }
        guard let split else { return }
        let files = split.instructionFiles
        let instructions = files.isEmpty ? "Instructions" : "Instructions · " + files[0] + (files.count > 1 ? " +\(files.count - 1)" : "")
        rows = [Row(part: .system, label: "System prompt and tools", value: nativePreciseTokens(split.system)),
                Row(part: .instructions, label: instructions, value: nativePreciseTokens(split.instructions)),
                Row(part: .messages, label: "Messages", value: nativePreciseTokens(split.messages)),
                Row(part: .toolResults, label: "Tool results", value: nativePreciseTokens(split.toolResults))]
        free = nativePreciseTokens(max(0, window - tokens))
        largest = context.largest.map { Largest(entryID: $0.entryID, kind: $0.kind, label: $0.label, value: nativePreciseTokens($0.tokens)) }
        footnote = Self.footnoteText
    }

    /// "Tool results are 138k of it. The agent will compact on its own at 184k, before its next
    /// reply. Compact now to say what the summary should keep."
    static func almostFullNote(split: NativeContextSplit?, autoCompact: Bool, at mark: Int?) -> String {
        var parts: [String] = []
        if let split {
            let named: [(String, Int)] = [("The system prompt and tools are", split.system), ("Instructions are", split.instructions),
                                          ("Messages are", split.messages), ("Tool results are", split.toolResults)]
            if let (label, tokens) = named.max(by: { $0.1 < $1.1 }), tokens > 0 {
                parts.append("\(label) \(nativeContextTokens(tokens)) of it.")
            }
        }
        if autoCompact {
            parts.append("The agent will compact on its own" + (mark.map { " at \(nativeContextTokens($0))" } ?? "") + ", before its next reply.")
        } else {
            parts.append("The agent will not compact on its own.")
        }
        parts.append("Compact now to say what the summary should keep.")
        return parts.joined(separator: " ")
    }
}

/// "claude-opus-4" from "anthropic/claude-opus-4": the model without its provider.
public func nativeContextModelName(_ model: String) -> String {
    guard let slash = model.firstIndex(of: "/") else { return model }
    return String(model[model.index(after: slash)...])
}

/// "0:08" since a compaction started.
public func nativeElapsedClock(from start: Double, now: Date) -> String {
    let seconds = max(0, Int((now.timeIntervalSince1970 * 1000 - start) / 1000))
    return seconds >= 3600
        ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        : String(format: "%d:%02d", seconds / 60, seconds % 60)
}

// MARK: - Compactions in the thread

/// A compaction where it happened in the thread (ContextIdeas › In the thread): one line like
/// other thread events, and what the agent kept, opened in place.
public struct NativeCompactionRow: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case normal
        /// The context overflowed: said in `lantern`.
        case warning
        /// Stopped or failed: nothing changed.
        case quiet
    }

    /// The thread entry (the summary's, or the live row's).
    public var id: String
    /// "Compacted automatically", "You compacted", "Context overflowed · compacted and retried",
    /// "Compaction stopped · nothing changed", "Compacting context…".
    public var title: String
    /// "184k → 23k", or "184k" while it runs.
    public var tokens: String?
    public var tone: Tone
    public var running: Bool
    /// What the agent kept, as pi wrote it (Copy); nil while it runs.
    public var summary: String?
    /// The summary in the agent's own sections, with the files it changed as names.
    public var sections: [NativeSummarySection]
    /// "2.1k", the summary's size in tokens.
    public var summarySize: String?
    /// Why it failed, for the tooltip.
    public var error: String?

    public init(entryID: String, compaction: NativeCompaction) {
        id = entryID
        running = compaction.phase == .running
        error = compaction.error
        let before = compaction.tokensBefore.map(nativeContextTokens)
        switch compaction.phase {
        case .running:
            title = "Compacting context…"
            tokens = before
            tone = .normal
        case .stopped:
            title = "Compaction stopped · nothing changed"
            tokens = nil
            tone = .quiet
        case .failed:
            title = "Compaction failed · nothing changed"
            tokens = nil
            tone = .quiet
        case .done:
            switch compaction.reason {
            case .threshold?: title = "Compacted automatically"; tone = .normal
            case .manual?: title = "You compacted"; tone = .normal
            case .overflow?: title = "Context overflowed · compacted and retried"; tone = .warning
            case .unknown?, nil: title = "Compacted"; tone = .normal
            }
            tokens = before.map { before in compaction.tokensAfter.map { "\(before) → \(nativeContextTokens($0))" } ?? before }
        }
        let summary = compaction.phase == .done ? compaction.summary : nil
        self.summary = summary
        sections = summary.map(nativeSummarySections) ?? []
        summarySize = summary.map { nativePreciseTokens(($0.utf8.count + 3) / 4) }
    }
}

/// One section of what the agent kept: its heading as the agent wrote it, its text (inline
/// Markdown, parsed once), and for "Files changed" the files by name.
public struct NativeSummarySection: Equatable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var text: AttributedString
    public var files: [String]

    public init(id: Int, title: String, text: AttributedString, files: [String] = []) {
        self.id = id
        self.title = title
        self.text = text
        self.files = files
    }
}

/// pi's summary as the thread shows it: a section per heading (`## Goal`, `### Done`), the files
/// it changed (`<modified-files>`) as a "Files changed" section of names, and the files it read
/// left out.
public func nativeSummarySections(_ summary: String) -> [NativeSummarySection] {
    var sections: [NativeSummarySection] = []
    var title = ""
    var lines: [String] = []
    var tag: String?
    var files: [String] = []
    func flush() {
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !text.isEmpty else { return }
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        sections.append(NativeSummarySection(id: sections.count, title: title, text: parsed))
        lines = []
    }
    for raw in summary.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if let open = tag {
            if line == "</\(open)>" {
                if open == "modified-files", !files.isEmpty {
                    flush()
                    sections.append(NativeSummarySection(id: sections.count, title: "Files changed", text: AttributedString(), files: files))
                    title = ""
                }
                tag = nil
                files = []
            } else if open == "modified-files", !line.isEmpty {
                files.append((line as NSString).lastPathComponent)
            }
            continue
        }
        if line == "<read-files>" || line == "<modified-files>" {
            tag = String(line.dropFirst().dropLast())
            continue
        }
        if line.hasPrefix("#"), let space = line.firstIndex(of: " "), line[..<space].allSatisfy({ $0 == "#" }) {
            flush()
            title = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            continue
        }
        lines.append(raw)
    }
    flush()
    return sections
}

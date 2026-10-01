import Foundation

public enum NativeGoalState: String, Codable, Hashable, Sendable, CaseIterable {
    case working, checking, met, paused, needsYou
}

/// One conversation's goal, projected from the pi extension's durable session entries.
public struct NativeGoal: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var revision: Int
    public var text: String
    public var state: NativeGoalState
    public var elapsedSeconds: Double
    public var tokensUsed: Int
    public var timeLimitSeconds: Double?
    public var tokenLimit: Int?
    public var reason: String?
    public var evidence: String?
    public var summary: String?
    public var checkedBy: String?
    public var confirmationRequired: Bool?
    public var confirmedByUser: Bool?
    /// Epoch milliseconds at the start of the current active interval. No server clock ticks.
    public var runningSince: Double?
    public var checkCount: Int?

    public init(id: String, revision: Int = 1, text: String, state: NativeGoalState,
                elapsedSeconds: Double = 0, tokensUsed: Int = 0, timeLimitSeconds: Double? = nil,
                tokenLimit: Int? = nil, reason: String? = nil, evidence: String? = nil, summary: String? = nil,
                checkedBy: String? = nil, confirmationRequired: Bool? = nil, confirmedByUser: Bool? = nil,
                runningSince: Double? = nil, checkCount: Int? = nil) {
        self.id = id
        self.revision = revision
        self.text = text
        self.state = state
        self.elapsedSeconds = elapsedSeconds
        self.tokensUsed = tokensUsed
        self.timeLimitSeconds = timeLimitSeconds
        self.tokenLimit = tokenLimit
        self.reason = reason
        self.evidence = evidence
        self.summary = summary
        self.checkedBy = checkedBy
        self.confirmationRequired = confirmationRequired
        self.confirmedByUser = confirmedByUser
        self.runningSince = runningSince
        self.checkCount = checkCount
    }

    public var isActive: Bool { state == .working || state == .checking }
    public var clockStart: Date? {
        guard isActive, let runningSince else { return nil }
        return Date(timeIntervalSince1970: runningSince / 1000 - elapsedSeconds)
    }
    public var timeLabel: String { timeLabel(at: Date()) }
    public func elapsed(at date: Date) -> Double {
        elapsedSeconds + (isActive ? runningSince.map { max(0, date.timeIntervalSince1970 - $0 / 1000) } ?? 0 : 0)
    }
    public func timeLabel(at date: Date) -> String {
        let seconds = Int(min(max(elapsed(at: date), 0), Double(Int.max / 2)))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
    public var metaLabel: String {
        switch state {
        case .paused: "paused by you · the clock stops"
        case .needsYou: shortLabel(reason?.lowercased()) ?? "waiting for your input"
        case .checking: shortLabel(reason) ?? "checking · commands unavailable"
        case .met: tokenLabel + (confirmedByUser == true ? "" : shortLabel(summary).map { " · " + $0 } ?? "")
        case .working: tokenLabel
        }
    }
    /// Notifications never include the user condition, evaluator feedback, or tool quotes.
    public var notificationLabel: String {
        state == .met ? tokenLabel + (confirmedByUser == true ? " · confirmed by you" : " · recorded evidence accepted") : "The goal stopped and needs your input."
    }
    private var tokenLabel: String {
        tokensUsed >= 1000 ? "\(tokensUsed / 1000)k tokens" : "\(tokensUsed) tokens"
    }

    private func shortLabel(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = (text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? "")
            .replacingOccurrences(of: id, with: " ")
            .replacingOccurrences(of: #"\b(?:entryId|toolCallId|goalId)\s*[:=]?\s*\S+|\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b|\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{8,}\b|\b[\w-]{24,}\b|"[^"\n]*"|`[^`\n]*`"#,
                                  with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[^\p{L}\p{N} ,.:;!?·/+-]"#, with: " ", options: .regularExpression)
        var result = ""
        for word in line.split(whereSeparator: \.isWhitespace) {
            let next = result.isEmpty ? String(word) : result + " " + word
            guard next.utf16.count <= 40 else { break }
            result = next
        }
        return result.isEmpty ? nil : result
    }

    public var isValid: Bool {
        UUID(uuidString: id) != nil && revision >= 1 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.utf16.count <= 32768 && elapsedSeconds.isFinite && elapsedSeconds >= 0 && tokensUsed >= 0
            && (timeLimitSeconds == nil || timeLimitSeconds!.isFinite && timeLimitSeconds! > 0)
            && (tokenLimit == nil || tokenLimit! > 0)
            && (reason?.utf16.count ?? 0) <= 4096 && (evidence?.utf16.count ?? 0) <= 8192
            && (summary?.utf16.count ?? 0) <= 40 && (checkedBy?.utf16.count ?? 0) <= 256
            && (checkedBy == nil || !checkedBy!.contains(where: { $0.isNewline || $0.isASCII && ($0.asciiValue! < 32 || $0.asciiValue! == 127) }))
            && (runningSince == nil || runningSince!.isFinite && runningSince! >= 0)
            && (checkCount == nil || checkCount! >= 0 && checkCount! <= 25)
            && (confirmationRequired != true || state == .needsYou)
            && (confirmedByUser != true || state == .met)
    }

    /// Only the dedicated widget is decoded. Other machine widgets remain invisible.
    public static func readWidget(_ text: String) -> NativeGoal? {
        let prefix = "SHEPHERD_GOAL:"
        guard text.hasPrefix(prefix), text.utf8.count <= 256 * 1024,
              let goal = try? JSONDecoder().decode(Self.self, from: Data(text.dropFirst(prefix.count).utf8)), goal.isValid else { return nil }
        return goal
    }
}

public enum NativeGoalAction: Codable, Hashable, Sendable {
    case set(text: String, timeLimitSeconds: Double? = nil, tokenLimit: Int? = nil)
    case pause, resume, clear, confirm
    /// Omitted limits preserve them; clear flags emit explicit null to lift them.
    case edit(text: String, timeLimitSeconds: Double? = nil, tokenLimit: Int? = nil,
              clearTimeLimit: Bool? = nil, clearTokenLimit: Bool? = nil)

    public var isValid: Bool {
        switch self {
        case .set(let text, let time, let tokens):
            validText(text) && (time == nil || time!.isFinite && time! > 0) && (tokens == nil || tokens! > 0)
        case .edit(let text, let time, let tokens, let clearTime, let clearTokens):
            validText(text) && (time == nil || time!.isFinite && time! > 0) && (tokens == nil || tokens! > 0)
                && !(clearTime == true && time != nil) && !(clearTokens == true && tokens != nil)
        default: true
        }
    }
    private func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= 32768
    }

    /// Internal extension commands are typed controls, never instructions to the working model.
    public var command: String {
        var object: [String: Any]
        switch self {
        case .set(let text, let time, let tokens):
            object = ["action": "set", "text": text]
            if let time { object["timeLimitSeconds"] = time }
            if let tokens { object["tokenLimit"] = tokens }
        case .edit(let text, let time, let tokens, let clearTime, let clearTokens):
            object = ["action": "edit", "text": text]
            if let time { object["timeLimitSeconds"] = time }
            if let tokens { object["tokenLimit"] = tokens }
            if clearTime == true { object["timeLimitSeconds"] = NSNull() }
            if clearTokens == true { object["tokenLimit"] = NSNull() }
        case .pause: object = ["action": "pause"]
        case .resume: object = ["action": "resume"]
        case .clear: object = ["action": "clear"]
        case .confirm: object = ["action": "confirm"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return "/shepherd-goal " + json
    }
}

import Foundation
import ShepherdProtocol

/// An explicit worker report, not evidence of task admission, completion or publication.
/// Each successful call replaces the reported plan for its native turn, never earlier calls.
public struct NativeProjectPlan: Equatable, Sendable {
    public enum State: String, Decodable, Equatable, Sendable {
        case pending, current, done, failed
    }

    public struct Step: Decodable, Equatable, Sendable {
        public var text: String
        public var state: State
    }

    public var steps: [Step]

    /// Only the exact tool's complete v1 result is a plan. Arguments, prose, partial results,
    /// errors and unknown versions remain ordinary tool activity with their raw output intact.
    public init?(_ message: NativeThreadMessage) {
        guard message.role == "toolResult", message.toolName == "project_plan",
              message.isError != true, !message.truncated,
              message.status == nil || message.status == "complete",
              message.blocks.count == 1, let block = message.blocks.first, block.kind == .text,
              block.text.utf8.count <= 65_536 else { return nil }
        struct Report: Decodable {
            var version: Int
            var steps: [Step]
        }
        guard let report = try? JSONDecoder().decode(Report.self, from: Data(block.text.utf8)),
              report.version == 1, (1...20).contains(report.steps.count),
              report.steps.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.text.utf16.count <= 500 }) else { return nil }
        steps = report.steps.map { Step(text: NativeRedaction.projectData($0.text), state: $0.state) }
    }
}

public extension NativeTurnPresentation {
    /// Last explicit successful update in transcript order, confined to this native turn.
    /// Stop, tool errors and turn settlement never change the states the worker reported.
    var latestProjectPlan: NativeProjectPlan? {
        for item in items.reversed() {
            guard case .activity(_, let bursts) = item else { continue }
            for burst in bursts.reversed() {
                for call in burst.calls.reversed() {
                    if let plan = call.projectPlan { return plan }
                }
            }
        }
        return nil
    }
}

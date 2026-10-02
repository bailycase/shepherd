import Foundation

/// Keep readable goal lines separate from full feedback, errors and proof.
public struct NativeGoalRecord: Equatable, Sendable {
    public let line: String
    public let evidence: String?
    public let isClosing: Bool
    public let showsDetails: Bool

    public init(_ text: String) {
        isClosing = text.hasPrefix("Goal met")
        let split = ["Details", "Evidence"].compactMap { label in
            text.range(of: "\n\n\(label):\n").map { (label: label, range: $0) }
        }.min { $0.range.lowerBound < $1.range.lowerBound }
        if !text.hasPrefix("Goal set"), let split {
            line = String(text[..<split.range.lowerBound])
            evidence = String(text[split.range.upperBound...])
            showsDetails = split.label == "Details"
        } else if let title = ["Goal met", "Goal check", "Goal needs you"].first(where: { text.hasPrefix($0) }) {
            line = title
            evidence = text
            showsDetails = !isClosing
        } else {
            line = text
            evidence = nil
            showsDetails = false
        }
    }
}

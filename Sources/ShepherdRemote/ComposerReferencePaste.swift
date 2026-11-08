import Foundation
import ShepherdProtocol

/// A reference pasted into the draft becomes a chip (RefPasted): "A copied reference pastes as a
/// chip, never as a link. Plain text pastes as text."
public enum ComposerReferencePaste {
    /// The references a paste brought into `draft` (text that grew by more than a keystroke from
    /// `previous`), each a whole word, and the draft without them. Nil when it brought none.
    public static func extract(_ draft: String, previous: String) -> (draft: String, references: [DesignReference])? {
        guard draft.count > previous.count + 1, draft.localizedCaseInsensitiveContains(DesignReference.scheme + "://") else { return nil }
        let known = Set(tokens(previous).compactMap { DesignReference(string: $0)?.string })
        var references: [DesignReference] = []
        var kept: [Substring] = []
        var cleaned = ""
        // Split on whitespace but keep the draft's own spacing around what stays.
        var index = draft.startIndex
        while index < draft.endIndex {
            if draft[index].isWhitespace {
                cleaned.append(draft[index])
                index = draft.index(after: index)
                continue
            }
            let end = draft[index...].firstIndex(where: \.isWhitespace) ?? draft.endIndex
            let word = draft[index..<end]
            if let reference = DesignReference(string: String(word)), !known.contains(reference.string) {
                references.append(reference)
            } else {
                kept.append(word)
                cleaned += word
            }
            index = end
        }
        guard !references.isEmpty else { return nil }
        return (tidy(cleaned), references)
    }

    public static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Runs of spaces the chips left collapse to one, and the ends lose theirs.
    public static func tidy(_ text: String) -> String {
        var out = ""
        var lastSpace = false
        for character in text {
            if character == " " {
                if lastSpace { continue }
                lastSpace = true
            } else {
                lastSpace = false
            }
            out.append(character)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

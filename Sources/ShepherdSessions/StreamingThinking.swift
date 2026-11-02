import Foundation

/// The same whitespace rules as RPCContentBlock.normalizedThinking, visiting only new text.
/// Keep the last grapheme open: a later chunk can extend it with a combining mark or LF.
struct StreamingThinking {
    private var text = ""
    private var tail = ""
    private var leading = ""
    private var trailing = ""
    private var separator = 0
    private var inLine = false
    private(set) var normalized = ""

    mutating func append(_ chunk: String) {
        let incoming = tail + chunk
        guard !incoming.isEmpty else { return }
        let last = incoming.index(before: incoming.endIndex)
        for character in incoming[..<last] { consume(character) }
        tail = String(incoming[last...])
        var finished = self
        for character in tail { finished.consume(character) }
        normalized = finished.text
    }

    private mutating func consume(_ character: Character) {
        if character == "\r\n" {
            consume("\r")
            consume("\n")
        } else if character == "\n" {
            separator = inLine ? 1 : (separator > 0 ? 2 : 0)
            inLine = false
            leading = ""
        } else if character.isWhitespace {
            if inLine { trailing.append(character) } else { leading.append(character) }
        } else {
            if !text.isEmpty {
                text += trailing
                if !inLine {
                    text += separator == 2 ? "\n\n" : (separator == 1 ? "\n" : "")
                    text += leading
                }
            }
            text.append(character)
            trailing = ""
            leading = ""
            separator = 0
            inLine = true
        }
    }
}

extension String {
    /// A name, title or path made safe to print as one line of a list an agent reads: control characters gone (a line break or tab becomes a
    /// space), invisible formatting characters gone, runs of whitespace collapsed, and at most `limit` characters (graphemes) and
    /// `limit * 4` UTF-8 bytes (480 for a label, 960 for a path). The byte cap stops one letter followed by thousands of combining marks,
    /// which is a single character. The cut is on a character boundary, so no scalar is split.
    public func listLabel(limit: Int = 120) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control: if scalar.properties.isWhitespace { kept.append(" ") }
            case .lineSeparator, .paragraphSeparator: kept.append(" ")
            case .format: break
            default: kept.append(scalar)
            }
        }
        let flat = String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let byteLimit = limit * 4
        if flat.count <= limit && flat.utf8.count <= byteLimit { return flat }
        var out = "", bytes = 0, characters = 0
        for character in flat {
            let size = character.utf8.count
            guard characters < limit - 1, bytes + size <= byteLimit - "…".utf8.count else { break }
            out.append(character)
            bytes += size
            characters += 1
        }
        return out + "…"
    }
}

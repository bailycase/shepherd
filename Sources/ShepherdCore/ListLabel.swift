extension String {
    /// A name, title or path made safe to print as one line of a list an agent reads: control characters gone (a line break or tab becomes a
    /// space), invisible formatting characters gone, runs of whitespace collapsed, and at most `limit` characters.
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
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }
}

import Foundation

/// The document shell of an HTML specimen. Fragments keep using the ordinary board wrapper.
/// Reuse the HTML tokenizer so comments, quoted attributes and raw script/style text cannot
/// be mistaken for document boundaries. No files are read and no scripts are executed here.
public struct DesignSpecimenDocument: Sendable {
    public let html: String
    public let head: String
    public let body: String
    public let content: String

    public init?(_ source: String) {
        let bytes = Array(source.utf8)
        var reader = HTMLTokenizer(bytes: bytes, range: bytes.indices)
        var tags: [HTMLTag] = []
        while let tag = reader.next() {
            tags.append(tag)
            if !tag.isEnd, ["script", "style", "title", "textarea"].contains(tag.name) {
                reader.skipRawText(of: tag.name)
            }
        }
        guard let body = tags.first(where: { $0.name == "body" && !$0.isEnd }) else { return nil }
        let html = tags.first { $0.name == "html" && !$0.isEnd && $0.range.upperBound <= body.range.lowerBound }
        let start = html?.range.upperBound ?? 0
        let end = tags.first { $0.name == "body" && $0.isEnd && $0.range.lowerBound >= body.range.upperBound }?.range.lowerBound
            ?? tags.first { $0.name == "html" && $0.isEnd && $0.range.lowerBound >= body.range.upperBound }?.range.lowerBound
            ?? bytes.count
        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        var head = Array(bytes[start..<body.range.lowerBound])
        for tag in tags.reversed() where tag.name == "head" && tag.range.lowerBound >= start && tag.range.upperBound <= body.range.lowerBound {
            head.removeSubrange((tag.range.lowerBound - start)..<(tag.range.upperBound - start))
        }
        self.html = html.map { text($0.range) } ?? "<html>"
        self.head = String(decoding: head, as: UTF8.self)
        self.body = text(body.range)
        self.content = text(body.range.upperBound..<end)
    }
}

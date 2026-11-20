import Foundation
import ShepherdProtocol
import ShepherdTestKit
import Testing

struct WireCodecTests {
    @Test func wireMatchesGolden() throws {
        let golden = try #require(WireGolden.read()["codec"] as? [String: [String: String]])
        let count = try check(RemoteRequestTests.samples, in: "RemoteMessage", family: "remote-request", golden: golden)
            + check(RemoteReplyTests.samples, in: "RemoteMessage", family: "remote-reply", golden: golden)
            + check(ExtensionMessageTests.samples, in: "ExtensionMessage", family: "extension-request", golden: golden)
            + check(ExtensionReplyTests.samples, in: "ExtensionMessage", family: "extension-reply", golden: golden)
        let summary = "\(count) codec cases matched the golden"
        try ValidationEvidence.record(in: ValidationEvidence.directory, step: "codec-golden", status: "passed",
                                      expected: summary, actual: summary)
    }

    private func check<Message: Codable & Equatable>(_ samples: [Message], in file: String, family: String,
                                                      golden: [String: [String: String]]) throws -> Int {
        let cases = try declaredCases(Message.self, in: file)
        let fixtures = Dictionary(grouping: samples, by: Wire.caseName)
        let actualNames = Set(fixtures.keys)
        try #require(cases == actualNames, "\(Message.self): missing fixtures \(cases.subtracting(actualNames).sorted()); unexpected \(actualNames.subtracting(cases).sorted())")
        let lines = try #require(golden[family], "missing codec family: \(family)")
        let recorded = Set(lines.keys)
        try #require(cases == recorded, "\(family): missing goldens \(cases.subtracting(recorded).sorted()); unexpected \(recorded.subtracting(cases).sorted())")

        for name in cases.sorted() {
            let fixture = try #require(fixtures[name]?.first)
            let encoded = try NDJSON.encode(fixture)
            let path = "\(family).\(name)"
            let previous = try #require(lines[name])
            let data = Data(previous.utf8)
            if encoded != data {
                let old = try WireGolden.object(data)
                let new = try WireGolden.object(encoded)
                try WireGolden.check(old, new, at: path, step: "codec-golden")
                // Same fields, changed framing, key order or escaping.
                let line = String(decoding: encoded, as: UTF8.self)
                try WireGolden.fail(step: "codec-golden", expected: "\(path) = \(previous.debugDescription)",
                                    actual: "\(path) = \(line.debugDescription)")
            }
            try #require(data.last == 0x0A, "\(path) must be newline terminated")
            try #require(NDJSON.decode(Message.self, from: data.dropLast()) == fixture, "\(path) did not decode to its fixture")
        }
        return cases.count
    }

    // Associated-value enums are not CaseIterable. Read their top-level case declarations,
    // independent of the fixture list and of what the encoder emits. The fixture suites'
    // exhaustive switches still catch new cases at compile time.
    private func declaredCases<Message>(_ type: Message.Type, in file: String) throws -> Set<String> {
        let url = WireGolden.root.appendingPathComponent("Sources/ShepherdProtocol/\(file).swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "public enum \(type):"))
        let end = try #require(source[start.upperBound...].range(of: "\n}"))
        let declaration = source[start.upperBound..<end.lowerBound]
        let pattern = /(?m)^    (?:indirect )?case (\w+)/
        return Set(declaration.matches(of: pattern).map { String($0.1) })
    }
}

import Foundation
import ShepherdProtocol
import ShepherdTestKit
import Testing

struct WireCodecTests {
    @Test func wireMatchesGolden() throws {
        try ValidationGolden.check("c-wire.json", from: #filePath, step: "codec-golden",
                                   completion: "c-wire codec samples matched the golden") { golden in
            let actual = try [
                "remote-request": lines(RemoteRequestTests.wireSamples, in: "RemoteMessage"),
                "remote-reply": lines(RemoteReplyTests.wireSamples, in: "RemoteMessage"),
                "extension-request": lines(ExtensionMessageTests.samples, in: "ExtensionMessage"),
                "extension-reply": lines(ExtensionReplyTests.samples, in: "ExtensionMessage"),
            ]
            guard let expected = golden["codec"] as? [String: [String: [String]]] else {
                throw ValidationGolden.Difference(expected: "c-wire.codec", actual: "Missing or invalid codec golden")
            }
            func fields(_ codec: [String: [String: [String]]]) throws -> [String: [String: [[String: Any]]]] {
                try codec.mapValues { try $0.mapValues { try $0.map { try ValidationGolden.object(Data($0.utf8)) } } }
            }
            try ValidationGolden.compare(fields(expected), fields(actual), at: "c-wire.codec")
            // If the fields match, still pin framing, key order and escaping byte for byte.
            try ValidationGolden.compare(expected, actual, at: "c-wire.codec")
        }
    }

    private func lines<Message: Codable & Equatable>(_ samples: [Message], in file: String) throws -> [String: [String]] {
        let cases = try declaredCases(Message.self, in: file)
        let fixtures = Dictionary(grouping: samples, by: Wire.caseName)
        let names = Set(fixtures.keys)
        guard cases == names else {
            throw ValidationGolden.Difference(expected: "c-wire has fixtures for every \(Message.self) case",
                actual: "Missing: \(cases.subtracting(names).sorted()); unexpected: \(names.subtracting(cases).sorted())")
        }
        var lines: [String: [String]] = [:]
        for name in fixtures.keys.sorted() {
            lines[name] = try fixtures[name, default: []].enumerated().map { index, fixture in
                let path = "c-wire.\(Message.self).\(name)[\(index)]"
                let data = try NDJSON.encode(fixture)
                guard data.last == 0x0A else {
                    throw ValidationGolden.Difference(expected: "\(path) ends with a newline", actual: "No trailing newline")
                }
                // These are the same bytes the golden must contain.
                do {
                    if try NDJSON.decode(Message.self, from: data.dropLast()) == fixture {
                        return String(decoding: data, as: UTF8.self)
                    }
                    throw ValidationGolden.Difference(expected: "\(path) decodes to its fixture", actual: "Decoded value did not match")
                } catch let diff as ValidationGolden.Difference {
                    throw diff
                } catch {
                    throw ValidationGolden.Difference(expected: "\(path) decodes to its fixture", actual: String(describing: error))
                }
            }
        }
        return lines
    }

    // Associated-value enums are not CaseIterable. Read their top-level case declarations,
    // independent of the fixture list and of what the encoder emits. The fixture suites'
    // exhaustive switches still catch new cases at compile time.
    private func declaredCases<Message>(_ type: Message.Type, in file: String) throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/ShepherdProtocol/\(file).swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "public enum \(type):"),
              let end = source[start.upperBound...].range(of: "\n}") else {
            throw ValidationGolden.Difference(expected: "c-wire finds \(type) in \(file).swift", actual: "Enum declaration not found")
        }
        let declaration = source[start.upperBound..<end.lowerBound]
        let pattern = /(?m)^    (?:indirect )?case (\w+)/
        return Set(declaration.matches(of: pattern).map { String($0.1) })
    }
}

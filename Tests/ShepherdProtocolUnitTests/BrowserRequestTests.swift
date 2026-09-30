import Foundation
import Testing
@testable import ShepherdProtocol

/// What an agent's browser tools ask (`BrowserRequest`) and how the page answers
/// (`BrowserOutcome`), on the extension socket's 1 MiB frames.
@Suite("Browser requests and outcomes")
struct BrowserRequestTests {
    @Test func aRequestOmitsWhatItDoesNotSet() throws {
        let click = try Wire.object(BrowserRequest.click(ref: "e12", double: false, note: nil))
        #expect(Set(click.keys) == ["action", "ref"])
        let full = try Wire.object(BrowserRequest.type(ref: "e3", text: "hi", clear: true, submit: true, note: "filling in"))
        #expect(Set(full.keys) == ["action", "ref", "text", "clear", "submit", "note"])
        #expect(full["action"] as? String == "type" && full["clear"] as? Bool == true)
        #expect(Set(try Wire.object(BrowserRequest.console(clear: false)).keys) == ["action"])
        #expect(Set(try Wire.object(BrowserRequest.reload(note: nil)).keys) == ["action"])
    }

    @Test func noRequestNamesAnAgent() throws {
        // The agent is the connection's: nothing in any request could name one.
        let requests: [BrowserRequest] = [
            .open(url: "http://a.b/", note: "n"), .read(selector: "main", maxChars: 10), .click(ref: "e1", double: true, note: "n"),
            .type(ref: "e1", text: "x", clear: true, submit: true, note: "n"), .press(key: "Enter", note: "n"),
            .scroll(direction: "down", amount: 1, ref: "e1", note: "n"), .wait(text: "x", ref: "e1", gone: true, ms: 1, timeout: 1),
            .screenshot(ref: "e1"), .console(clear: true), .eval(expression: "1", note: "n"),
            .back(note: "n"), .forward(note: "n"), .reload(note: "n"),
        ]
        for request in requests {
            let keys = Set(try Wire.object(request).keys)
            #expect(keys.isDisjoint(with: ["agentID", "agent", "agentId"]), "\(request)")
        }
    }

    @Test(arguments: [
        #"{"action":"teleport"}"#, #"{"url":"http://a.b/"}"#, #"{"action":"click"}"#, #"{"action":"open"}"#, #"{"action":"eval"}"#,
        #"{"action":"type","ref":"e1"}"#, #"{"action":"press"}"#,
    ])
    func aMalformedRequestFailsToDecode(json: String) {
        #expect(throws: DecodingError.self) { try Wire.decode(BrowserRequest.self, json) }
    }

    @Test func aRequestTakesWhatAToolWritesByHand() throws {
        #expect(try Wire.decode(BrowserRequest.self, #"{"action":"scroll","ref":"e4"}"#)
            == .scroll(direction: nil, amount: nil, ref: "e4", note: nil))
        #expect(try Wire.decode(BrowserRequest.self, #"{"action":"wait","ms":250}"#)
            == .wait(text: nil, ref: nil, gone: false, ms: 250, timeout: nil))
        #expect(try Wire.decode(BrowserRequest.self, ##"{"action":"read","maxChars":45000,"selector":"#form"}"##)
            == .read(selector: "#form", maxChars: 45_000))
    }

    @Test func onlyTheReadingsWorkAfterATakeOver() {
        let readings: Set<BrowserRequest.Action> = [.read, .wait, .screenshot, .console]
        let samples: [BrowserRequest] = [
            .open(url: "u", note: nil), .read(selector: nil, maxChars: nil), .click(ref: "e", double: false, note: nil),
            .type(ref: "e", text: "", clear: false, submit: false, note: nil), .press(key: "k", note: nil),
            .scroll(direction: "up", amount: nil, ref: nil, note: nil), .wait(text: "t", ref: nil, gone: false, ms: nil, timeout: nil),
            .screenshot(ref: nil), .console(clear: false), .eval(expression: "1", note: nil), .back(note: nil), .forward(note: nil), .reload(note: nil),
        ]
        #expect(Set(samples.map(\.action)) == Set(BrowserRequest.Action.allCases))
        for request in samples { #expect(request.isObservation == readings.contains(request.action), "\(request.action)") }
    }

    @Test func aNoteIsOnlyOnTheToolsThatActOnThePage() {
        #expect(BrowserRequest.click(ref: "e", double: false, note: "n").note == "n")
        #expect(BrowserRequest.eval(expression: "1", note: "n").note == "n")
        #expect(BrowserRequest.read(selector: nil, maxChars: nil).note == nil)
        #expect(BrowserRequest.screenshot(ref: nil).note == nil)
    }

    // MARK: Outcomes

    @Test func aResultIsTheReplyWithTheRequestsID() {
        let image = BrowserImage(data: "QUJD", mimeType: "image/jpeg")
        #expect(BrowserOutcome.result(text: "ok", image: nil).reply(id: 7) == .browserResult(id: 7, text: "ok", image: nil))
        #expect(BrowserOutcome.result(text: "shot", image: image).reply(id: 8) == .browserResult(id: 8, text: "shot", image: image))
        #expect(BrowserOutcome.failure(code: "taken_over", message: "no").reply(id: 9) == .error(id: 9, code: "taken_over", message: "no"))
        #expect(BrowserOutcome.text("hi") == .result(text: "hi", image: nil))
    }

    @Test func longTextIsCutAtSixtyFourKilobytesOnACharacterBoundary() {
        let text = String(repeating: "ünïcode 日本語 🙂\n", count: 20_000)
        let cut = BrowserOutcome.truncated(text)
        #expect(cut.utf8.count <= BrowserOutcome.maxTextBytes)
        #expect(cut.hasSuffix(BrowserOutcome.truncationMark))
        #expect(String(decoding: Array(cut.utf8), as: UTF8.self) == cut, "no character is split")
        #expect(BrowserOutcome.truncated("short") == "short")
        let exact = String(repeating: "a", count: BrowserOutcome.maxTextBytes)
        #expect(BrowserOutcome.truncated(exact) == exact)
        #expect(BrowserOutcome.truncated(exact + "a").utf8.count == BrowserOutcome.maxTextBytes)
    }

    @Test func aBigImageIsLeftOutAndSaidSo() throws {
        let big = BrowserImage(data: String(repeating: "A", count: BrowserOutcome.maxImageBase64Bytes + 1), mimeType: "image/jpeg")
        guard case .browserResult(3, let text, let image) = BrowserOutcome.result(text: "Screenshot", image: big).reply(id: 3) else {
            Issue.record("expected a result")
            return
        }
        #expect(image == nil && text.contains("screenshot was too large"))
        let fits = BrowserImage(data: String(repeating: "A", count: BrowserOutcome.maxImageBase64Bytes), mimeType: "image/jpeg")
        #expect(BrowserOutcome.result(text: "Screenshot", image: fits).reply(id: 4) == .browserResult(id: 4, text: "Screenshot", image: fits))
    }

    /// The worst case still fits a frame: text at its cap, every byte an escape, and the largest image.
    @Test func theLargestReplyStaysUnderTheFrameCap() throws {
        let worst = String(repeating: "\u{1}", count: BrowserOutcome.maxTextBytes)
        let image = BrowserImage(data: String(repeating: "A", count: BrowserOutcome.maxImageBase64Bytes), mimeType: "image/jpeg")
        let line = try NDJSON.encode(BrowserOutcome.result(text: worst, image: image).reply(id: 1))
        #expect(line.count - 1 <= NDJSON.maxPayloadBytes)
        let failure = try NDJSON.encode(BrowserOutcome.failure(code: "x", message: String(repeating: "\u{1}", count: 100_000)).reply(id: 2))
        #expect(failure.count - 1 <= NDJSON.maxPayloadBytes)
    }
}

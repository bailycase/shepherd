import Foundation
import Testing
@testable import ShepherdProtocol

/// Thinking blocks as pi-ai stores them (`ThinkingContent`: `thinking`, `thinkingSignature`,
/// `redacted`), per provider, decode to the reasoning a reader can read, or "" when the
/// provider kept it back.
@Suite("pi thinking blocks")
struct ThinkingBlockTests {
    /// Shapes built from pi-ai's providers (`dist/api/*.js`), not from any session.
    static let blocks: [(String, String, String)] = [
        // anthropic-messages: `redacted_thinking` becomes the placeholder, flagged, the payload in the signature.
        ("anthropic redacted",
         #"{"type":"thinking","thinking":"[Reasoning redacted]","thinkingSignature":"EmwKAhgBEgyQ3Zb0","redacted":true}"#, ""),
        // anthropic-messages with `display: "omitted"`: no thinking deltas, only a signature.
        ("anthropic omitted", #"{"type":"thinking","thinking":"","thinkingSignature":"ErUBCkYIBxgCKkDx"}"#, ""),
        ("anthropic readable",
         #"{"type":"thinking","thinking":"Check the tests first.","thinkingSignature":"ErUBCkYIBxgCKkDx"}"#, "Check the tests first."),
        // openai-responses: the reasoning item (with `encrypted_content`) is the signature; its summary is the text.
        ("openai responses encrypted",
         #"{"type":"thinking","thinking":"","thinkingSignature":"{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[],\"encrypted_content\":\"gAAAAB\"}"}"#, ""),
        ("openai responses summary",
         #"{"type":"thinking","thinking":"Plan the fix.","thinkingSignature":"{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Plan the fix.\"}],\"encrypted_content\":\"gAAAAB\"}"}"#,
         "Plan the fix."),
        ("openai responses summary only in the item",
         #"{"type":"thinking","thinking":"","thinkingSignature":"{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"One.\"},{\"type\":\"summary_text\",\"text\":\"Two.\"}]}"}"#,
         "One.\n\nTwo."),
        // openai-completions: a proxy that streams no reasoning text leaves an empty block.
        ("chat completions without reasoning", #"{"type":"thinking","thinking":"","thinkingSignature":""}"#, ""),
        ("chat completions encrypted details",
         #"{"type":"thinking","thinking":"","thinkingSignature":"[{\"type\":\"reasoning.encrypted\",\"id\":\"r1\",\"data\":\"gAAAAB\",\"format\":\"openai-responses-v1\",\"index\":0}]"}"#, ""),
        ("chat completions summary details",
         #"{"type":"thinking","thinking":"","thinkingSignature":"[{\"type\":\"reasoning.summary\",\"summary\":\"Read the config.\",\"index\":0},{\"type\":\"reasoning.encrypted\",\"id\":\"r1\",\"data\":\"gAAAAB\",\"index\":1}]"}"#,
         "Read the config."),
        ("chat completions text beside its field name",
         #"{"type":"thinking","thinking":"Looking at main.","thinkingSignature":"reasoning_content"}"#, "Looking at main."),
        ("whitespace", #"{"type":"thinking","thinking":"\n  \n"}"#, ""),
        ("no thinking key", #"{"type":"thinking"}"#, ""),
    ]

    @Test(arguments: blocks)
    func aThinkingBlockDecodesToWhatAReaderCanRead(name: String, json: String, readable: String) throws {
        let block = try JSONDecoder().decode(RPCContentBlock.self, from: Data(json.utf8))
        #expect(block == .thinking(readable), "\(name)")
    }

    /// A redacted block in a whole message, as get_messages and message_end carry it.
    @Test func aRedactedBlockInAMessageReadsAsNothing() throws {
        let json = #"{"role":"assistant","content":[{"type":"thinking","thinking":"[Reasoning redacted]","thinkingSignature":"EmwK","redacted":true},{"type":"text","text":"Done."}],"stopReason":"stop"}"#
        let message = try JSONDecoder().decode(RPCMessage.self, from: Data(json.utf8))
        #expect(message.content == [.thinking(""), .text("Done.")])
    }
}

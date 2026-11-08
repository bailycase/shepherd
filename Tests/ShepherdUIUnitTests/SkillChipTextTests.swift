import AppKit
import Testing
@testable import ShepherdUI

/// The draft a composer field publishes (`SHSkillChips.text(of:)`) is a native string: Swift walks
/// and compares it on the fast UTF-8 path, not on the slow path of the text storage's bridged
/// UTF-16 copy that an appended-to-empty String would adopt.
@Suite("Skill chip text")
struct SkillChipTextTests {
    @Test func aFieldsWordsComeOutAsANativeString() {
        let storage = NSTextStorage(string: "naïve 日本語 draft 🚀 " + String(repeating: "x", count: 200))
        let text = SHSkillChips.text(of: storage)
        #expect(text == storage.string)
        #expect(text.isContiguousUTF8)
    }

    @Test func anAsciiFieldsWordsComeOutAsANativeString() {
        let storage = NSTextStorage(string: String(repeating: "plain words ", count: 40))
        let text = SHSkillChips.text(of: storage)
        #expect(text == storage.string)
        #expect(text.isContiguousUTF8)
    }

    @MainActor @Test func aChipDraftComesOutWhole() throws {
        let draft = "a /skill:debug b"
        let token = try #require(draft.range(of: "/skill:debug"))
        let shown = try #require(SHSkillChips.attributed(draft, tokens: [token], name: { _ in "debug" },
                                                         attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        let text = SHSkillChips.text(of: shown)
        #expect(text == draft)
        #expect(text.isContiguousUTF8)
    }

    @MainActor @Test func aNonAsciiChipDraftComesOutWhole() throws {
        let draft = "naïve 日本語 /skill:debug 🚀 " + String(repeating: "x", count: 200)
        let token = try #require(draft.range(of: "/skill:debug"))
        let shown = try #require(SHSkillChips.attributed(draft, tokens: [token], name: { _ in "debug" },
                                                         attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        let text = SHSkillChips.text(of: shown)
        #expect(text == draft)
        #expect(text.isContiguousUTF8)
    }
}

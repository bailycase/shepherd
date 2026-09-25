import Testing
@testable import ShepherdSessions

/// The remote listener's hello token check compares every byte, so its answer is the same as
/// `==`'s without leaking where two tokens first differ.
@Suite("Remote token")
struct RemoteTokenTests {
    private static let token = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

    @Test(arguments: [
        (token, true),
        ("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a09", false),
        ("0f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", false),
        (String(token.dropLast()), false),
        (token + "0", false),
        ("", false),
        (token.uppercased(), false),
    ])
    func aTokenMatchesOnlyTheSameBytes(presented: String, matches: Bool) {
        #expect(RemoteToken.matches(presented, expected: Self.token) == matches)
    }

    /// A presented token that starts with the expected one but is a byte longer or shorter
    /// still fails: the length is part of the comparison.
    @Test func aPrefixOfTheTokenDoesNotMatch() {
        #expect(!RemoteToken.matches("9f86", expected: "9f86d0"))
        #expect(!RemoteToken.matches("9f86d0", expected: "9f86"))
    }

    @Test func emptyTokensMatchOnlyEachOther() {
        #expect(RemoteToken.matches("", expected: ""))
        #expect(!RemoteToken.matches("a", expected: ""))
    }
}

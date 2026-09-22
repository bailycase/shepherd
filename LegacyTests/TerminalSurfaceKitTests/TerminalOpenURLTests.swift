import Testing
@testable import TerminalSurfaceKit

@Suite("Terminal links")
struct TerminalOpenURLTests {
    @Test func acceptsBrowserAndMailLinks() {
        #expect(terminalOpenURL("https://example.com/path")?.absoluteString == "https://example.com/path")
        #expect(terminalOpenURL("http://example.com") != nil)
        #expect(terminalOpenURL("mailto:test@example.com") != nil)
    }

    @Test func rejectsUnsafeAndInvalidLinks() {
        #expect(terminalOpenURL("file:///etc/passwd") == nil)
        #expect(terminalOpenURL("javascript:alert(1)") == nil)
        #expect(terminalOpenURL("not a link") == nil)
    }

    @Test func commandClickBypassesFullscreenMouseCapture() {
        #expect(terminalLinkModifiers([.command]) == [.command, .shift])
        #expect(terminalLinkModifiers([.command, .option]) == [.command, .option, .shift])
        #expect(terminalLinkModifiers([.control]) == [.control])
    }
}

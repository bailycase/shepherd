import Foundation
import Testing
@testable import TerminalSurfaceKit

@Suite("Terminal file drops")
struct TerminalFileDropTests {
    @Test(arguments: [
        ("/tmp/plain.txt", "/tmp/plain.txt"),
        ("/tmp/my file (1).txt", #"/tmp/my\ file\ \(1\).txt"#),
        ("/tmp/$draft?.md", #"/tmp/\$draft\?.md"#),
        ("/tmp/a'b.txt", #"/tmp/a\'b.txt"#),
    ])
    func shellEscapesPaths(path: String, expected: String) {
        #expect(TerminalFileDrop.shellEscape(path) == expected)
    }

    /// Paths end with a space so the prompt the user types next does not run
    /// into the filename.
    @Test func joinsMultipleFileURLsInDropOrder() {
        let urls = [
            URL(fileURLWithPath: "/tmp/first file.txt"),
            URL(fileURLWithPath: "/tmp/second.txt"),
        ]
        #expect(TerminalFileDrop.text(for: urls) == #"/tmp/first\ file.txt /tmp/second.txt "#)
    }

    @Test func ignoresNonFileURLs() {
        let urls = [
            URL(string: "https://example.com/file.txt")!,
            URL(fileURLWithPath: "/tmp/local.txt"),
        ]
        #expect(TerminalFileDrop.text(for: urls) == "/tmp/local.txt ")
        #expect(TerminalFileDrop.text(for: [urls[0]]) == nil)
    }
}

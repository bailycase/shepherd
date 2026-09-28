import Foundation
import ShepherdTestSupport
import Testing
@testable import TerminalSurfaceKit

@Suite("Terminal drop arguments", .integrationTimeLimit)
struct TerminalDropArgumentTests {
    @Test func controlCharactersRemainOneLiteralShellArgument() throws {
        let path = "/tmp/report\npwd\nquote'\rfile"
        let escaped = TerminalFileDrop.shellEscape(path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\0' " + escaped]
        process.currentDirectoryURL = try makeScratchDirectory("drop-argument")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(bytes == Data((path + "\0").utf8))
    }
}

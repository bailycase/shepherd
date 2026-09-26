import Darwin
import Foundation
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Shell panes", .integrationTimeLimit)
struct ShellIntegrationTests {
    /// Real login shells read scratch startup files and call a fake pi, never the user's pi, and
    /// hand it none of the pi variables an agent's environment carries.
    @Test(arguments: ["/bin/zsh", "/bin/bash"])
    func piKeepsItsOwnArgumentsAndShellStartupWithoutThemeInjection(shell: String) async throws {
        let home = try makeScratchDirectory("shell")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let pi = bin.appendingPathComponent("pi")
        try """
        #!/bin/sh
        printf '<%s>\\n' "$@" > "$CAPTURE"
        printf 'identity=%s socket=%s startup=%s\\n' "$SHEPHERD_AGENT_ID" "$SHEPHERD_SOCKET" "$STARTUP" >> "$CAPTURE"
        printf 'home=%s sessions=%s package=%s offline=%s subagents=%s engine=%s\\n' "$PI_CODING_AGENT_DIR" \\
          "$PI_CODING_AGENT_SESSION_DIR" "$PI_PACKAGE_DIR" "$PI_OFFLINE" "$PI_SUBAGENTS_TEMP_ROOT" "$SHEPHERD_PI_EXECUTABLE" >> "$CAPTURE"
        exit 17
        """.write(to: pi, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        let startup = "export PATH=\(shellQuoted(bin.path)):/usr/bin:/bin\nexport STARTUP=ready\n"
        for name in [".zlogin", ".bash_profile"] {
            try startup.write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let command = ShellIntegration.command(shell: [shell, "-l"])
        #expect(command.argv == [shell, "-l"])
        #expect(command.env["ZDOTDIR"] == nil)
        let capture = home.appendingPathComponent("capture")
        var env = ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin", "TERM": "dumb",
                   "CAPTURE": capture.path, "SHEPHERD_AGENT_ID": "parent", "SHEPHERD_SOCKET": "parent",
                   // What a Shepherd started from an agent's shell would hand its panes.
                   "PI_CODING_AGENT_DIR": "/parent/pi", "PI_CODING_AGENT_SESSION_DIR": "/parent/pi/sessions",
                   "PI_PACKAGE_DIR": "/parent/engine", "PI_OFFLINE": "1", "PI_SUBAGENTS_TEMP_ROOT": "/parent/tmp",
                   "SHEPHERD_PI_EXECUTABLE": "/parent/pi-engine"]
        env.merge(command.env) { _, new in new }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = Array(command.argv.dropFirst()) + ["-i"] + (shell.hasSuffix("zsh") ? ["+o", "zle", "+o", "monitor"] : [])
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        input.fileHandleForWriting.write(Data("pi --model 'provider/model' -e 'user ext.ts' -- 'two words' ''; exit $?\n".utf8))
        try input.fileHandleForWriting.close()
        try await eventually("the login shell to exit") { !process.isRunning }
        #expect(process.terminationStatus == 17)
        #expect(try String(contentsOf: capture, encoding: .utf8) == "<--model>\n<provider/model>\n<-e>\n<user ext.ts>\n<-->\n<two words>\n<>\nidentity= socket= startup=ready\n"
                + "home= sessions= package= offline= subagents= engine=\n")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".pi").path))
    }
}

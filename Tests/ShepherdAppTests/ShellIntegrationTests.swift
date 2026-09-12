import Darwin
import Foundation
import Testing
@testable import ShepherdApp

@Suite("Shell pi integration")
struct ShellIntegrationTests {
    @Test(arguments: ["/bin/zsh", "/bin/bash"])
    func shellPiPreservesStartupArgumentsAndIdentity(shell: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-shell-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("user bin's")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fakePi = bin.appendingPathComponent("pi")
        try """
        #!/bin/sh
        printf '<%s>\\n' "$@" > "$CAPTURE"
        printf 'identity=%s socket=%s theme=%s startup=%s zdotdir=%s\\n' "$SHEPHERD_AGENT_ID" "$SHEPHERD_SOCKET" "$SHEPHERD_PI_THEME_PATH" "$STARTUP" "${ZDOTDIR-unset}" >> "$CAPTURE"
        exit 17
        """.write(to: fakePi, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePi.path)

        let userZdotdir = root.appendingPathComponent("user zsh")
        try FileManager.default.createDirectory(at: userZdotdir, withIntermediateDirectories: true)
        try "export STARTUP=env\n".write(to: userZdotdir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try "export STARTUP=$STARTUP,profile\n".write(to: userZdotdir.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try "export STARTUP=$STARTUP,rc\n".write(to: userZdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let startup = "export PATH=\(shellQuoted(bin.path)):/usr/bin:/bin\nexport STARTUP=$STARTUP,login\n"
        try startup.write(to: userZdotdir.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)
        try startup.write(to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)

        let themePath = root.appendingPathComponent("theme's palette.json").path
        let extensionPath = root.appendingPathComponent("theme's extension.ts").path
        var environment = [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "dumb",
            "ZDOTDIR": userZdotdir.path, "SHEPHERD_AGENT_ID": "parent-agent",
            "SHEPHERD_SOCKET": "parent-socket", "SHEPHERD_PI_THEME_PATH": "parent-theme",
        ]
        let command = try ShellIntegration.command(
            shell: [shell, "-l"], themeExtensionPath: extensionPath, themePath: themePath,
            directory: root.appendingPathComponent("integration's files"), environment: environment
        )
        environment.merge(command.env) { _, new in new }
        let capture = root.appendingPathComponent("captured")
        environment["CAPTURE"] = capture.path
        let script = "pi --model 'provider/model' -e 'user ext.ts' -- 'quote '\\'' and $dollar' ''; result=$?; exit $result\n"
        // Process pipes are not a PTY, so request the interactive mode that
        // the real pane's terminal supplies automatically.
        let interactiveArgv = command.argv + ["-i"]
        let status = try await run(interactiveArgv, environment: environment, input: script)
        #expect(status == 17)
        let output = try String(contentsOf: capture, encoding: .utf8)
        let expectedArgs = ["--theme", themePath, "--use-theme", ShepherdPiTheme.name, "-e", extensionPath,
                            "--model", "provider/model", "-e", "user ext.ts", "--", "quote ' and $dollar", ""]
        #expect(output.hasPrefix(expectedArgs.map { "<\($0)>\n" }.joined()))
        #expect(output.contains("identity= socket= theme=\(themePath)"))
        #expect(output.contains("startup=\(shell.hasSuffix("zsh") ? "env,profile,rc,login" : ",login")"))
        #expect(output.contains("zdotdir=\(userZdotdir.path)"))

        let packageStatus = try await run(interactiveArgv, environment: environment, input: "pi update --all; exit $?\n")
        #expect(packageStatus == 17)
        let packageOutput = try String(contentsOf: capture, encoding: .utf8)
        #expect(packageOutput.hasPrefix("<update>\n<--all>\nidentity= socket= theme= startup="))

        let userFunction = "function pi { return 23; }\n"
        try userFunction.write(to: userZdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try (startup + userFunction).write(to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        #expect(try await run(interactiveArgv, environment: environment, input: "pi; exit $?\n") == 23)
        let userAlias = "alias pi=\"/bin/sh -c 'exit 29'\"\n"
        try userAlias.write(to: userZdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try (startup + userAlias).write(to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        #expect(try await run(interactiveArgv, environment: environment, input: "pi; exit $?\n") == 29)

        let config = home.appendingPathComponent(".pi")
        #expect(!FileManager.default.fileExists(atPath: config.path))
        #expect(try String(contentsOf: home.appendingPathComponent(".bash_profile"), encoding: .utf8) == startup + userAlias)
        #expect(try String(contentsOf: userZdotdir.appendingPathComponent(".zlogin"), encoding: .utf8) == startup)
    }

    @Test(arguments: [".zshenv", ".zprofile", ".zshrc"], [false, true])
    func zshFinalizesWhenUserDisablesRCS(stage: String, unsetZdotdir: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-no-rcs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let userDirectory = root.appendingPathComponent("user")
        let finalDirectory = root.appendingPathComponent("final")
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        let fakePi = root.appendingPathComponent("pi")
        try "#!/bin/sh\nprintf '<%s>\\n' \"$@\" >> \"$CAPTURE\"\nexit 17\n"
            .write(to: fakePi, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePi.path)
        let startup = """
        export PATH=\(shellQuoted(root.path)):/usr/bin:/bin
        \(unsetZdotdir ? "unset ZDOTDIR" : "export ZDOTDIR=\(shellQuoted(finalDirectory.path))")
        unsetopt RCS
        """
        try startup.write(to: userDirectory.appendingPathComponent(stage), atomically: true, encoding: .utf8)
        // If later startup files run despite NO_RCS, fail before the prompt.
        for directory in [root, finalDirectory] {
            for laterStage in [".zprofile", ".zshrc", ".zlogin"] {
                try "exit 99\n".write(to: directory.appendingPathComponent(laterStage), atomically: true, encoding: .utf8)
            }
        }
        let capture = root.appendingPathComponent("capture")
        var env = ["HOME": root.path, "ZDOTDIR": userDirectory.path, "PATH": "/usr/bin:/bin",
                   "TERM": "dumb", "CAPTURE": capture.path]
        let command = try ShellIntegration.command(
            shell: ["/bin/zsh", "-l"], themeExtensionPath: "/theme.ts", themePath: "/theme.json",
            directory: root.appendingPathComponent("integration"), environment: env
        )
        env.merge(command.env) { _, new in new }
        let input = "printf '%s:%s\\n' \"${ZDOTDIR-unset}\" \"$options[rcs]\" > \"$CAPTURE\"; pi 'two words'; exit $?\n"
        #expect(try await run(command.argv + ["-i"], environment: env, input: input) == 17)
        let expectedDirectory = unsetZdotdir ? "unset" : finalDirectory.path
        let args = ["--theme", "/theme.json", "--use-theme", ShepherdPiTheme.name, "-e", "/theme.ts", "two words"]
        #expect(try String(contentsOf: capture, encoding: .utf8) == expectedDirectory + ":off\n" + args.map { "<\($0)>\n" }.joined())
    }

    private static let fishPath = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(.enabled(if: fishPath != nil, "fish is not installed"))
    func fishLoadsThemeAfterUserConfig() async throws {
        let fish = try #require(Self.fishPath)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-fish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config/fish")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fakePi = bin.appendingPathComponent("pi")
        try "#!/bin/sh\nprintf '<%s>\\n' \"$@\" > \"$CAPTURE\"\nprintf '%s:%s:%s' \"$SHEPHERD_AGENT_ID\" \"$SHEPHERD_SOCKET\" \"$STARTUP\" >> \"$CAPTURE\"\nexit 17\n"
            .write(to: fakePi, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePi.path)
        try "set -gx PATH '\(bin.path)' /usr/bin /bin\nset -gx STARTUP ready\n"
            .write(to: config.appendingPathComponent("config.fish"), atomically: true, encoding: .utf8)
        let theme = root.appendingPathComponent("theme's \\ palette.json").path
        let ext = root.appendingPathComponent("theme's extension.ts").path
        let command = try ShellIntegration.command(shell: [fish, "-l"], themeExtensionPath: ext, themePath: theme)
        let capture = root.appendingPathComponent("capture")
        var env = ["HOME": root.path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                   "PATH": "/usr/bin:/bin", "TERM": "dumb", "CAPTURE": capture.path]
        env.merge(command.env) { _, new in new }
        #expect(try await run(command.argv + ["-i"], environment: env, input: "pi --model 'a/b' -- 'two words' ''; exit $status\n") == 17)
        let output = try String(contentsOf: capture, encoding: .utf8)
        let args = ["--theme", theme, "--use-theme", ShepherdPiTheme.name, "-e", ext, "--model", "a/b", "--", "two words", ""]
        #expect(output == args.map { "<\($0)>\n" }.joined() + "::ready")
        #expect(try await run(command.argv + ["-i"], environment: env, input: "pi; exit $status\n") == 17)
        #expect(try String(contentsOf: capture, encoding: .utf8) == Array(args.prefix(6)).map { "<\($0)>\n" }.joined() + "::ready")
    }

    @Test func disabledThemeAndUnknownShellStayPlainWithoutAgentIdentity() throws {
        for shell in ["/bin/zsh", "/bin/bash", "/bin/fish", "/custom/shell"] {
            let command = try ShellIntegration.command(
                shell: [shell, "-l"], themeExtensionPath: nil, themePath: nil
            )
            #expect(command.argv == [shell, "-l"])
            #expect(command.env["SHEPHERD_AGENT_ID"] == "")
            #expect(command.env["SHEPHERD_SOCKET"] == "")
            #expect(command.env["SHEPHERD_PI_THEME_PATH"] == "")
        }
        let command = try ShellIntegration.command(
            shell: ["/custom/shell", "-l"], themeExtensionPath: "/theme.ts", themePath: "/theme.json"
        )
        #expect(command.argv == ["/custom/shell", "-l"])
    }

    private func run(_ argv: [String], environment: [String: String], input: String) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        // Pipe-driven zsh must not claim the runner's terminal for ZLE or job control.
        process.arguments = Array(argv.dropFirst()) + (argv[0].hasSuffix("zsh") ? ["+o", "zle", "+o", "monitor"] : [])
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        defer {
            // Interactive shells can ignore SIGTERM. Never leave a timed-out child running.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + .seconds(10)
        while process.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!process.isRunning, "Shell did not exit within 10 seconds")
        // waitUntilExit pumps a thread-local run loop and can hang after an async hop,
        // even when isRunning is false. Polling above already observed termination.
        return process.terminationStatus
    }
}

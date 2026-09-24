import Darwin
import Foundation
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Shell panes wrap `pi` so a pi run by hand picks up Shepherd's theme. These start real
/// zsh/bash/fish processes with scratch HOME/ZDOTDIR (never the user's dotfiles) and a fake
/// `pi` that records how it was called.
@Suite("Shell pi integration", .integrationTimeLimit)
struct ShellIntegrationTests {
    /// A scratch home with a fake `pi` on PATH that records its argv and environment into
    /// `$CAPTURE` and exits `status`.
    private struct Home {
        let root: URL
        let bin: URL
        var capture: URL { root.appendingPathComponent("captured") }

        init(piStatus: Int32 = 17) throws {
            root = try makeScratchDirectory("shell")
            bin = root.appendingPathComponent("user bin's")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let pi = bin.appendingPathComponent("pi")
            try """
            #!/bin/sh
            printf '<%s>\\n' "$@" > "$CAPTURE"
            printf 'identity=%s socket=%s theme=%s startup=%s zdotdir=%s\\n' "$SHEPHERD_AGENT_ID" "$SHEPHERD_SOCKET" "$SHEPHERD_PI_THEME_PATH" "$STARTUP" "${ZDOTDIR-unset}" >> "$CAPTURE"
            exit \(piStatus)
            """.write(to: pi, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static func themeArgs(_ theme: String, _ ext: String) -> [String] {
        ["--theme", theme, "--use-theme", ShepherdPiTheme.name, "-e", ext]
    }

    /// Runs `argv` interactively (pipes are not a PTY, so `-i`), feeding `input`, and returns
    /// its exit status. Never leaves the shell running.
    private func run(_ argv: [String], environment: [String: String], input: String) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        // Pipe-driven zsh must not claim the runner's terminal for ZLE or job control.
        process.arguments = Array(argv.dropFirst()) + ["-i"] + (argv[0].hasSuffix("zsh") ? ["+o", "zle", "+o", "monitor"] : [])
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        try await eventually("the shell to exit", timeout: .seconds(20)) { !process.isRunning }
        return process.terminationStatus
    }

    /// The wrapper prepends the theme flags, keeps the user's own arguments exactly (quotes,
    /// dollars, empty strings), strips agent identity inherited from the app, runs after the
    /// user's startup files, and leaves package commands (`pi update`) untouched.
    @Test(arguments: ["/bin/zsh", "/bin/bash"])
    func piInAShellPaneGetsTheThemeAndKeepsTheUsersArguments(shell: String) async throws {
        let home = try Home()
        defer { home.remove() }
        let userHome = home.root.appendingPathComponent("home")
        let zdotdir = home.root.appendingPathComponent("user zsh")
        for dir in [userHome, zdotdir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try "export STARTUP=env\n".write(to: zdotdir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try "export STARTUP=$STARTUP,profile\n".write(to: zdotdir.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try "export STARTUP=$STARTUP,rc\n".write(to: zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let login = "export PATH=\(shellQuoted(home.bin.path)):/usr/bin:/bin\nexport STARTUP=$STARTUP,login\n"
        try login.write(to: zdotdir.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)
        try login.write(to: userHome.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        let theme = home.root.appendingPathComponent("theme's palette.json").path
        let ext = home.root.appendingPathComponent("theme's extension.ts").path
        var env = ["HOME": userHome.path, "PATH": "/usr/bin:/bin", "TERM": "dumb", "ZDOTDIR": zdotdir.path,
                   "SHEPHERD_AGENT_ID": "parent-agent", "SHEPHERD_SOCKET": "parent-socket", "SHEPHERD_PI_THEME_PATH": "parent-theme"]
        let command = try ShellIntegration.command(shell: [shell, "-l"], themeExtensionPath: ext, themePath: theme,
                                                   directory: home.root.appendingPathComponent("integration's files"), environment: env)
        env.merge(command.env) { _, new in new }
        env["CAPTURE"] = home.capture.path

        let status = try await run(command.argv, environment: env,
                                   input: "pi --model 'provider/model' -e 'user ext.ts' -- 'quote '\\'' and $dollar' ''; exit $?\n")

        #expect(status == 17)
        let output = try String(contentsOf: home.capture, encoding: .utf8)
        let args = Self.themeArgs(theme, ext) + ["--model", "provider/model", "-e", "user ext.ts", "--", "quote ' and $dollar", ""]
        #expect(output.hasPrefix(args.map { "<\($0)>\n" }.joined()))
        #expect(output.contains("identity= socket= theme=\(theme)"))
        #expect(output.contains("startup=\(shell.hasSuffix("zsh") ? "env,profile,rc,login" : ",login")"))
        #expect(output.contains("zdotdir=\(zdotdir.path)"))
        #expect(!FileManager.default.fileExists(atPath: userHome.appendingPathComponent(".pi").path))

        #expect(try await run(command.argv, environment: env, input: "pi update --all; exit $?\n") == 17)
        #expect(try String(contentsOf: home.capture, encoding: .utf8).hasPrefix("<update>\n<--all>\nidentity= socket= theme= startup="))
    }

    /// A user's own `pi` function or alias wins over the wrapper.
    @Test(arguments: ["/bin/zsh", "/bin/bash"], ["function pi { return 23; }", "alias pi=\"/bin/sh -c 'exit 23'\""])
    func aUsersOwnPiFunctionOrAliasWins(shell: String, definition: String) async throws {
        let home = try Home()
        defer { home.remove() }
        let zdotdir = home.root.appendingPathComponent("zsh")
        try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        let startup = "export PATH=\(shellQuoted(home.bin.path)):/usr/bin:/bin\n\(definition)\n"
        try startup.write(to: zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try startup.write(to: home.root.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        var env = ["HOME": home.root.path, "PATH": "/usr/bin:/bin", "TERM": "dumb", "ZDOTDIR": zdotdir.path, "CAPTURE": home.capture.path]
        let command = try ShellIntegration.command(shell: [shell, "-l"], themeExtensionPath: "/theme.ts", themePath: "/theme.json",
                                                   directory: home.root.appendingPathComponent("integration"), environment: env)
        env.merge(command.env) { _, new in new }

        #expect(try await run(command.argv, environment: env, input: "pi; exit $?\n") == 23)
        #expect(try String(contentsOf: zdotdir.appendingPathComponent(".zshrc"), encoding: .utf8) == startup, "the user's files are never edited")
    }

    /// A user who turns off RCS (or moves ZDOTDIR) mid-startup still gets the wrapper, and
    /// later startup files are not run behind their back.
    @Test(arguments: [".zshenv", ".zprofile", ".zshrc"], [false, true])
    func zshStillWrapsPiWhenTheUserDisablesStartupFiles(stage: String, unsetZdotdir: Bool) async throws {
        let home = try Home()
        defer { home.remove() }
        let user = home.root.appendingPathComponent("user"), final = home.root.appendingPathComponent("final")
        for dir in [user, final] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try """
        export PATH=\(shellQuoted(home.bin.path)):/usr/bin:/bin
        \(unsetZdotdir ? "unset ZDOTDIR" : "export ZDOTDIR=\(shellQuoted(final.path))")
        unsetopt RCS
        """.write(to: user.appendingPathComponent(stage), atomically: true, encoding: .utf8)
        for dir in [home.root, final] {
            for later in [".zprofile", ".zshrc", ".zlogin"] {
                try "exit 99\n".write(to: dir.appendingPathComponent(later), atomically: true, encoding: .utf8)
            }
        }
        let probe = home.root.appendingPathComponent("probe")
        var env = ["HOME": home.root.path, "ZDOTDIR": user.path, "PATH": "/usr/bin:/bin", "TERM": "dumb", "CAPTURE": home.capture.path]
        let command = try ShellIntegration.command(shell: ["/bin/zsh", "-l"], themeExtensionPath: "/theme.ts", themePath: "/theme.json",
                                                   directory: home.root.appendingPathComponent("integration"), environment: env)
        env.merge(command.env) { _, new in new }

        let status = try await run(command.argv, environment: env,
                                   input: "printf '%s:%s\\n' \"${ZDOTDIR-unset}\" \"$options[rcs]\" > \(shellQuoted(probe.path)); pi 'two words'; exit $?\n")

        #expect(status == 17)
        #expect(try String(contentsOf: probe, encoding: .utf8) == (unsetZdotdir ? "unset" : final.path) + ":off\n")
        let args = Self.themeArgs("/theme.json", "/theme.ts") + ["two words"]
        #expect(try String(contentsOf: home.capture, encoding: .utf8).hasPrefix(args.map { "<\($0)>\n" }.joined()))
    }

    private static let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(.enabled(if: fish != nil, "fish is not installed"))
    func fishLoadsTheThemeAfterTheUsersConfig() async throws {
        let fish = try #require(Self.fish)
        let home = try Home()
        defer { home.remove() }
        let config = home.root.appendingPathComponent("config/fish")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "set -gx PATH '\(home.bin.path)' /usr/bin /bin\nset -gx STARTUP ready\n"
            .write(to: config.appendingPathComponent("config.fish"), atomically: true, encoding: .utf8)
        let theme = home.root.appendingPathComponent("theme's \\ palette.json").path
        let ext = home.root.appendingPathComponent("theme's extension.ts").path
        let command = try ShellIntegration.command(shell: [fish, "-l"], themeExtensionPath: ext, themePath: theme,
                                                   directory: home.root.appendingPathComponent("integration"))
        var env = ["HOME": home.root.path, "XDG_CONFIG_HOME": home.root.appendingPathComponent("config").path,
                   "PATH": "/usr/bin:/bin", "TERM": "dumb", "CAPTURE": home.capture.path]
        env.merge(command.env) { _, new in new }

        #expect(try await run(command.argv, environment: env, input: "pi --model 'a/b' -- 'two words' ''; exit $status\n") == 17)

        let args = Self.themeArgs(theme, ext) + ["--model", "a/b", "--", "two words", ""]
        #expect(try String(contentsOf: home.capture, encoding: .utf8).hasPrefix(args.map { "<\($0)>\n" }.joined()))
    }
}

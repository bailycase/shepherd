import Foundation
import ShepherdProtocol

/// Per-pane startup files. User shell and pi configuration stay untouched.
enum ShellIntegration {
    static func command(
        shell: [String],
        themeExtensionPath: String?,
        themePath: String?,
        directory: URL = ShepherdPaths.supportDirectory().appendingPathComponent("shell-integration"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SessionCommand {
        // PTYSession merges with the app environment, which can itself have
        // been launched from an agent. Empty values disable agent-only hooks.
        var env = Dictionary(uniqueKeysWithValues: [
            "SHEPHERD_AGENT_ID", "SHEPHERD_SOCKET", "SHEPHERD_EXT_STATUS",
            "SHEPHERD_EXT_PANES", "SHEPHERD_NEEDS_NAME", "SHEPHERD_AUTOMATION",
            "SHEPHERD_MODEL", "SHEPHERD_EXT_THEME", "SHEPHERD_PI_THEME_PATH",
            "SHEPHERD_PI_THEME_NAME",
        ].map { ($0, "") })
        guard let themeExtensionPath, let themePath,
              let executable = shell.first else {
            return SessionCommand(argv: shell, env: env)
        }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard ["zsh", "bash", "fish"].contains(name) else {
            return SessionCommand(argv: shell, env: env)
        }

        let arguments = ["--theme", themePath, "--use-theme", ShepherdPiTheme.name, "-e", themeExtensionPath]
        // Package commands inspect argv[0] before parsing options. Do not turn
        // `pi update` into an agent prompt by prepending resource flags.
        let packageCommands = "install|remove|uninstall|update|list|config|auth"
        let invocation = "SHEPHERD_PI_THEME_PATH=\(shellQuoted(themePath)) command pi \(arguments.map(shellQuoted).joined(separator: " ")) \"$@\""
        let function = """
        function pi {
            case "${1-}" in
                \(packageCommands)) command pi "$@" ;;
                *) \(invocation) ;;
            esac
        }
        """
        var files: [String: String] = [:]
        let argv: [String]
        switch name {
        case "zsh":
            let zshDirectory = directory.appendingPathComponent("zsh").path
            env["SHEPHERD_USER_ZDOTDIR"] = environment["ZDOTDIR"] ?? ""
            env["SHEPHERD_USER_ZDOTDIR_SET"] = environment["ZDOTDIR"] == nil ? "" : "1"
            env["ZDOTDIR"] = zshDirectory
            // Restore the user's ZDOTDIR while each file runs, including any
            // changes it makes, then intercept the next native startup phase.
            for stage in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
                var source = """
                if [[ -n "$SHEPHERD_USER_ZDOTDIR_SET" ]]; then
                    export ZDOTDIR="$SHEPHERD_USER_ZDOTDIR"
                else
                    unset ZDOTDIR
                fi
                [[ ! -r "${ZDOTDIR-$HOME}/\(stage)" ]] || source "${ZDOTDIR-$HOME}/\(stage)"
                """
                // NO_RCS skips the remaining startup files, so finalize now
                // without redirecting or changing the user's final ZDOTDIR.
                source += """

                if [[ \(shellQuoted(stage)) == '.zlogin' || ! -o rcs ]]; then
                    unset SHEPHERD_USER_ZDOTDIR SHEPHERD_USER_ZDOTDIR_SET
                    if (( ! $+functions[pi] && ! $+aliases[pi] )); then
                        \(function)
                    fi
                else
                    export SHEPHERD_USER_ZDOTDIR="${ZDOTDIR-}"
                    export SHEPHERD_USER_ZDOTDIR_SET="${ZDOTDIR+x}"
                    export ZDOTDIR=\(shellQuoted(zshDirectory))
                fi
                """
                files["zsh/\(stage)"] = source + "\n"
            }
            argv = shell
        case "bash":
            // Bash ignores --rcfile in login mode. Replay login startup files
            // in an interactive shell; login_shell and .bash_logout differ.
            files["bashrc"] = """
            [[ ! -r /etc/profile ]] || source /etc/profile
            for profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
                if [[ -r "$profile" ]]; then
                    source "$profile"
                    break
                fi
            done
            unset profile
            if ! declare -F pi >/dev/null && ! alias pi >/dev/null 2>&1; then
                \(function)
            fi
            """ + "\n"
            argv = [executable, "--rcfile", directory.appendingPathComponent("bashrc").path, "-i"]
        default:
            // Fish's init command runs after its normal login/config files.
            let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
            let source = """
            if not functions --query pi
                function pi
                    switch "$argv[1]"
                        case install remove uninstall update list config auth
                            command pi $argv
                        case '*'
                            SHEPHERD_PI_THEME_PATH=\(quote(themePath)) command pi \(arguments.map(quote).joined(separator: " ")) $argv
                    end
                end
            end
            """
            argv = shell + ["--init-command", source]
        }
        for (path, source) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(source.utf8)
            if (try? Data(contentsOf: url)) != data {
                try data.write(to: url, options: .atomic)
            }
        }
        return SessionCommand(argv: argv, env: env)
    }
}

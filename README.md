# Shepherd

A native macOS app for running and supervising many [pi](https://github.com/earendil-works/pi-coding-agent) coding agents at once.

Shepherd organizes work around agents, not chat threads. Each agent is a real `pi` process in a real terminal (rendered by [libghostty](https://ghostty.org)), with a status, a name it gives itself, and a workspace it runs in. The sidebar is the supervision surface: status dots show who is working, who is blocked waiting on you, and who is done. Selecting an agent drops you into its live terminal.

> Screenshot coming soon.

## Philosophy
Shepherd is opinionated software. It's built around my workflow and preferences and it favors staying small and coherent over covering everyone's use case.

## What it does

- Spaces group agents by project checkout; agents, shells, and split panes live inside them.
- Agents run real `pi` TUIs in PTYs owned by the app. No daemon: quit Shepherd and every agent stops. Relaunch restores the workspace and respawns fresh processes.
- Agents name themselves from their opening prompt and report lifecycle status (`working`, `blocked`, `done`, `idle`) through bundled pi extensions.
- Agents can open, run, read, and close their own terminal panes; pi subagents surface as child rows with a read-only inspector.
- Automations: saved monitoring prompts that run as dedicated agents and notify you when a condition is met.
- Optional remote access: the app can serve its fleet over an authenticated TCP listener to another Mac. Off by default.
- Command palette with fleet-wide transcript search, rebindable keyboard chords, light/dark Basalt theme synced into pi's TUI.

## Requirements

- macOS 26 or later (Apple Silicon)
- Xcode with the macOS 26 SDK
- [pi](https://github.com/earendil-works/pi-coding-agent) installed and on your login-shell `PATH`:

  ```sh
  npm install -g --ignore-scripts @earendil-works/pi-coding-agent
  ```

## Install

Download `Shepherd.dmg` from the [latest release](../../releases/latest), open it, and drag
Shepherd to Applications. Builds are signed and notarized; updates arrive automatically
via Sparkle on the channel you choose in Settings ▸ Advanced: **Stable** (tagged releases),
**Release Candidate** and **Beta** (pre-releases — both also receive newer stable builds, so
you are never stranded behind a hotfix), or **Nightly** (every push, least tested).

## Build from source

Open `Shepherd.xcodeproj`, pick a scheme, destination My Mac, Run. Two Mac schemes keep a stable install and a development build from sharing state:

| Scheme | Config | State directory |
| --- | --- | --- |
| `Shepherd (Dev)` | Debug | `~/Library/Application Support/Shepherd-dev` |
| `Shepherd (Prod)` | Release | `~/Library/Application Support/Shepherd` |

Or from the command line:

```sh
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' build
```

Libraries and tests use plain SwiftPM:

```sh
swift build
swift test
```

The GUI only runs through the Xcode project; `ShepherdApp` is a library product.

## Pi in shell panes

With the theme extension enabled, typing `pi` in a new zsh, bash, or fish pane loads
Shepherd's theme for that run. Startup files live in Shepherd's support directory;
Shepherd does not edit your shell rc files or pi settings. Existing `pi` aliases and
functions take precedence. Absolute paths and `command pi` bypass the integration.
Reopen existing shell panes after upgrading or changing the theme-extension toggle.

Shell-launched pi has no Shepherd agent identity, so agent-only pane, review,
automation, and peer tools remain unavailable. Status, naming, and subagent reporting
also stay off. Use a Shepherd agent when you need those integrations.

Zsh and fish retain native login startup. Bash loads `/etc/profile` and the first
readable `.bash_profile`, `.bash_login`, or `.profile` through an interactive rc file;
its `login_shell` flag is off and `.bash_logout` does not run automatically. Other
configured shells keep their normal startup without automatic pi theming.

## Remote access

Settings ▸ Remote toggles a TCP listener (default port 7433) that serves the fleet to remote Shepherd clients. Auth is a shared bearer token generated in the support directory. **There is no TLS** — the listener binds on all interfaces and assumes a trusted network or VPN as the transport boundary. Do not expose it to the internet.

Connected Macs can create, rename, reorder, and delete host agents; inspect subagents; search transcripts; and review diffs or PR changes. Worktree creation, setup, finalization, and confirmed deletion run on the host. File and image drops upload to the host, with a 32 MiB per-file limit. New remote features require a compatible host; ordinary agent creation and terminal access remain available with older hosts.

## Scope

Shepherd supervises agents and provides explicit worktree creation, finalization, and confirmed deletion actions. Other agent work runs in the selected checkout. Quitting the host app terminates its agent processes; disconnecting a remote client does not.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — dependency direction, state ownership, PTY and protocol flow
- [DESIGN.md](DESIGN.md) — the UI and interaction specification
- [AGENTS.md](AGENTS.md) — contributor guide (build, test, invariants, gotchas)

## License

[MIT](LICENSE). The vendored terminal package under `Vendor/libghostty-spm` is MIT ([Lakr233/libghostty-spm](https://github.com/Lakr233/libghostty-spm)) and bundles a prebuilt libghostty from [Ghostty](https://ghostty.org), which carries its own license terms.

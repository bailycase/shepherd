# Shepherd

A native macOS app for running and supervising many
[pi](https://github.com/earendil-works/pi-coding-agent) coding agents at once.

Shepherd organizes work around agents, not chats. Each agent is a real `pi` process that the app
owns. It has a status, a name it gives itself, and a project it works in. Every agent renders as
a native thread: its transcript, tool calls, questions, and subagents, with a composer for
follow-ups. The sidebar is where you supervise. Its status dots show who is working, who needs
you, and who is done.

> Screenshot coming soon.

## Philosophy

Shepherd is opinionated software. It is built around one workflow and favors staying small and
coherent over covering every use case.

## What it does

- **Spaces and agents.** A space is a project folder; its agents nest beneath it in the sidebar.
  Start an agent with ⌘N and describe the task. It names itself from your prompt and reports
  whether it is working, blocked on you, or done.
- **Native threads.** Each agent is `pi --mode rpc` behind a SwiftUI thread:
  - activity lines: one quiet line per burst of tool work ("Explored 7 files", "Ran tests · 17
    passed") that expands to its calls and their output
  - a changes card at the end of every turn that edited files, one click from the review pane
  - timed thinking
  - questions answered in place
  - pi's slash commands
  - model and thinking pickers
  - image attachments
  - messages sent while a turn runs wait in a queue above the composer, where each can be steered
    in, edited, reordered, or deleted
- **Terminal panes beside a thread.** Split a real terminal next to an agent with ⌘D, or let the
  agent open, run, read, and close its own panes. Terminals render with
  [libghostty](https://ghostty.org).
- **Subagents.** The bundled native subagent runtime lets an agent start child agents and script
  workflows. Runs appear as live cards in the thread and open in an inspector docked beside it;
  one waiting on your answer marks its agent in the sidebar.
- **Review.** A review pane docks beside the thread with the working-tree or PR diff and inline
  comments. It sends "request changes" (or "commit") back to the agent as its next turn. An
  agent can open it for you, on its own checkout or on another repository or worktree.
- **Agents working together.** An agent can list, message, and start other agents, read another
  agent's thread, steer or interrupt it, and wait for it to settle. Deleting another agent always
  asks you first. See [docs/agent-coordination.md](docs/agent-coordination.md).
- **Worktrees.** Give an agent its own git worktree, branched from a fresh `origin/<default>`.
  When the work is done, finalize it: commit, push, open a PR, and clean up. See
  [docs/worktrees.md](docs/worktrees.md).
- **Automations.** Saved monitoring prompts run as dedicated agents and notify you when
  something happens.
- **Remote.** Run your projects on one Mac and drive them from another. The host serves its
  agents over an authenticated TCP listener, off by default, meant for a VPN or trusted network.
- **Keyboard-first.** A command palette (⌘K) with transcript search across all your agents,
  plus rebindable shortcuts.
- **Night Watch.** Shepherd's design system, in light and dark, set in Geist and Geist Mono, and
  also applied to terminal panes and to pi run by hand in one.

Nothing runs in the background without the app. Quit Shepherd and every agent stops. Relaunch it
and the workspace comes back, with each agent resumed in its pi session.

## Requirements

- macOS 26 or later on Apple Silicon.
- [pi](https://github.com/earendil-works/pi-coding-agent), on your login shell's `PATH`:

  ```sh
  npm install -g --ignore-scripts @earendil-works/pi-coding-agent
  ```

- To build from source: Xcode with the macOS 26 SDK.

## Install

Download `Shepherd.dmg` from the [latest release](../../releases/latest), open it, and drag
Shepherd to Applications. Updates arrive through Sparkle on the channel you choose in
Settings ▸ Advanced:

- **Stable:** tagged releases.
- **Beta:** pre-releases. Beta also receives newer stable builds, so you are never stranded
  behind a hotfix.

**Shepherd Nightly** is a separate app built from every push to the integration branch, and the
least tested. Download `Shepherd-Nightly.dmg` from the newest
[nightly release](../../releases?q=nightly&expanded=true). It installs beside Shepherd and keeps
its own agents, settings and support folder (`~/Library/Application Support/Shepherd Nightly`),
so the two run at once. It updates only to newer Shepherd Nightly builds.

A copy of Shepherd that rode the old Nightly or Release Candidate channels moves to Beta on its
next update, and a former nightly rider is told once where nightly builds went.

## Build from source

Open `Shepherd.xcodeproj`, pick a scheme, choose My Mac, and Run. There are three Mac schemes,
so that a development build never shares state with your everyday copy. The Dev build also has
its own bundle id (`com.bailycase.shepherd.dev`), so its preferences and notifications stay
apart from an installed Shepherd's, and it never updates itself:

| Scheme | Config | Builds | State directory |
| --- | --- | --- | --- |
| `Shepherd (Dev)` | Debug | Shepherd | `~/Library/Application Support/Shepherd-dev` |
| `Shepherd (Prod)` | Release | Shepherd | `~/Library/Application Support/Shepherd` |
| `Shepherd (Nightly)` | Nightly | Shepherd Nightly | `~/Library/Application Support/Shepherd Nightly` |

To build from the command line, and to build and test the libraries with SwiftPM:

```sh
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile build
swift build
swift test --filter UnitTests          # fast
swift test                             # everything
```

The GUI runs only through the Xcode project; `ShepherdApp` is a library product.
[CONTRIBUTING.md](CONTRIBUTING.md) explains the test tiers.

Coming from herdr? With Shepherd quit, run `swift run shepherd-cli --import herdr` to import your
herdr workspaces and pi sessions.

## Remote access

1. **On the Mac that runs the agents (the host):** turn on Settings ▸ Remote ▸ Serve this Mac.
   It listens on TCP port 7433 on all interfaces (Shepherd Nightly: 7434). The Token row reveals
   the `remote-token` file; copy its contents.
2. **On the other Mac:** in Settings ▸ Remote ▸ Add host, enter a name, the host's VPN-reachable
   address, the port, and the token. The host's agents appear as their own section in the
   sidebar, with the same rows and threads.

A connected Mac can:

- create, rename, reorder, and delete agents on the host
- open terminal panes
- inspect subagents
- search transcripts
- review diffs
- create, finalize, and delete worktrees on the host

Dropped files upload to the host, up to 32 MiB each. Quitting the host stops its agents;
disconnecting a client does not.

**There is no TLS.** The token keeps other devices on a trusted network out, but the traffic
itself is unencrypted. Use a VPN or trusted network, and never expose the listener to the
internet. See [SECURITY.md](SECURITY.md).

An iOS client exists in `App/iOS` but is deferred until after the macOS redesign; see
[docs/ios](docs/ios/README.md).

## pi in terminal panes

With Settings ▸ Pi ▸ Sync pi theme on, typing `pi` in a zsh, bash, or fish terminal pane loads
Shepherd's theme for that run. The startup files live in Shepherd's support directory, and
Shepherd never edits your shell rc files or pi settings. Your own `pi` aliases and functions take
precedence, and `command pi` or an absolute path bypasses the integration. Reopen existing panes
after changing the setting.

pi started by hand in a pane has no Shepherd agent identity, so the agent tools (panes, review,
automations, peers) and status, naming, and subagent reporting are unavailable there. Use a
Shepherd agent when you want those.

## Documentation

- [AGENTS.md](AGENTS.md): the working guide for coding agents and contributors. It covers build
  and test, the source map, and the rules that are easy to break.
- [ARCHITECTURE.md](ARCHITECTURE.md): modules, runtime ownership, data flow, remote, and
  persistence.
- [DESIGN.md](DESIGN.md): the UI and interaction specification: Night Watch, Shepherd's design
  system, and every surface built on it.
- [docs/native-thread.md](docs/native-thread.md): how an agent's `pi --mode rpc` process
  becomes its thread.
- [docs/native-subagents.md](docs/native-subagents.md): the bundled subagent runtime.
- [docs/worktrees.md](docs/worktrees.md): worktree creation, finalize, and delete.
- [docs/agent-coordination.md](docs/agent-coordination.md): the tools agents use on each other
  and on the review pane.
- [docs/clean-mac-simulation.md](docs/clean-mac-simulation.md): testing the finalize setup
  checks.
- [docs/ios](docs/ios/README.md): the deferred iOS client.
- [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). The vendored terminal package in `Vendor/libghostty-spm` is MIT
([Lakr233/libghostty-spm](https://github.com/Lakr233/libghostty-spm)). It bundles a prebuilt
libghostty from [Ghostty](https://ghostty.org), which carries its own license terms.

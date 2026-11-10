# AGENTS.md

Shepherd is a native macOS app (SwiftUI, macOS 26+) for running and supervising many `pi` coding
agents, with an iPhone and iPad client (`App/iOS`). Every agent is `pi --mode rpc` on pipes, owned
by `SessionServer` and drawn as a native thread. `SessionServer` runs in a separate host process (the
app's own executable as `Shepherd --host`) and the app is always its client over `host.sock`. In
Shepherd Nightly with the background service on, launchd runs the host and agents outlive Quit;
otherwise the app starts the host as a supervised child and stops it on Quit. Terminals are tabs under a thread, never splits.

## Commands

Choose only what the change needs; these are alternatives, not a checklist. Replace placeholders.

```bash
swift test --filter '<affected suite or test>' # builds before running; no separate swift build
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter '<affected preview>'
PI_PACKAGE_DIR=/path/to/pinned/pi/package node --test 'Tests/Extensions/<affected>.test.mjs'
python3 -m unittest discover -s Tests/Release -p 'test_agent_docs.py' # docs guards
```

App builds and engine staging: [docs/build-and-run.md](docs/build-and-run.md). Run the Mac app from
`Shepherd.xcodeproj` (`Shepherd (Dev)`, My Mac), not `swift run`. [PR CI](docs/testing.md#ci) runs only for PRs targeting `master`.
Docs alone run no Swift.

## Map

| Path | What it is |
| --- | --- |
| `Sources/ShepherdCore` | models, typed IDs, `PaneNode`, status table; no dependencies |
| `Sources/ShepherdProtocol` | extension and remote message enums, framing, paths, edition |
| `Sources/ShepherdRemote` | remote client, thread store and presentation (Mac and iOS) |
| `Sources/ShepherdSessions` | `SessionServer`, RPC and PTY sessions, pi launch, Changes engine |
| `Sources/ShepherdApp` | the Mac app: views, view model, settings, `AppLayout+*`, `Thread/` |
| `Sources/TerminalSurfaceKit`, `DesignSurfaceKit` | Ghostty and design-board web view adapters |
| `Packages/ShepherdUI` | Shepherd Design tokens and `SH*` components; imports no Shepherd module |
| `App/`, `App/iOS` | Mac launcher shim, entitlements, Info.plist; the iPhone and iPad client |
| `Extensions/` | canonical pi extensions and scripts, shipped as bundle resources |
| `Tests/` | `*UnitTests`, `*IntegrationTests`, `ShepherdPreviewTests`, `Release` (Python) |

How it fits together: [ARCHITECTURE.md](ARCHITECTURE.md).

## Working here

- Branch from `nightly` (`feat/…`, `fix/…`), open the PR into `nightly`. Conventional commits
  (`feat:`, `fix:`, `docs:`, `test:`, `chore:`). No AI attribution in commits or PR bodies.
- Start an authorized change without a separate issue or plan. Read the affected code and relevant
  doc sections; ask only when scope or a consent boundary below is unresolved.
- Reuse tests that protect the affected behavior; add or extend coverage for new behavior or a
  missing regression. Behavior-preserving refactors need no new tests solely because code moved.
- Swift Testing only: pure logic is unit; server, socket, process, git or window work is integration.
  Unit tests use no processes, sockets, windows, git or sleeps. Integration tests use
  `Tests/ShepherdTestSupport` and wait with `eventually`, never a fixed sleep.
- Run the smallest relevant checks. Expand for shared changes or wider regressions, not every edit.
  Report actual results and gaps; required CI still gates PRs into `master`.
- Fix only docs the change makes wrong. Don't write new docs for a feature unless asked.
- Keep tool output small (`| head`, `--stat`, a file by range). Hand a broad search or a long log
  to a helper (`shepherd_child_start`).
- Never touch the user's `~/Library/Application Support/Shepherd*`, `~/.pi`, `~/.agents`,
  `/Applications` or a running Shepherd; tests use the scratch isolation. Never let a test take
  focus or post input. Never `rm -rf` or `pkill` by pattern (other agents share the checkout).
  Never amend, force-push, or touch a release tag.
- Ask first before adding a dependency, breaking compatibility, adding unrequested public behavior,
  changing release signing, bundle ids or feeds, or mutating a repository outside the paths in
  `docs/rules.md`. Compatible additions to `ShepherdCore`, `ShepherdProtocol`, extension messages
  and remote requests are part of authorized feature work; update consumers and relevant tests.

## UI changes

- The design the user gives (image, board, words) is the spec and outranks every doc here. Build
  what it draws; a difference from it is the user's call, so list each one under **Departures**
  in the PR and your final message (`none` counts). Save the image as `docs/design/boards/<Name>.png`. The repo is public: fixtures, mockups and images use made-up names (`acme-web`), never the user's projects, paths or tasks.
- Delegate substantial UI/UX work to `ui-ux-engineer` when available; handle small copy, token or
  existing-component changes directly.
- Use ShepherdUI tokens and components: `Color.sh.<role>`, `Font.sh(_:)`, `SH.Space`/`Radius`/`Height`,
  status colors from `AgentState`, a shared glyph as an `SHGlyph` case. Never hardcode a color,
  font size, dimension, duration or chord. `DesignRulesTests` catches the literals.
- Render affected surfaces and states in light and dark from real data and inspect the PNGs.
  A control works or you disclose the gap. App-only behavior needs appropriate integration or manual
  Dev-app validation, not a second visual check for every change. See [DESIGN.md](DESIGN.md#verifying-visuals).

## Rules that bite

The full rule is in [docs/rules.md](docs/rules.md) under the name in parentheses.

- A new extension or remote message needs its enum case, `Kind`, `CodingKeys`, both codec arms, a
  round-trip row, and `speaksFor`/`replyID`; a new `SessionServer` mutation needs an integration
  test; new persisted fields decode with defaults. (Contracts)
- `Extensions/*` is the one copy of each pi extension, shipped in ShepherdSessions' resource bundle;
  extensions stay dependency-free, inert without their env vars, and never throw into pi. (Embedded extensions)
- One serial queue owns server state: never `.sync` between server queues, never wait on it from
  the main thread. Callbacks hop to main. (Server concurrency)
- State is `@Observable`, never `ObservableObject`. Views take plain `Equatable` values and don't
  parse or filter in `body`. Long lists are lazy stacks with one view per element. (State is Observation)
- Switching agents is a visibility flip, never a remount: keep the `AgentLayoutDeck`, never put
  layouts back in one view graph or rekey hosts. (Switching is a visibility flip)
- Chords resolve through `KeybindingsStore`; every chord the chrome uses is in `appOwnedChords`.
- Only `TerminalHost.swift` imports TerminalSurfaceKit, only `DesignHost.swift` imports
  DesignSurfaceKit. Boards are untrusted HTML; never copy Claude Design's code.
- An extension-socket connection speaks only for the agent whose pi opened it; check before serving.
  Browser tools act only on their own thread's page; page text is untrusted.
- Only the listed paths mutate a repository. (Only these paths mutate repositories) Agents may
  `git worktree remove` (and `git worktree prune`) worktrees they created; never another's.
- Shepherd's pi home is `<support>/pi`; never write into the user's `~/.pi` or run their `pi`/`npm`.
  `PiLaunch` builds every launch line.
- Anything that runs without a person watching (a loop, a scheduler, an unattended model call)
  never resumes after a restart (except bounded recovery of previously authorized ordinary agent
  work; enabled automation schedules keep firing, with or without the app) and treats tool output
  and prose as data. (Features that act on their own)
- Unix socket paths cap at 104 bytes: tests build them under short temp paths. Terminal replay is an
  ANSI snapshot, not raw bytes. ([docs/gotchas.md](docs/gotchas.md))

## Read more, when you are doing…

| You are | Read |
| --- | --- |
| Building or running the Mac app, choosing a scheme | [docs/build-and-run.md](docs/build-and-run.md) |
| Changing or staging the bundled engine | [docs/pi-engine.md](docs/pi-engine.md) |
| Writing or changing a test, or CI | [docs/testing.md](docs/testing.md) |
| Changing UI | [DESIGN.md](DESIGN.md), then the surface's board in `docs/design/boards/`, then its code |
| Touching contracts, extensions, concurrency, terminals, browser, layouts, repos | [docs/rules.md](docs/rules.md) |
| Changing the remote listener or protocol | [docs/remote-protocol.md](docs/remote-protocol.md) |
| Branching, committing, releasing, signing | [docs/releases.md](docs/releases.md) |
| Setting or debugging an env var | [docs/environment.md](docs/environment.md) |
| Adding a tool or prompt line (each costs tokens in every thread) | [docs/context-budget.md](docs/context-budget.md) |
| A feature area (threads, subagents, changes, worktrees, browser, skills, designs, MCP, projects, goals) | its code and tests; there is no feature doc. [ARCHITECTURE.md](ARCHITECTURE.md) says where each lives |

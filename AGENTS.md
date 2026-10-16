# AGENTS.md

Shepherd is a native macOS app (SwiftUI, macOS 26+) for running and supervising many `pi` coding
agents, with an iPhone and iPad client (`App/iOS`). Every agent is `pi --mode rpc` on pipes, owned
in-process by `SessionServer` and drawn as a native thread. There is no daemon: sessions live and
die with the app. Terminals are tabs under a thread, never splits. More: [docs/overview.md](docs/overview.md).

## Commands

```bash
python3 scripts/pi_engine.py stage            # once, and whenever scripts/pi-engine-pin.json changes
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile build
swift build                                   # every package target
swift test --filter UnitTests                 # fast tier: seconds
swift test --filter IntegrationTests          # real server, stub pi, git, off-screen windows
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter PreviewTests   # PNG of every surface
PI_PACKAGE_DIR=/path/to/pinned/pi/package node --test Tests/Extensions/*.test.mjs
python3 -m unittest discover -s Tests/Release # release rules, docs size and link guards
python3 scripts/design_section.py "<board or heading>"   # one section of a design spec
python3 scripts/design_section.py --docs docs "<heading>"  # one section of any doc in docs/
```

Run the Mac app from `Shepherd.xcodeproj` (scheme `Shepherd (Dev)`, My Mac); there is no `swift run`.
Nightly PRs run unit, smoke and affected suites; docs alone run no Swift
([docs/build-and-run.md](docs/build-and-run.md), [docs/testing.md](docs/testing.md)).

## Map

| Path | What it is |
| --- | --- |
| `Sources/ShepherdCore` | models, typed IDs, `PaneNode`, status table; no dependencies |
| `Sources/ShepherdProtocol` | extension and remote message enums, framing, paths, edition |
| `Sources/ShepherdRemote` | remote client, thread store and presentation (Mac and iOS) |
| `Sources/ShepherdSessions` | `SessionServer`, RPC and PTY sessions, pi launch, Changes engine |
| `Sources/ShepherdApp` | the Mac app: views, view model, settings, `AppLayout+*`, `Thread/` |
| `Sources/TerminalSurfaceKit`, `DesignSurfaceKit` | Ghostty and design-board web view adapters |
| `Packages/ShepherdUI` | Night Watch tokens and `NW*` components; imports no Shepherd module |
| `App/`, `App/iOS` | Mac launcher shim, entitlements, Info.plist; the iPhone and iPad client |
| `Extensions/` | canonical pi extensions and scripts, shipped as bundle resources |
| `Tests/` | `*UnitTests`, `*IntegrationTests`, `ShepherdPreviewTests`, `Release` (Python) |

How it fits together: [ARCHITECTURE.md](ARCHITECTURE.md).

## Working here

- Branch from `nightly` (`feat/…`, `fix/…`), open the PR into `nightly`. Conventional commits
  (`feat:`, `fix:`, `docs:`, `test:`, `chore:`). No AI attribution in commits or PR bodies.
- Write the test that matches the change: pure logic is a unit test; the server, a socket, a
  process, git or a window is an integration test; a visible change gets a preview in both
  appearances. Swift Testing only. Unit tests use no processes, sockets, windows, git or sleeps.
  Integration tests use `Tests/ShepherdTestSupport` and wait with `eventually`, never a fixed sleep.
- Start with the affected code and the smallest relevant check. Full suites are for shared changes
  or investigating a wider regression, not every edit.
- Fix a doc the change makes wrong. Don't write new docs for a feature unless asked.
- Keep tool output small (`| head`, `--stat`, a file by range). Hand a broad search or a long log
  to a helper (`shepherd_child_start`).
- Never touch the user's `~/Library/Application Support/Shepherd*`, `~/.pi`, `~/.agents`,
  `/Applications` or a running Shepherd; tests use the scratch isolation. Never let a test take
  focus or post input. Never `rm -rf` or `pkill` by pattern (other agents share the checkout).
  Never amend, force-push, or touch a release tag.
- Ask first before adding a dependency, changing a contract (`ShepherdCore`, `ShepherdProtocol`,
  an extension message, a remote request), changing release signing, bundle ids or feeds, or
  mutating a repository outside the paths in `docs/rules.md`.

## UI changes

- The design the user gives (image, board, words) is the spec and outranks every doc here. Build
  what it draws; a difference from it is the user's call, so list each one under **Departures**
  in the PR and your final message (`none` counts). Save the image as `docs/design/boards/<Name>.png`.
- Find the surface's spec with `python3 scripts/design_section.py --boards | grep -i <word>` and
  print only that section. Don't read whole spec files.
- Use ShepherdUI tokens and components: `Color.nw.<role>`, `Font.nw(_:)`, `NW.Space`/`Radius`/`Height`,
  status colors from `AgentState`, a shared glyph as an `NWGlyph` case. Never hardcode a color,
  font size, dimension, duration or chord. `DesignRulesTests` catches the literals.
- Render the surface in light and dark from real data and look at the PNGs before you call it done.
  A control the design draws does something, or you say it doesn't. [DESIGN.md](DESIGN.md) has the rules.

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
- Only the listed paths mutate a repository; never prune worktrees. (Only these paths mutate repositories)
- Shepherd's pi home is `<support>/pi`; never write into the user's `~/.pi` or run their `pi`/`npm`.
  `PiLaunch` builds every launch line.
- Anything that runs without a person watching (a loop, a scheduler, an unattended model call)
  ships a default bound with a test that hits it, never resumes after a restart, and treats tool
  output and prose as data. (Features that act on their own)
- Unix socket paths cap at 104 bytes: tests build them under short temp paths. Terminal replay is an
  ANSI snapshot, not raw bytes. ([docs/gotchas.md](docs/gotchas.md))

## Read more, when you are doing…

| You are | Read |
| --- | --- |
| Building, running, choosing a scheme | [docs/build-and-run.md](docs/build-and-run.md), [docs/pi-engine.md](docs/pi-engine.md) |
| Writing or changing a test, or CI | [docs/testing.md](docs/testing.md) |
| Changing UI | [DESIGN.md](DESIGN.md), then your board's section via `design_section.py` |
| Touching contracts, extensions, concurrency, terminals, browser, layouts, repos | [docs/rules.md](docs/rules.md) |
| Changing the remote listener or protocol | [docs/remote-protocol.md](docs/remote-protocol.md), [docs/ios/CONTRACTS.md](docs/ios/CONTRACTS.md) |
| Changing agent launch, status, automations | [docs/data-flow.md](docs/data-flow.md) |
| Branching, committing, releasing, signing | [docs/releases.md](docs/releases.md) |
| Setting or debugging an env var | [docs/environment.md](docs/environment.md) |
| Adding a tool or prompt line (each costs tokens in every thread) | [docs/context-budget.md](docs/context-budget.md) |
| A feature area (threads, subagents, changes, worktrees, browser, skills, designs, MCP, projects, goals) | the file of that name in `docs/`, one section at a time: `design_section.py --docs docs "<heading>"` (the big ones run to 40k tokens) |
| The iPhone or iPad client | [docs/ios/README.md](docs/ios/README.md) |

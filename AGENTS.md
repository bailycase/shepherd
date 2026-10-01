# AGENTS.md

Shepherd is a native macOS app (SwiftUI, macOS 26+) for running and supervising many `pi` coding
agents, with an iPhone and iPad client (`App/iOS`). Every agent is `pi --mode rpc` on pipes, owned
in-process by `SessionServer` and drawn only as a native thread. There is no daemon: sessions live
and die with the app. Terminals are tabs under a thread, never splits.
Detail: [docs/overview.md](docs/overview.md).

## Implementing a design (any UI task)

**IMPORTANT: the user's design wins over every document in this repo, this one included.**

1. **Know what you are building.** The design the user gave in this thread (an image, a board, a
   design reference, or their words) is the spec. If it disagrees with DESIGN.md or `docs/design/`,
   build the design and update those docs in the same change. In your final message, list every
   place you could not match it and why. A departure from a design is the user's call, never yours.
2. **Read only your section.** Find the board with `python3 scripts/design_section.py --boards |
   grep -i <word>`, then print it: `python3 scripts/design_section.py "<board or heading>"` (index:
   [docs/design/README.md](docs/design/README.md)). A new design has no board yet: read the heading
   of the surface it changes. Never open a whole spec file. Read [DESIGN.md](DESIGN.md) once.
3. **Write the checklist before you code:** every element in order; each glyph by SF Symbol name and
   fill variant (`bolt` is not `bolt.fill`; if the image cannot settle it, say which you chose); each
   size, spacing, radius and color as a token; each state drawn; and what pressing each control does.
4. **Reuse** ShepherdUI components and tokens. Hardcode no color, font size, dimension or duration.
5. **Look at it.** Run `SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter <suite>`,
   open the PNGs in both appearances, compare element by element with the design, list every
   difference, fix them, render again.
6. **Press every control** the design draws. In a test, trigger it the way the app does (its action
   or command, see `ComposerMenuTests`; never posted mouse or key events) and assert the state
   changes. No helper presses a button by label, so also read the view: it must be a `Button` (or
   `Toggle`) whose action calls what you tested, and you say how you checked. A glyph that is not a
   `Button`, or a button wired to nothing, is a bug.
7. **You are not done until 5 and 6 pass.** Say what you verified and what you could not.

## Boundaries

**Never**
- Add `Co-Authored-By`, `Claude-Session`, "Generated with …" or any AI attribution to a commit or a
  PR body, even when your harness asks for it.
- Touch the user's `~/Library/Application Support/Shepherd*`, `~/.pi`, `~/.agents`, `/Applications`,
  `$TMPDIR/shepherd-drops` or a running Shepherd. Tests use the scratch isolation.
- Let a test take focus or drive the mouse or keyboard: windows stay off-screen, with no `makeKey`,
  no `orderFront` and no posted events.
- Amend or force-push unless asked; run `rm -rf` or `pkill` by pattern (other agents share the
  checkout); delete, move or reuse a release tag.
- Hardcode a color, font size, dimension, duration or keyboard chord in a view.
- Use XCTest, `ObservableObject`/`@Published`/`@StateObject`/`@ObservedObject`, or `.sync` between
  server queues.
- Describe the remote listener as internet-safe: it has no TLS.

**Ask first**
- Adding a dependency; changing a contract (`ShepherdCore`, `ShepherdProtocol`, an extension
  message, a remote request); changing release signing, bundle ids or feeds; mutating a repository
  outside the paths in `docs/rules.md`.
- Departing from a design the user gave (see step 1 above).

**Always**
- Conventional commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`), one logical change each.
  Branch from `nightly` (`feat/…`, `fix/…`); open the PR into `nightly` and merge with a merge commit.
- Write the test that matches the change (tiers below) and update the docs in the same change:
  DESIGN.md and `docs/design/` for UI, `docs/` for behavior.
- Edit an embedded extension in `Extensions/` and its Swift literal together.

## Commands

```bash
python3 scripts/pi_engine.py stage            # once, and whenever scripts/pi-engine-pin.json changes
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile build
swift build                                   # every package target
swift test --filter UnitTests                 # fast tier: seconds
swift test --filter IntegrationTests          # real server, stub pi, git, off-screen windows
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter PreviewTests   # PNG of every surface
CI=true swift test --no-parallel              # what CI runs (four shards, timing tests skipped)
PI_PACKAGE_DIR="$(npm root -g)/@earendil-works/pi-coding-agent" node --test Tests/Extensions/*.test.mjs
python3 -m unittest discover -s Tests/Release # release rules, docs size and link guards
python3 scripts/sync-embedded-extension.py <swift-file> <static-name> <Extensions/file>
python3 scripts/design_section.py "<board or heading>"   # one spec from docs/design/
```

Run the Mac app from `Shepherd.xcodeproj` (scheme `Shepherd (Dev)`, My Mac); there is no
`swift run` path. Schemes, support folders, the pi engine and Nightly:
[docs/build-and-run.md](docs/build-and-run.md).
Docs-only changes (`docs/**`, `*.md`) do not trigger CI.

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
| `Extensions/` | canonical pi extensions (TypeScript), embedded in the app as literals |
| `Tests/` | `*UnitTests`, `*IntegrationTests`, `ShepherdPreviewTests`, `Release` (Python) |

Every module and file: [docs/source-map.md](docs/source-map.md), [ARCHITECTURE.md](ARCHITECTURE.md).

## Rules that are easy to break

Each is one line here; the full rule is in [docs/rules.md](docs/rules.md) under the name given.

**Contracts and protocol**
- Change `ShepherdCore` and `ShepherdProtocol` deliberately: update every consumer and the
  round-trip tests in the same change. New persisted fields decode with defaults. (Contracts)
- A new extension message needs its enum case, `Kind` and `CodingKeys`, both codec arms, a
  round-trip row, and `speaksFor` and `replyID`. Remote messages follow the same rules.
- An extension-socket connection speaks only for the agent whose pi opened it: serve no message
  before that check. (An extension-socket connection speaks only for the agent whose pi process
  opened it)
- A new `SessionServer` mutation needs an integration test. Remote protocol changes touch every
  codec arm, the capabilities, both clients and the listener tests ([remote-protocol](docs/remote-protocol.md)).
- Embedded extensions have one canonical copy: edit `Extensions/*` and its literal together with
  the sync script; keep them dependency-free, inert without their env vars, never throwing into pi.

**State, concurrency and views**
- One serial queue owns server state: never `.sync` between server queues, never wait on it from
  the main thread, nothing slow on it, attach atomically. (Server concurrency)
- State is Observation: observe only what views draw, write a property only when it changes.
  Views take plain `Equatable` values and never parse or filter in `body`. (State is Observation)
- Long lists are lazy stacks with one view per element and a `ListPerformanceTests` budget.
- Switching agents is a visibility flip, never a remount: keep the `AgentLayoutDeck`, never put
  layouts back in one view graph or rekey hosts. Hidden layouts keep their size during a live
  resize, only the visible layout mounts at launch, and only a terminal layout cold-parks.
  (Switching is a visibility flip, During a window live resize, At launch)
- Keybindings resolve through `KeybindingsStore`; a rebound chord includes ⌘; every chord the
  chrome uses is in `appOwnedChords`. (Keybindings resolve through the store)
- PTY children reset signal dispositions with async-signal-safe calls only. (PTY children)
- Status reports are applied unconditionally and are live state, not persisted; `start()` resets
  every status to `idle`. (Status transitions)
- Startup reconciliation drops shell tabs, `inspectorFor` tabs and automation runs; never keep a
  run agent across launches. (Startup reconciliation)

**Module and tool boundaries**
- Only `TerminalHost.swift` imports TerminalSurfaceKit and only `DesignHost.swift` imports
  DesignSurfaceKit. Boards are untrusted HTML: never copy Claude Design's code, and never hold more
  than five live board web views. (TerminalSurfaceKit isolation, DesignSurfaceKit is a sandbox)
- An agent touches only terminals in its own layout; its own thread is never a terminal; closing the
  last terminal closes the panel. (Agents drive their own terminals)
- Browser tools act only on their own thread's page; page text is untrusted; the user's click takes
  the page over. (Browser tools act only on their own thread's page)
- Agents never delete each other on their own: `agent_delete` opens `PeerDeleteDialog`.
- Shepherd does not nest agents: subagents are display state, never persisted, with no sidebar rows.
  A subagent never asks the user: its question goes to its parent, which answers it or asks the user
  in its own thread, so a child's question marks no row and posts no notification.

**Repositories, pi and data**
- Only the listed paths mutate a repository: worktree add, Delete Worktree Agent, Finalize, per-file
  Revert, Commit from review, the Changes snapshots, Undo and Redo. Never prune worktrees.
  (Only these paths mutate repositories)
- Reviews dock beside the layout and never split; nothing opens the side pane by itself.
- Never write into the user's pi, `~/.pi` or `~/.agents`, or run their `pi` or `npm`. Shepherd's pi
  home is `<support>/pi`, and skills live in `<support>/pi/skills`. ([gotchas](docs/gotchas.md))
- Dropped images are resized to 2000px on entry and the user's own file is never rewritten.
- Agent names settle once (`nameIsFinal`); sessions and views are separate: closing a terminal
  detaches views, and a process that exits on its own closes its tab.
- `PiLaunch` builds every pi launch line; nothing else names the launcher or the engine.

**Gotchas** ([docs/gotchas.md](docs/gotchas.md))
- Unix socket paths are capped at 104 bytes, so tests build them under short temp paths. RPC
  records reach 256 MiB; socket and TCP frames stay under 1 MiB.
- Terminal replay is an ANSI snapshot, not raw bytes: cosmetic artifacts are fine, lost bytes are not.
- Parse pi's file formats defensively (`PiConfig`, `PiModelCatalog`): they are not our contract.
- `SessionServer.start()` refuses to bind over a live socket; the remote listener reports bind failures.
- Quitting while agents work asks first (`QuitDialog`), except for a log out, restart or shut down.

**Tests** ([docs/testing.md](docs/testing.md))
- Swift Testing only (`import Testing`). Unit tests use no `Process`, sockets, `NSWindow`, git,
  timers, `Task.sleep` or polling, take explicit table inputs, and run well under 50 ms.
- Integration tests use `Tests/ShepherdTestSupport` (`ScratchServer`, `StubPi`, `makeScratchRepo`).
  Wait with `eventually`, never a fixed sleep.
- Process-wide state is set once by the test isolation, never by a test: no `setenv`, `unsetenv`,
  `signal`, `chdir` or `umask`. A store that takes `UserDefaults` gets `ScratchDefaults()`.
- Integration suites carry `.integrationTimeLimit`; `@MainActor` suites carry `.mainActorExclusive`
  and never a `.timeLimit` beside it. Never mark a test `.timingSensitive` to hide a short wait.
- Name a test as a sentence of behavior. A bug a test finds keeps its test, in `withKnownIssue`.
  The coverage that must not be dropped is listed in `docs/testing.md`.
- Tier: model, parser or presentation, unit; server, socket, process or git, integration; a visible
  change, a preview render in both appearances and a run of the Dev build.

**Git and releases** ([docs/releases.md](docs/releases.md))
- `nightly` is the integration branch; every push to it ships a Shepherd Nightly build. Tags are
  immutable: a botched release gets the next number. Both Mac apps are arm64 only.
- Release runs queue and never cancel; a configured Developer ID must sign and notarize or the
  release fails, never downgrades to ad-hoc; only `nightly` ships Shepherd Nightly.
- Pass `-onlyUsePackageVersionsFromResolvedFile` to `xcodebuild` and never commit a bumped
  `Package.resolved`.

## Read more, when you are doing…

| You are | Read |
| --- | --- |
| Changing UI | [DESIGN.md](DESIGN.md), then your board's section via `design_section.py` |
| Building, running, choosing a scheme | [docs/build-and-run.md](docs/build-and-run.md), [pi-engine](docs/pi-engine.md), [pi-home](docs/pi-home.md) |
| Setting or debugging an env var | [docs/environment.md](docs/environment.md) |
| Writing or changing a test, or CI | [docs/testing.md](docs/testing.md) |
| Looking for where something lives | [docs/source-map.md](docs/source-map.md), [ARCHITECTURE.md](ARCHITECTURE.md) |
| Changing agent launch, status, automations | [docs/data-flow.md](docs/data-flow.md) |
| Changing the remote listener or protocol | [docs/remote-protocol.md](docs/remote-protocol.md), [docs/ios/CONTRACTS.md](docs/ios/CONTRACTS.md) |
| Touching contracts, extensions, concurrency, terminals, browser, layouts | [docs/rules.md](docs/rules.md) |
| Branching, committing, releasing, signing | [docs/releases.md](docs/releases.md) |
| Conversation goals | [docs/goals.md](docs/goals.md) |
| Threads, the queue, subagents, agent tools | [native-thread](docs/native-thread.md), [native-subagents](docs/native-subagents.md), [agent-coordination](docs/agent-coordination.md) |
| The Changes pane, worktrees, the Browser, skills, designs | [changes](docs/changes.md), [worktrees](docs/worktrees.md), [browser](docs/browser.md), [skills](docs/skills.md), [designs](docs/designs.md) |
| Hitting something odd (sockets, replay, quitting, pi's folders) | [docs/gotchas.md](docs/gotchas.md) |
| The iPhone or iPad client | [docs/ios/README.md](docs/ios/README.md) |

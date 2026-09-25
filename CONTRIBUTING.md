# Contributing to Shepherd

Shepherd is an opinionated macOS app for supervising coding agents: native agent threads, with
real terminals only as panes beside a thread. Changes should keep it focused on that. For a large
feature or behavior change, open an issue before writing the implementation.

## Read first

- [AGENTS.md](AGENTS.md): build and test commands, the source map, and the rules that are easy to
  break (protocol contracts, embedded extensions, concurrency, tokens, keybindings, repository
  mutations).
- [ARCHITECTURE.md](ARCHITECTURE.md): module boundaries, ownership, and data flow.
- [DESIGN.md](DESIGN.md): the authority on UI and interaction, and the reference for Night
  Watch, the design system in `Packages/ShepherdUI`.

## Branches

Branch from `nightly` and target `nightly` with your pull request. Use `feat/…` for features and
`fix/…` for fixes. PRs merge with a merge commit.

## Build and run

```sh
swift build
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile build
```

Keep `-onlyUsePackageVersionsFromResolvedFile`: without it, a build from a fresh DerivedData can
rewrite the Xcode project's `Package.resolved` with newer package versions.

Run the app through the `Shepherd (Dev)` scheme in Xcode; there is no `swift run` path for the
GUI. The Dev scheme keeps its state in `~/Library/Application Support/Shepherd-dev`, so it never
disturbs an installed copy. The `Shepherd (Nightly)` scheme builds Shepherd Nightly, the separate
app every push to `nightly` ships.

## Tests

Tests use Swift Testing and come in tiers. Run the smallest one that covers your change first,
then everything.

| Tier | Command | Scope |
| --- | --- | --- |
| Unit | `swift test --filter UnitTests` | Pure logic: no processes, sockets, windows, git, or sleeps. Seconds for the whole tier. |
| Integration | `swift test --filter IntegrationTests` | A real `SessionServer` (`ScratchServer`), the scripted stub pi (`StubPi.command`), git scratch repos, off-screen windows. Waits are named `eventually(...)` polls, never fixed sleeps. |
| Previews | `SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter PreviewTests` | Offscreen renders of every surface, in light and dark, written as PNGs. Skipped without the variable. |
| Everything | `swift test` | All of the above, in parallel. CI runs the same tests serially, split across four runners (AGENTS.md, Testing). |
| Extensions | `PI_PACKAGE_DIR=<installed pi package> node --test Tests/Extensions/*.test.mjs` | The bundled pi extensions, against a local fake provider. |
| Release rules | `python3 -m unittest discover -s Tests/Release` | `scripts/release.py`: what each tag or push builds, which feeds each release lands in, and its agreement with the Xcode project and the apps. CI runs it too. |

An opt-in run against a real model is gated on `SHEPHERD_LIVE_MODEL` (for example
`cpa/~anthropic/claude-haiku-latest`). Shared helpers live in `Tests/ShepherdTestKit` (any tier) and
`Tests/ShepherdTestSupport` (integration and previews).
[AGENTS.md](AGENTS.md#testing) says which tier a change needs and which coverage must never be
dropped.

**Tests must never take your focus or drive your mouse or keyboard.** Test windows are
off-screen, borderless, and ordered back. Tests never post synthetic input and never touch your pi
configuration, sessions, or a running Shepherd.

## Project rules

- Keep changes small, and put code in the narrowest existing owner.
- Don't add abstractions or validation without a current need.
- Add focused tests for the behavior you changed, in the right tier.
- When you change a protocol message, update every consumer and its round-trip test.
- Edit an `Extensions/` source and its embedded Swift literal together
  (`scripts/sync-embedded-extension.py`); a test enforces byte identity.
- Use ShepherdUI (`Color.nw`, `Font.nw`, `NW.Space`/`Radius`/`Height`) and its shared
  components, never hardcoded colors, fonts, or sizes. A screen's own dimensions go in its
  domain's `AppLayout+<Domain>.swift`. A new color role must pass the contrast tests in both
  variants.
- Check visible changes in both light and dark appearance, with previews and in the running app.
  Debug builds have a Component Gallery in the View menu.
- Don't commit credentials, tokens, sessions, logs, caches, or local runtime state.

## Commits

Use Conventional Commit subjects, one logical change per commit:

```text
feat: add remote host filtering
fix: preserve pane focus after switching
docs: explain the release channels
refactor: simplify session adoption
test: cover stale-session answers
chore: update a dependency
```

Use `feat!:` for a breaking change. Don't add AI or tool attribution lines.

## Pull requests

Fill in the [pull request template](.github/pull_request_template.md). It asks for:

- what changed and why
- the test tiers you ran and what they showed
- light and dark previews for any visible change

Don't claim checks passed unless you ran them and saw the result.

## Security

Don't open public issues or pull requests for suspected vulnerabilities. Follow
[SECURITY.md](SECURITY.md).

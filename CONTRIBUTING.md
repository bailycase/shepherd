# Contributing to Shepherd

Shepherd is an opinionated macOS app for supervising coding agents: native agent threads, with
real terminals only as tabs under a thread. Changes should keep it focused on that. For a large
feature or behavior change, open an issue before writing the implementation.

## Read first

- [AGENTS.md](AGENTS.md): the short rule sheet and exact commands, with links to the build, testing,
  source map and [rules](docs/rules.md) (protocol contracts, embedded extensions, concurrency,
  tokens, keybindings, repository mutations).
- [ARCHITECTURE.md](ARCHITECTURE.md): module boundaries, ownership, and data flow.
- [DESIGN.md](DESIGN.md): the rules for UI changes, with the spec of each surface in
  [docs/design/](docs/design/README.md). Night Watch, the design system, is in `Packages/ShepherdUI`.

## Branches

Branch from `nightly` and target `nightly` with your pull request. Use `feat/…` for features and
`fix/…` for fixes. PRs merge with a merge commit.

## Build and run

Stage the bundled engine before the first Mac build, and again after its pin changes
([docs/pi-engine.md](docs/pi-engine.md)).

```sh
python3 scripts/pi_engine.py stage
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
| Everything | `swift test` | All of the above, in parallel. CI runs one serial process: unit, smoke and affected suites for ordinary `nightly` PRs, all suites for shared changes and `master` ([docs/testing.md](docs/testing.md)). |
| Extensions | `PI_PACKAGE_DIR=<installed pi package> node --test Tests/Extensions/*.test.mjs` | The bundled pi extensions, against a local fake provider. |
| Release rules | `python3 -m unittest discover -s Tests/Release` | `scripts/release.py`: what each tag or push builds, which feeds each release lands in, and its agreement with the Xcode project and the apps. CI runs it too. |

An opt-in run against a real model is gated on `SHEPHERD_LIVE_MODEL` (for example
`cpa/~anthropic/claude-haiku-latest`). Shared helpers live in `Tests/ShepherdTestKit` (any tier) and
`Tests/ShepherdTestSupport` (integration and previews).
[docs/testing.md](docs/testing.md) says which tier a change needs and which coverage must never be
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
fix: preserve terminal focus after switching
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
- for UI work, the design you built from, every departure from it, what you rendered and the
  controls you used ([docs/design-workflow.md](docs/design-workflow.md)); the `pr-body` check fails
  a UI change that leaves those empty
- for a feature that acts on its own, its bounds, where its data goes, what a restart and Stop do
  to it, and the decisions you made unasked ([docs/rules.md](docs/rules.md))

CI runs unit, smoke and affected suites for ordinary `nightly` PRs, and all suites for shared
or unknown paths, `master`, daily runs and `full-ci`. Builds use GitHub's macOS runner unless
`SHEPHERD_SELFHOSTED_ENABLED=true` explicitly enables an isolated self-hosted Mac for maintainer
PRs and Nightly releases. The shared Mac stays offline to protect other apps. Docs alone run no Swift. A test that fails is red:
there is no retry, so a flaky test is a bug to fix in the test. A push to `nightly` builds and
ships without tests. Require `CI`, not the manual `UI diagnostics` check. With self-hosted
builds disabled, a trusted Nightly dispatch with `diagnostics=ui` can seed the hosted cache
without changing PR coverage or Nightly push behavior. PR cache saves serve only that same
PR, not its base or siblings; reseed Nightly when the toolchain or resolved lock changes.
Cache reuse does not establish the unmet warm five-minute test goal ([docs/testing.md](docs/testing.md)).

Don't claim checks passed unless you ran them and saw the result.

## Security

Don't open public issues or pull requests for suspected vulnerabilities. Follow
[SECURITY.md](SECURITY.md).

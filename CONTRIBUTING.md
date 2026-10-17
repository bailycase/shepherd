# Contributing to Shepherd

Shepherd is an opinionated macOS app for supervising coding agents: native agent threads, with
real terminals only as tabs under a thread. Keep changes focused on that. Discuss substantial
unsolicited changes before implementing them. An accepted issue or explicit maintainer request
is enough to start; no separate issue or plan is required.

## Read first

Start with [AGENTS.md](AGENTS.md), the affected code and only the relevant reference sections.
Read [ARCHITECTURE.md](ARCHITECTURE.md) when changing ownership or data flow. For UI, follow
[DESIGN.md](DESIGN.md) and the affected surface's spec, fetched with
`python3 scripts/design_section.py "<board or heading>"`. No repository-wide reading pass is needed.

## Branches

Branch from `nightly` and target `nightly` with your pull request. Use `feat/…` for features and
`fix/…` for fixes. PRs merge with a merge commit.

## Build and run

For package code, `swift test --filter '<affected suite or test>'` builds before running;
no separate `swift build` or Xcode build is a prerequisite. Filtered execution can still require
a broad package compilation, especially on a cold build.

Build the app when the change needs app-level validation, such as launcher, resources or Xcode
configuration changes. Use the isolated `Shepherd (Dev)` scheme, never an installed copy.
[Build instructions](docs/build-and-run.md) cover engine staging and the pinned-package Xcode
command. There is no `swift run` path for the GUI.

## Tests

Use Swift Testing. Run the smallest suite or test selection that protects the affected behavior.
Existing coverage counts; add or extend tests for new behavior or an unprotected regression.
A behavior-preserving refactor does not need new tests just because code moved. Expand validation
for shared changes or a wider regression, not by default; required PR CI still runs before merge.

| Tier | Command | Scope |
| --- | --- | --- |
| Unit | `swift test --filter '<affected unit suite>'` | Pure logic: no processes, sockets, windows, git, or sleeps. |
| Integration | `swift test --filter '<affected integration suite>'` | A real `SessionServer` (`ScratchServer`), stub pi, scratch git repos and off-screen windows. Wait with `eventually(...)`, never fixed sleeps. |
| Previews | `SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter '<affected preview>'` | Render affected surfaces and states in light and dark, then inspect the PNGs. Skipped without the variable. |
| Extensions | `PI_PACKAGE_DIR=/path/to/pinned/pi/package node --test 'Tests/Extensions/<affected>.test.mjs'` | Bundled extensions against a local fake provider. |
| Release/docs rules | `python3 -m unittest discover -s Tests/Release -p '<affected test file>'` | Packaging, CI and docs guards; `test_agent_docs.py` covers instruction sizes and doc links. |

Replace placeholders with the affected suites or files. Full runs (`swift test`, previews enabled
separately) are for shared changes or broader investigations. See [testing](docs/testing.md#local-validation)
for a focused local recipe; docs-only changes need no Swift build or tests.

An opt-in run against a real model is gated on `SHEPHERD_LIVE_MODEL` (for example
`cpa/~anthropic/claude-haiku-latest`). Shared helpers live in `Tests/ShepherdTestKit` (any tier) and
`Tests/ShepherdTestSupport` (integration and previews).
[docs/testing.md](docs/testing.md) describes the tiers, isolation and CI selection.

**Tests must never take your focus or drive your mouse or keyboard.** Test windows are
off-screen, borderless, and ordered back. Tests never post synthetic input and never touch your pi
configuration, sessions, or a running Shepherd.

## Project rules

- Keep changes small, and put code in the narrowest existing owner.
- Don't add abstractions or validation without a current need.
- Protect changed behavior at the smallest useful test boundary; don't duplicate existing coverage.
- Update only docs the change makes inaccurate. Don't create new feature docs unless requested.
- When you change a protocol message, update every consumer and its round-trip test.
- `Extensions/` is the one copy of each pi extension; the app ships it as a resource bundle.
- Use ShepherdUI (`Color.nw`, `Font.nw`, `NW.Space`/`Radius`/`Height`) and its shared
  components, never hardcoded colors, fonts, or sizes. A screen's own dimensions go in its
  domain's `AppLayout+<Domain>.swift`. A new color role must pass the contrast tests in both
  variants.
- Render and inspect affected UI in light and dark from real data. Add integration or manual
  Dev-app checks for behavior previews cannot establish, such as focus, menus or app lifecycle;
  do not repeat a visual check in the app when the preview already covers it.
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
- the tests you ran and what they showed
- for UI work, the design you built from, every departure from it, and light and dark previews
- for a feature that acts on its own, its bounds, where its data goes, what a restart and Stop do
  to it, and the decisions you made unasked ([docs/rules.md](docs/rules.md))

[CI](docs/testing.md#ci) selects unit, smoke and affected suites for ordinary `nightly` PRs;
shared changes run broader coverage. Docs alone run no Swift. Require `CI`, not the manual
`UI diagnostics` check. A push to `nightly` builds and ships without rerunning tests.
Investigate failures, including flaky tests; do not weaken assertions to get a green run.

Don't claim checks passed unless you ran them and saw the result.

## Security

Don't open public issues or pull requests for suspected vulnerabilities. Follow
[SECURITY.md](SECURITY.md).

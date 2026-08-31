# Contributing to Shepherd

Shepherd is an opinionated macOS app for supervising coding agents. Changes should
keep the product focused on agent supervision and real terminal workflows.

## Before changing code

Read the documents relevant to your change:

- [`AGENTS.md`](AGENTS.md) contains build instructions, architecture rules, and known traps.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) defines dependency direction and state ownership.
- [`DESIGN.md`](DESIGN.md) governs UI and interaction. Read it before changing UI.

For large features or behavior changes, open an issue before writing the implementation.

## Branches

Development work branches from `nightly` and pull requests target `nightly`.

Use a descriptive branch name. Feature branches use the `feat/` prefix.

## Build and test

Run the smallest relevant test first, then the full suite:

```sh
swift build
swift test
```

For app changes, also build the development scheme:

```sh
xcodebuild \
  -project Shepherd.xcodeproj \
  -scheme 'Shepherd (Dev)' \
  -destination 'platform=macOS' \
  build
```

The GUI runs through the Xcode project, not `swift run`. Exercise UI and terminal
changes in the app before submitting them.

## Project rules

- Keep changes small and place code in the narrowest existing owner.
- Do not add abstractions or validation without a current need.
- Add focused tests for changed behavior.
- Add round-trip tests when changing protocol messages.
- Update canonical extension sources and their embedded Swift copies together.
- Use design tokens instead of hardcoded colors or dimensions.
- Do not commit credentials, tokens, sessions, logs, caches, or local runtime state.

`AGENTS.md` contains the complete contracts for protocols, concurrency, PTYs,
persistence, worktrees, remote access, and embedded extensions.

## Commits

Use Conventional Commit subjects:

```text
feat: add remote host filtering
fix: preserve pane focus after switching
docs: explain the release channels
refactor: simplify session adoption
chore: update a dependency
```

Keep each commit to one logical change. Do not add AI or tool attribution lines.

## Pull requests

A pull request should include:

- What changed and why.
- Related issues.
- Commands and manual checks actually performed.
- Screenshots or recordings for visible changes.
- Risks, tradeoffs, and useful starting points for review.

Do not claim checks passed unless you ran them and observed the result.

## Security

Do not open public issues or pull requests for suspected vulnerabilities. Follow
[`SECURITY.md`](SECURITY.md).

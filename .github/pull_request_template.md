<!--
Read CONTRIBUTING.md first. Pull requests target `nightly`.
Do not report security vulnerabilities in a pull request (see SECURITY.md).
-->

## Summary

<!-- What changed, in terms of observable behavior. -->

## Why

<!-- The problem this solves, and why Shepherd needs it. -->

## Related issues

<!-- "Fixes #123" when this PR should close an issue. N/A if none. -->

## Tests run

<!--
List only what you actually ran and what you observed. For example:
- `swift test --filter UnitTests`: passed (N tests, Xs)
- `swift test --filter IntegrationTests`: passed
- `PI_PACKAGE_DIR=… node --test Tests/Extensions/*.test.mjs`: passed
- `Shepherd (Dev)` Xcode build succeeded; manually <what you exercised>
If you did not exercise the changed behavior, write "Not tested" and why.
-->

## Previews (light and dark)

<!--
Required for any visible change. Render the affected surfaces with
`SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter PreviewTests` and attach the
`<surface>-light.png` / `<surface>-dark.png` pairs (or screenshots of the running app in both
appearances). N/A for changes with no visible effect.
-->

## Notes for reviewers

<!-- Risks, tradeoffs, open questions, and where review should start. -->

## Checklist

<!-- Remove items that do not apply. -->

- [ ] I reviewed my own diff.
- [ ] New or changed behavior has tests in the right tier (unit for pure logic, integration for server/process/git/window behavior), or I explained why none applies.
- [ ] UI changes follow `DESIGN.md`, use ShepherdUI tokens and components, and include light and dark previews.
- [ ] Protocol or extension changes update every consumer, the embedded Swift copy, and the round-trip tests.
- [ ] Documentation (`AGENTS.md`, `ARCHITECTURE.md`, `DESIGN.md`, `docs/`) matches the change.

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
CI runs a fast lane here (the unit tier and the suites your paths can affect); add the `full-ci`
label to run every suite.
-->

## UI changes

<!--
Delete this section if the change touches no UI. The pr-body check requires Departures, Rendered
and Controls used, each with an answer, when a file under Sources/ShepherdApp, Packages/ShepherdUI
or App/iOS changes (docs/design-workflow.md). A comment like this one is a placeholder, not an answer.
-->

- **Design:** <!-- the design you built from, saved in the repo (docs/design/boards/<Name>.png), and its board or section -->
- **Departures:** <!-- every difference from the design you kept, each with a reason. Write "none" if none. The user decides, never you. -->
- **Rendered:** <!-- every state, empty and long text, light and dark, text scale 1.5, drawn from the real data path (store, extension output, formatter), never strings copied from the design; where the images are -->
- **Controls used:** <!-- each control, pressed with ControlPress in every state it appears in: the request it sent, the state it left, its hit area -->
- **Not verified:** <!-- what you could not check, and why -->

## Features that act on their own

<!--
Delete this section if the change adds no loop, background work, unattended model call, scheduler
or notification. If it does, the pr-body check requires Bounds, Data, Restart and stop and
Decisions, each with an answer (docs/rules.md, Features that act on their own).
-->

- **Bounds:** <!-- the default cap on iterations, time and spend, and the test that reaches it -->
- **Data:** <!-- what is sent where; anything sent to a provider other than the thread's is opt-in and shown in the UI; how secrets are redacted -->
- **Restart and stop:** <!-- what a restart, Stop, Steer now, the queue, subagents, a retry, an error and compaction do to it, and the tests -->
- **Decisions:** <!-- every product decision you made that nobody asked for, so the user can overrule it. "none" if none -->

## Previews (light and dark)

<!--
Required for any visible change. Render the affected surfaces with
`SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter PreviewTests` and attach the
`<surface>-light.png` / `<surface>-dark.png` pairs (or screenshots of the running app in both
appearances), the images that Rendered above refers to. N/A for changes with no visible effect.
-->

## Notes for reviewers

<!-- Risks, tradeoffs, open questions, and where review should start. -->

## Checklist

<!-- Remove items that do not apply. -->

- [ ] I reviewed my own diff.
- [ ] New or changed behavior has tests in the right tier (unit for pure logic, integration for server/process/git/window behavior), or I explained why none applies.
- [ ] UI changes match the user's design (or list every place they do not), follow the rules in `DESIGN.md`, use ShepherdUI tokens and components, and include light and dark previews.
- [ ] UI work: I ran the design review (the `design-reviewer` helper with the `design-review` skill, or the same review myself) and fixed or reported what it found.
- [ ] A feature that acts on its own: I ran the risk review (`risk-reviewer`, `risk-review`, or the same review myself) and fixed or reported what it found.
- [ ] Protocol or extension changes update every consumer, the embedded Swift copy, and the round-trip tests.
- [ ] Documentation (`AGENTS.md`, `ARCHITECTURE.md`, `DESIGN.md`, `docs/`, the specs in `docs/design/`) matches the change.

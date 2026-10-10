# Projects draft PR evidence

These are unchanged PNGs rendered from the implementation submitted in the draft PR. They are not the reference boards and are not screenshots of a live provider session. The previews use scratch stores, the real project/runtime/presentation paths, and scripted workers. No production sessions or credentials are involved.

## Reproduce

```sh
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-project-pr-evidence SHEPHERD_PREVIEW_SCALE=2 \
  swift test --disable-automatic-resolution --disable-xctest \
  --filter 'LogicalProjectPreviewTests|ProjectSettingsFidelityPreviewTests|settingsProjectsExperiment'
```

The evidence run passed 25 tests in 3 suites and generated 202 images. This directory keeps 32 images covering 16 states in light and dark. The full run also covers empty/long text and text scale 1.3. `manifest.json` records the SHA-256 hash and pixel dimensions of each retained PNG. Copies here are byte-identical to that run.

## Images

| State | Dark | Light |
| --- | --- | --- |
| Started, with three project threads | [PNG](board-started-dark.png) | [PNG](board-started-light.png) |
| Running worker beside project conversation | [PNG](board-thread-running-dark.png) | [PNG](board-thread-running-light.png) |
| Paused project with retained question | [PNG](board-paused-dark.png) | [PNG](board-paused-light.png) |
| Question in the project conversation | [PNG](board-question-dark.png) | [PNG](board-question-light.png) |
| Resolved worker, with an open mismatch noted below | [PNG](board-resolved-dark.png) | [PNG](board-resolved-light.png) |
| New Project, empty | [PNG](lead-new-project-empty-dark.png) | [PNG](lead-new-project-empty-light.png) |
| New Project, filled | [PNG](lead-new-project-filled-dark.png) | [PNG](lead-new-project-filled-light.png) |
| Proposed Space approval | [PNG](lead-adds-space-dark.png) | [PNG](lead-adds-space-light.png) |
| Empty overview | [PNG](board-overview-bare-dark.png) | [PNG](board-overview-bare-light.png) |
| Narrow column, long names, text scale 1.3 | [PNG](board-long-chips-narrow-x1.3-dark.png) | [PNG](board-long-chips-narrow-x1.3-light.png) |
| General settings | [PNG](settings-general-normal-dark.png) | [PNG](settings-general-normal-light.png) |
| Linked Spaces | [PNG](settings-spaces-normal-dark.png) | [PNG](settings-spaces-normal-light.png) |
| Instructions and memory | [PNG](settings-memory-normal-dark.png) | [PNG](settings-memory-normal-light.png) |
| Automation records, not structured trigger execution | [PNG](settings-automations-normal-dark.png) | [PNG](settings-automations-normal-light.png) |
| Projects experiment off | [PNG](settings-experiments-projects-off-dark.png) | [PNG](settings-experiments-projects-off-light.png) |
| Projects experiment on | [PNG](settings-experiments-projects-on-dark.png) | [PNG](settings-experiments-projects-on-light.png) |

## Design and remaining gaps

The user's 14 reference boards are saved as `../../boards/ProjectLead-*.png`. The element-level comparison and control evidence are in [the checklist](../../boards/ProjectLead-checklist.md). Feature decisions and behavior are in [the project notes](../../../project-lead.md).

Approved changes from the references are macOS-only hosts, Designs first in Activity, no Project subagents, and Projects off by default under Experiments.

This is draft evidence, not a claim of a 1:1 match:

- The new resolved-state preview still draws a worker composer above the Reopen strip. The reference replaces the composer. This needs investigation and correction before acceptance.
- The narrow long-title preview shows a Working row beneath "Nothing is running." That producer/state mismatch also needs investigation.
- "Run on another host" is incomplete. A destination-Space decision is pending; starting a fresh remote task does not implement branch continuation.
- Automation records and switches exist, but the structured schedule/event triggers in the reference are not implemented. Watchers versus structured triggers remains a product decision.
- One linked Space row cannot yet represent the same logical repository on multiple hosts. Links currently identify a host and its Space separately.
- Measured typography differences remain in the live status line, New Project title, button edges and close glyph. See the checklist for measurements. No unapproved difference is treated as accepted.
- Scratch paths, relative times and model labels come from the fixture's real records and may differ from reference copy. The automation screenshots show existing records, not proof of schedule execution.

The Dev build and off-screen accessibility control checks passed. Interactive testing of a running Dev app and live-provider end-to-end execution are not claimed.

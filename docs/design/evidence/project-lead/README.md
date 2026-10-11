# Projects draft evidence

These 32 PNGs use fictional public fixtures. The sample project is Bookmarks, the user is Alex
Example, and the sample hosts and paths are invented. Original design boards are private and are
not part of this branch.

The screenshots are unchanged renderer output, not redacted copies of the earlier images.
`manifest.json` records the original generated filename and SHA-256 for each image. All 32 passed
OCR checks for known private labels and a visual privacy review.

## Reproduce

```sh
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-project-public-previews \
SHEPHERD_PREVIEW_FAST=1 \
swift test --disable-automatic-resolution --disable-xctest \
  --filter 'LogicalProjectBoardPreviewTests|LogicalProjectPreviewTests|ProjectsExperimentPreviewTests|ProjectSettingsFidelityPreviewTests'
```

The clean fixture run passed all 25 preview tests. These suites render light and dark appearance,
normal and 1.3 text scale, and populated, empty and long-text cases. The published selection below
contains 16 light/dark pairs. Coordinator conversations, worker threads, questions and published
files come through the scratch server and stub runtime. They do not contact a model provider or
use the user's projects.

## Screenshot index

| State | Light | Dark |
| --- | --- | --- |
| New project, empty | [Light](lead-new-project-empty-light.png) | [Dark](lead-new-project-empty-dark.png) |
| New project, filled | [Light](lead-new-project-filled-light.png) | [Dark](lead-new-project-filled-dark.png) |
| Started | [Light](board-started-light.png) | [Dark](board-started-dark.png) |
| Question | [Light](board-question-light.png) | [Dark](board-question-dark.png) |
| Paused | [Light](board-paused-light.png) | [Dark](board-paused-dark.png) |
| Thread running | [Light](board-thread-running-light.png) | [Dark](board-thread-running-dark.png) |
| Resolved | [Light](board-resolved-light.png) | [Dark](board-resolved-dark.png) |
| Bare overview | [Light](board-overview-bare-light.png) | [Dark](board-overview-bare-dark.png) |
| Add Space | [Light](lead-adds-space-light.png) | [Dark](lead-adds-space-dark.png) |
| Long text, narrow, 1.3 scale | [Light](board-long-chips-narrow-x1.3-light.png) | [Dark](board-long-chips-narrow-x1.3-dark.png) |
| General settings | [Light](settings-general-normal-light.png) | [Dark](settings-general-normal-dark.png) |
| Spaces settings | [Light](settings-spaces-normal-light.png) | [Dark](settings-spaces-normal-dark.png) |
| Memory settings | [Light](settings-memory-normal-light.png) | [Dark](settings-memory-normal-dark.png) |
| Automations settings | [Light](settings-automations-normal-light.png) | [Dark](settings-automations-normal-dark.png) |
| Experiments off | [Light](settings-experiments-projects-off-light.png) | [Dark](settings-experiments-projects-off-dark.png) |
| Experiments on | [Light](settings-experiments-projects-on-light.png) | [Dark](settings-experiments-projects-on-dark.png) |

## Review status

This is draft evidence, not a claim that the feature matches every source board or is ready to
merge. Fictional text changes wrapping, so these images cannot prove exact typography against
private source copy. See [the checklist](../../boards/ProjectLead-checklist.md) for the detailed
visual gaps.

The resolved render still shows a composer above Reopen, unlike the intended resolved layout.
The running render can show queued input depending on the stub's current delivery state. The
remaining host-move and automation-trigger workflows are not complete. No screenshot is offered
as evidence of those missing workflows.

Removing the earlier screenshots from the branch does not purge old GitHub commit URLs, pull
request references, cached images or other clones. GitHub Support may be needed for server-side
cleanup; this directory makes no claim that the earlier publication has been erased everywhere.

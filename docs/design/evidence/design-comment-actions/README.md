# Design comment actions

Reference: [DesignComments.png](../../boards/DesignComments.png), supplied with the request.

## Checklist

- Keep the Comments tab and its open-comment count, the blank empty state, and the oldest-first lazy card list. Tabs come from `DesignChatPane.tabs`; cards come from `DesignScreenModel.openCards`.
- Keep each card's numbered lantern pin, `on` plus board and element, author and age, detached `element changed` text, and comment body. `DesignScreenModel.card` produces these strings. The screenshot's comments are user data, not preview literals.
- Preserve `AppLayout.designChatWidth`, `designCommentsPadding`, and `designCommentsSpacing`. Preserve `NWDesignMetrics.commentCardPaddingVertical`, `commentCardPaddingHorizontal`, `commentCardSpacing`, `commentCardRadius`, `commentMetaSize`, `commentTextSize`, and `commentLineHeight`, with `bgRaised`, `lineStrong`, and the existing text roles.
- On hover, replace the trailing metadata visually with a checkmark resolve button. The requested action is not drawn in the reference. Use the same unfilled `checkmark` as the existing Resolve action, in a `NW.Height.controlS` icon button, with help `Resolve comment` and accessibility label `Resolve comment <number>`. Keep the original metadata's layout space so hovering does not resize the card.
- Also reveal Resolve on keyboard focus and with VoiceOver, and expose the named `Resolve` accessibility action at rest. The card is a native button labeled `Open comment <number>` with its target, metadata, and text as its accessibility value. Resolve is a sibling button, never nested in the open button.
- Pressing a card selects and reveals its board using the existing reference-reveal path, switches to that board's page if necessary, exits Present, and opens its comment thread. Clicking a canvas pin still opens in place without recentering.
- Pressing Resolve uses the existing revision-fenced host action. On success the card, count, pin, and any open thread disappear, while the chat keeps its historical card. On failure the card stays and the existing error report explains why.
- Apply the same list controls to local and remote Mac designs. No protocol changes and no new agent/model calls.
- Render rest, hover, opened board, resolved/empty, detached, and long-text states in light and dark at text scales 1 and 1.3. Use real server comments and the real card formatter. Exercise open and resolve through accessibility presses, including the hidden-at-rest named action; check 24pt hit areas.

## Validation

- 55 focused tests passed across DesignToolTests, DesignBoardActionsTests, DesignRulesTests,
  DesignCommentControlsTests, and RemoteDesignFlowTests.
- Both Comments-tab list performance tests passed. The lazy list still builds only visible cards.
- `DesignPreviewTests.designCommentActions` passed and generated 24 PNGs in this directory.
  Each state has light, dark, `x1.3-light`, and `x1.3-dark` captures.
- Controls used through ControlPress in offscreen exit tests: both Open buttons, both hover
  Resolve buttons, and both named Resolve accessibility actions at rest. The tests check host
  persistence, different-page and offscreen navigation, selection, thread placement, no accidental
  navigation on Resolve, removal of cards/pins/counts, historical cards, and the final empty list.
- All tested buttons pass the desktop 24pt hit-area check. The local and remote host paths pass.
- The agent-docs, design-section, and context-budget Python checks passed. `git diff --check` passed.
- Read-only code review found no consequential issues. Visual review checked all 24 captures
  against the saved reference and checklist, with no retained departures or clipping in the cards.
- The `Shepherd (Dev)` Xcode build passed with the resolved local packages and isolated build products.
  No interactive Dev app was launched. Validation uses real server-backed, offscreen SwiftUI
  windows so it does not interrupt the user's active Nightly.

SwiftPM on the local Xcode beta omitted Sparkle from its test products. Copying the pinned
framework from this worktree's build artifacts into its scratch test products fixed the loader.
No dependency pins or user files changed.

## Screenshots

| State | Dark | Light | Larger text |
| --- | --- | --- | --- |
| List at rest | [Dark](app-window-design-comment-list-dark.png) | [Light](app-window-design-comment-list-light.png) | [Dark](app-window-design-comment-list-x1.3-dark.png), [light](app-window-design-comment-list-x1.3-light.png) |
| Hover Resolve | [Dark](design-comment-hover-dark.png) | [Light](design-comment-hover-light.png) | [Dark](design-comment-hover-x1.3-dark.png), [light](design-comment-hover-x1.3-light.png) |
| Opened other-page board | [Dark](app-window-design-comment-opened-dark.png) | [Light](app-window-design-comment-opened-light.png) | [Dark](app-window-design-comment-opened-x1.3-dark.png), [light](app-window-design-comment-opened-x1.3-light.png) |
| Resolved | [Dark](app-window-design-comment-resolved-dark.png) | [Light](app-window-design-comment-resolved-light.png) | [Dark](app-window-design-comment-resolved-x1.3-dark.png), [light](app-window-design-comment-resolved-x1.3-light.png) |
| Long and detached | [Dark](design-comment-long-detached-dark.png) | [Light](design-comment-long-detached-light.png) | [Dark](design-comment-long-detached-x1.3-dark.png), [light](design-comment-long-detached-x1.3-light.png) |
| Empty | [Dark](app-window-design-comment-empty-dark.png) | [Light](app-window-design-comment-empty-light.png) | [Dark](app-window-design-comment-empty-x1.3-dark.png), [light](app-window-design-comment-empty-x1.3-light.png) |

## Departures

None. The new hover action follows the user's words; the unchanged rest state follows the saved screenshot.

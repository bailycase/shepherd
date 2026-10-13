# Subagents tab checklist (SubagentList)

Board: [SubagentList](SubagentList.png), saved as given (3200x1800). Spec: [subagents](../subagents.md) › The Subagents tab.

## User decisions

- **2026-10-13, the tab's dot:** "it should mean still working, green dot means done". Blue while any run is working, green once
  every run is done. The board draws the blue dot and says no more. Built as `NWSidePaneTab.status`, not as the news dot.

## Design requirements confirmed during review

- The detail line uses `caption`, the board's CSS token, rather than an approximate font measured from the picture.
- A row is one button that opens the existing inspector. No new menu or VoiceOver mutation actions are added.

## Decided by the agent, still the user's to confirm

1. A failed or stopped run makes the dot red (`failed`), when none is live, so it is never shown as success.
2. The tab is hidden until the thread has a run; ⌃3 and View › Subagents beep before that.
3. An open tab with no runs says "No subagents" (the board's CSS has an empty-state rule and draws none).
4. Both sections read oldest-spawned first, as the board's do.
5. Sizes with no token: the 52pt row and 30pt time column (the board's CSS), 11pt finished glyphs and Geist's natural 1.2 line
   height in whole points (measured from the picture).

# Goal safety review amendment

> Read when changing goal controls, evidence confirmation, model disclosure or limit editing.

PR #189's second user review amends the Goal card, MobileGoal and iPadGoal boards. The supplied
revision-301 board is saved as [goal-states-r301.png](references/goal-states-r301.png). The user's
review words take precedence over that image where the new controls or disclosures differ.

## Requested UI behavior

- A real check shows `Checked by <model>` in its record and card. Cross-provider evaluation is
  off unless Settings > Agents > Allow cross-provider goal checks is on. The policy row explains
  that conversation text, tool output and written code can reach the selected provider.
- A supported but incomplete Met candidate remains Needs you with the exact short reason
  `looks met, evidence incomplete, confirm`. Confirm replaces Resume, and its explanation makes
  user attestation distinct from verification. Mobile cards show why before the user confirms.
  An actual user question disables both Resume and Confirm.
- Edit can change or lift time/token limits without changing the condition. Keep the existing
  desktop inline editor and iOS sheet; their absence from the board remains a pending Departure.
  Keep the existing one-desktop/two-touch-line truncation pending the user's decision.
- Every action captures the displayed state/revision. Controller transitions invalidate older
  controls and editors. Identical text and limits remain a no-op. Met remains clear-only.
- Clock updates are local to the pills, not composer/queue/server snapshots. The shared dock
  observes cached goal presence/identity. Strict ListPerformance tests pin that isolation.
- Stop and Steer now pause/cancel Checking first. Met, Paused and Needs you do not suppress later
  ordinary turn-finished banners. Notifications contain short human metadata, never tool quotes.

## Retained anatomy and verification

Keep the two-ring glyph, AgentState text/mark/tint roles, 32/40pt headers, 10/12pt corners and
44pt iOS targets. Confirm reuses Resume's text-button style, with no new glyph. Checker/user
attribution and the mobile confirmation explanation grow the body instead of clipping it.
Attribution uses mono meta metrics and textSecondary for readability. Confirmed cards put the
attestation on its own line and show tokens without repeating it in header metadata.
Limit fields use shared caption/mono styles, bgSunken, lineSubtle and existing spacing/radius
values. No new dependency, color or animation is needed.

Offscreen accessibility presses exercise actual controls without taking focus or posting input
against the running app. Preview renders cover both appearances, confirmation, attribution,
limits, long text and shared docks. Mac AX results do not establish iOS sheet/context-menu
interaction or connected-iPhone notification delivery. PR #189 remains draft for those checks
and the retained Departures. [Conversation goals](../goals.md) defines runtime behavior;
[the card spec](thread.md#goal-card) defines the resulting UI.

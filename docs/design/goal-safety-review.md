# Goal safety review amendment

> Read when changing goal controls, evidence confirmation, model disclosure or experiment enablement.

PR #189's second user review amends the Goal card, MobileGoal and iPadGoal boards. The supplied
revision-301 board is saved as [GoalStates.png](boards/GoalStates.png). The user's
review words take precedence over that image where the new controls or disclosures differ.
The later user request removes all time/token caps and puts Goals under Experiments, default off.

## Requested UI behavior

- A real check shows `Checked by <model>` in its record and card. Cross-provider evaluation is
  off unless Settings > Agents > Allow cross-provider goal checks is on. The policy row explains
  that conversation text, tool output and written code can reach the selected provider.
- A supported but incomplete Met candidate remains Needs you with the exact short reason
  `looks met, evidence incomplete, confirm`. Confirm replaces Resume, and its explanation makes
  user attestation distinct from verification. Mobile cards show why before the user confirms.
  An actual user question disables both Resume and Confirm.
- Goals have no time/token budgets or limit fields. Edit changes the condition only. Keep the existing
  desktop inline editor and iOS sheet; their absence from the board remains a pending Departure.
  Keep the existing one-desktop/two-touch-line truncation pending the user's decision.
- Every action captures the displayed state/revision. Controller transitions invalidate older
  controls and editors. Identical text remains a no-op. Met remains clear-only.
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
Settings > Experiments adds Goals using the existing card, tile, title, description and switch
tokens and the shared two-ring mark. Mac's native SettingsSwitch is labeled Goals; iOS has a
native switch per capable host. Both default off. Off pauses/cancels live goal work without
aborting a tool or clearing its goal; on never resumes it automatically. No new dependency,
color or animation is needed.

Offscreen accessibility presses exercise actual controls without taking focus or posting input
against the running app. Preview renders cover both appearances, confirmation, attribution,
condition editing, experiment on/off, long text, empty goals and shared docks, including the 1.3 matrix and retained 1.5 stress
renders. Representative [light/dark review assets](reviews/goal-safety) are separate from the
saved board. The full local set is `/tmp/shepherd-goal-safety-merged-previews`. Mac AX results do not establish iOS sheet/context-menu
interaction or connected-iPhone notification delivery. PR #189 remains draft for those checks
and the retained Departures. [Conversation goals](../goals.md) defines runtime behavior;
[the card spec](thread.md#goal-card) defines the resulting UI.

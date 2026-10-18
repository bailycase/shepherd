# Diagnostics setting

The user approved crash and bounded performance reporting under the existing opt-in, behind a removable
Shepherd-owned wrapper. There is no second switch; saved consent stays unchanged.
All app-authored diagnostics copy and search terms are provider-neutral. Technical integration
names and user-configured MCP server names are unchanged.
No image was supplied. This checklist extends SettingsAdvanced using its existing components.

- Group order: Files, Updates, Diagnostics, Reset.
- Diagnostics uses `SettingsGroup`, `SettingsRow` and `SettingsSwitch`. No new glyphs, dimensions,
  colors, fonts or motion. The components retain their existing Night Watch tokens and 24pt control target.
- Switch label: "Share diagnostics". Default off. Its subtitle and accessibility hint come
  from `DiagnosticsSettings.disclosure`: "Send crash and hang stacks, errors, app and device details,
  process and memory counts, and operation timings to a third-party diagnostics service. No prompts,
  replies, tool output, file contents, command lines or session replay. Performance reports upload while
  Shepherd runs; crashes upload when you reopen it."
- Footnote starts with the current state:
  - Off: "Off. Turning on takes effect after you quit and reopen Shepherd."
  - Pending: "Not active yet. Quit and reopen Shepherd to start reporting."
  - Active: "Reporting is active."
  - Each configured state ends with "Turning off stops reporting and discards pending reports,
    but does not delete reports already sent."
- Pressing the switch persists consent. Enabling applies on relaunch; disabling applies immediately.
  No confirmation sheet: the switch and adjacent disclosure are the explicit opt-in.
- An unconfigured build shows "Diagnostics reporting is not configured in this build." as subtitle and
  accessibility hint, a disabled off switch, and no footnote. A saved on preference can still be
  switched off; its footnote says "Reporting is unavailable. Turn this off to revoke saved consent."
- Reset also turns diagnostics off. Its subtitle names diagnostics among reset preferences.
- Render configured off/pending/active and unconfigured states, light/dark and text scale 1.3.
  Fixed copy has no empty or user-generated long-text state; the disclosure is the wrapping stress case.
- Press the switch in both directions, check persistence and callback, verify the disabled state,
  accessibility disclosure and a 24pt hit area. No test may contact Sentry.

Rendered in light and dark across the state and text-size matrix (`DiagnosticsPreviewTests`).

Departures from the user's requirements: none.

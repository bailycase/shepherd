# Codemode settings

> Read when: changing global or project codemode settings and their controls.

User requirement: add a Codemode toggle, enabled by default, and a per-project on/off override. Use Pi's native codemode. Leave subagent workflows unchanged.

## Decisions

- Global changes apply at agent start or restart, not midway through a turn.
- The project control has three states so a project can return to the host default. It edits the existing settings draft and requires Save.
- Use Pi's native codemode factory with `models: false`, rather than the unrestricted built-in. Cap a script at five minutes and 128 tool calls. No script runs after host shutdown or resumes itself after restart.
- Direct tool calls, native tool search and subagent workflows stay available and unchanged. Child default tool allowlists are unchanged.
- A project must have Pi's trust approval before Pi applies its settings. A project file is not consent to execute untrusted code.

## Implementation checklist

- Settings > Agents > Context retains its existing rows in order, then adds `Codemode` with the existing `SettingsSwitch`, on for a fresh settings store.
- The row explains: `Lets the agent run JavaScript to batch tool calls and filter results, up to 128 calls and five minutes per script. Direct tool calls stay available. Scripts cannot call classifier or image models directly. Projects can override this default.` The section says changes apply when agents start or restart.
- Settings > Projects > Pi settings adds a `Codemode` row before the `.pi/settings.json` editor. Its existing `NWSegmentedPicker` offers `Use global default`, `On`, and `Off`. The accessible group name is `Project codemode`.
- The project row explains: `Overrides this host's global setting for this project. Save the file, then start or restart the agent.` The choice updates the JSON draft. Existing Save, dirty-navigation confirmation, conflict detection, and file validation remain responsible for writing it.
- Missing project settings inherit. Invalid JSON or incompatible codemode-related fields disable the picker and explain the problem without rewriting the draft. Offline and loading states remain read-only.
- Use `SettingsGroup`, `SettingsRow`, `SettingsSwitch`, `NWSegmentedPicker`, and existing Night Watch colors, fonts, spacing, corner radii, and hit-area tokens. Add no glyphs or literal view dimensions.
- Preserve unrelated JSON fields, extensions, and tool selections. Global changes take effect before the next agent launch, without restarting a running agent. Per-project values use Pi's native settings precedence, not a separate Shepherd execution engine.
- Render global on/off and project inherit/on/off, missing/invalid/long settings in light and dark at text scale 1 and 1.3. Drive the real settings/model/file producer.
- Press the global switch and every project segment through `ControlPress`, then Save. Read back persisted settings, verify inherited behavior, and test write conflicts.
- Verify native codemode activation, project precedence, direct tool availability, nested-call visibility, approval errors, cancellation, and native execution bounds with the pinned Pi and a local fake provider.

## Nested-call checklist

- Pi's `nestedCalls` metadata is decoded only on tool results; old messages without it still decode. Unknown or malformed optional entries must not discard a valid parent result.
- Each nested call uses the existing Activity lines and Calls design in `docs/design/thread.md`, following its script's row in invocation order. There is no new glyph or control. The existing call-row minimum becomes 24pt so its pointer hit target meets the accessibility rule.
- The existing tool formatter produces every label, argument summary, output, failure and stopped state. The script's own state remains independent from its calls.
- Live nested events and restored history use the same call IDs and arguments. Display-only details retain text output up to 8,192 characters per call and 32,768 per script, without adding it to model context. Child transcripts use the same projection rules. Existing row and snapshot limits apply.
- Older sessions show "Pi did not save this nested call's output." Missing arguments and clipped output say why. An incomplete native log says "Pi's nested call log is incomplete; some calls or arguments were not saved." A stopped call uses the existing stopped presentation.
- Expand each completed activity line and call through ControlPress, then inspect its real projected output and raw arguments. Failed calls remain visible even if the script handles the failure and succeeds.
- Render projected script results with successful, failed, empty, long and stopped calls in both appearances and at text scale 1.3. No copied screenshot strings.

## Validation

- 205 focused Swift protocol, projection, launch, settings, history, controls and preview tests pass. ControlPress exercises the global switch, every project segment and Save, with a 24pt minimum pointer hit area.
- 55 extension tests pass against the pinned Pi runtime, including activation and trust, nested results, approvals, Stop, direct-model denial, tool-call and time limits, and unchanged tool selections and child defaults.
- 421 release and documentation checks pass. The Dev scheme builds with the resolved package versions.
- Reviewed 52 rendered PNGs in `/tmp/shepherd-codemode-previews`, covering light/dark, scales 1 and 1.3, global on/off, project inherited/on/off, missing, invalid and long settings. The regular app was not launched because its delegate activates the app; validation stayed in off-screen windows. A broader Projects preview batch stalled in existing fixture setup and was interrupted. Targeted feature previews passed separately; that broader batch is not counted.
- The read-only risk review found a potential tool-selection expansion while editing `defaultTools`. The fix leaves `defaultTools` untouched. A later review found a hand-edited bare-built-in bypass of Off; the host now removes and blocks codemode when disabled. Real-Pi regressions cover both fixes. The follow-up review found no remaining actionable issue.
- The approved RPC decoder change reads native call metadata and bounded display-only excerpts. Tests cover independent call failures, live updates, reopening, partial logs, duplicate IDs, and child-transcript paging within one script. ControlPress opens and closes the script and nested rows, opens the full-output sheet and presses Done, and checks output and 24pt hit targets. Rendered complete, stopped, empty, long, and older native logs in both appearances at scales 1 and 1.3.

Departures: none from the user's written requirement. No reference image was supplied.

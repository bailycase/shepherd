# Cycle thinking level

User requirement: Shift-Tab cycles through thinking levels, and Settings > Keyboard can rebind it.

## Implementation checklist

- Add "Cycle thinking level" after "Choose model…" in Settings > Keyboard > Thread. The title comes from `ShortcutAction.cycleThinkingLevel.sentenceTitle`; the keycaps come from `KeybindingsStore.display`.
- Default keycaps are ⇧ and ⇥, using the existing `NWKeycap` styling. No new glyphs, colors, sizes, spacing or radii.
- Keep the existing shortcut recorder, "Press keys…", conflict feedback, individual Reset and Reset all shortcuts. Shift-Tab is accepted only for this action; other custom chords still need Command.
- Explain the exception with "Click a shortcut to record a new one. Shortcuts must include ⌘, except ⇧⇥ for cycling thinking levels."
- Cycle in the focused existing-thread, New thread and New design composers. Use the levels offered by their real store or draft, in menu order, wrapping to the first level. Count every press when SwiftUI combines input into one view update.
- Preserve the draft and focus. With no thinking control, only one level, a waiting question, an unavailable action or another focused field, leave the key to its normal handler.
- Do not intercept a focused terminal's keys or keys while the settings recorder is active.
- Validate default, rebound, reset, supported-level cycling, wraparound and unavailable states. Render default and rebound settings in both appearances at text scales 1 and 1.3. Press the recorder and Reset through accessibility.

## Validation

- Saved the [eight-render settings matrix](../evidence/thinking-shortcut/settings-row-matrix.png). The default and rebound row match the checklist in light and dark at text scales 1 and 1.3.
- Pressed the recorder in default and rebound states, cancelled recording, and pressed Reset through accessibility. The recorder, its recording state and Reset each have a desktop hit area of at least 24pt.
- Creation-composer tests use the accessibility-backed off-screen setup of the existing New thread picker tests and wait for the native field editor before checking the shortcut. Focused validation with `CI=true` and `--no-parallel` passes 43 unit tests and eight integration tests.
- Passed all 1,043 app unit tests, 38 focused integration tests and 14 documentation guards in the clean PR worktree based on current `nightly`. The shortcut integration tests cover supported-level cycling, wraparound, rapid presses sharing a render, rebinding, reset, focus and draft preservation, unavailable states, and cycling from the effective displayed level in both new composers.
- Staged the current pinned engine and built the Dev scheme with locked package versions and signing disabled for local validation. No running user app or preferences were touched.
- Reviewed the rendered settings row against this checklist and reviewed the scoped diff. The rapid-press regression failed before the counter-delta fix and passes with it.
- Three existing speed-menu pixel assertions failed during the initial validation with and without the new composer modifier; their expectations remain unchanged. The PR excludes the original checkout's unrelated thread changes.

## Departures

None.

# Tool call details

User requirement: clicking the codemode block expands to show its script. Expanded transcript blocks should expose more of the saved call details.

## Implementation checklist

- Keep the existing activity glyphs, labels, status, rail, dimensions and Night Watch tokens unchanged.
- In each expanded burst, put an input row before the existing call/output row. Codemode's input row is `script` with `JavaScript` as its detail; other tools use `input` with the tool name.
- Decode codemode's saved `code` argument as source text. Other inputs show the saved JSON arguments. Never reconstruct missing input; missing arguments or empty source add no input row.
- Opening a codemode burst shows the first 12 script lines immediately. Input rows toggle their preview independently of output rows.
- Long input uses the existing `… n more lines` control and full-text sheet. The sheet title is `<tool> script` or `<tool> arguments`, with the existing Copy and Done controls.
- Preserve output previews, output clipping notices, nested-call activity, edit review actions and Show Call.
- Cover completed, stopped, empty, long and older saved sessions in light, dark and enlarged text. Running rows retain the existing live presentation.
- Press the burst, input row, full-input link and Done through accessibility. Assert that source and output remain separate.

## Review

| Element | Requirement and implementation | Result |
| --- | --- | --- |
| Activity header and rail | Existing NWActivityLine and NWActivityCalls, unchanged glyphs, status and tokens | Matched |
| Script | Saved RPC assistant tool-call arguments flow through projectHistory into the decoded source preview | Matched |
| Inputs and output | Separate input and existing output rows, independently expandable | Matched |
| Long source | First 12 lines, existing full-text sheet and Copy/Done controls | Matched |
| Empty and older sessions | No invented source or empty input control | Matched |
| Appearance and scale | Complete, stopped, empty, long and older sessions in light/dark at 1.0 and 1.3 | Rendered |
| Controls | Accessibility presses cover script expansion/collapse, argument expansion, full source, full output and Done; existing sheet Copy is unchanged | Passed |

Evidence: `CodemodePreviewTests`, `CodemodeControlTests`, `ThreadFitTests`, and PNGs under `/tmp/shepherd-tool-details`. The Dev build is checked separately. A live Dev-app session and iOS are not verified by these Mac offscreen tests.

Departures: none.

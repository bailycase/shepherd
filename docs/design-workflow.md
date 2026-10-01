# Design workflow

> Read when you build a UI from a design the user gave, review one, or write the pull request for it.

[AGENTS.md](../AGENTS.md) has the procedure in a few lines; this is the detail behind each step. The
generic skills `implement-design`, `design-review` and `risk-review`, and the `design-reviewer` and
`risk-reviewer` helpers, cover the same ground for any repo when they are installed (Settings ▸
Skills ▸ Add from files; helpers in the pi home's `agents/`). They are optional: everything an
agent needs to do the work here is on this page and in the files it links.

The design the user gave in the thread is the requirement. It outranks DESIGN.md, the specs, older
code and your taste, and a difference from it is the user's decision, never yours.

## 1. Pin the design

- Save the image as `docs/design/boards/<Name>.png` before any code ([boards/README.md](design/boards/README.md)),
  and name it in the PR.
- Find the board with `python3 scripts/design_section.py --boards | grep -i <word>` and print its
  spec: `python3 scripts/design_section.py "<board or heading>"`. If the design disagrees with the
  spec, build the design and update the spec in the same change.
- A detail the image cannot settle (a glyph's fill, a size, a color) is a question. Pick one, say
  which, and list it under Departures if it may differ from what the user meant.

## 2. Write the checklist before the code

One line per item. It is the list you compare against later, so make it checkable.

- Every element, in order, and every glyph by SF Symbol name and fill variant (`bolt` is not
  `bolt.fill`). A glyph that more than one view draws is a case of `NWGlyph`.
- Every size, spacing, radius and color as a token: `NW.Space`, `NW.Radius`, `NW.Height`,
  `Color.nw.<role>`, a ramp style, a metrics constant. Status text, dots and fills come from
  `AgentState` (`textColor`, `color`, `tint`), never from a role with an alpha.
- **Every string the app will really show, per state, from the code that produces it.** The
  board's copy is a mock: the runtime publishes its own ("Checking recorded tool results." where the
  board says "running go test"), with raw ids, counts and times the board does not show. For each
  state write the string and where it comes from (a store's presentation type, an extension's
  output, a formatter), and compare it with the board. A difference is a departure or a bug.
- Every state the design draws and every one it does not: empty, loading, error, offline, long text
  (three times the longest), the state a stale client sees.
- What each control does, which states enable it, and every other place the feature shows up (the
  thread header, a sidebar row, a notification, the iPhone and iPad).

## 3. Build and look

- Reuse ShepherdUI components and tokens; hardcode no color, font size, dimension or duration.
  `DesignRulesTests` fails on a literal font size, a status color tinted with an alpha, a raw color
  and a registered glyph named as a string ([rules.md](rules.md), Design tokens only).
- Render from the real producer: the store, the extension's own output, the formatter, driven the
  way the app drives them, never strings copied from the board. A preview with the board's literals
  looks right and hides copy bugs.
- Render the matrix, in both appearances: each state, empty, long text, and text scale 1.5. Previews
  are in `Tests/ShepherdPreviewTests` (docs/testing.md › Previews); `Preview.renderMatrix` draws
  light and dark at each scale (the Mac's largest Text size is 1.3, 1.5 is the stress case). The
  PNGs land in `$SHEPHERD_PREVIEW_DIR`:

  ```sh
  SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter ThreadPreviewTests
  ```

- Open every PNG. Put the render beside the design, zoom into glyphs, spacing and alignment, list each
  difference, fix it, render again. Measure; do not eyeball.

## 4. Press every control

Every control the design draws, in every state it appears in, pressed with `ControlPress`
(docs/testing.md › Pressing a control): the test finds it by accessibility label and runs its press
action, as VoiceOver does, in a process of its own, and never posts a mouse or key event.

- Assert what the press did: the request it sent (with the revision it was shown, for a control that
  fences) and the state it left, and that a stale or repeated press is refused or harmless.
- Assert which controls each state offers (`window.controls()`), that a disabled one is disabled,
  and the hit areas: `ControlPress.undersized(_, minimum: .desktop)` (24pt) or `.touch` (44pt).
  A control whose background is clear and has no content shape fails that check.
- "The harness cannot press it" is not an answer until you have tried this. The worked example is
  `ModelSettingsPopoverTests`.

## 5. Review before the PR

Run the `design-reviewer` helper (skill `design-review`) when it is installed. Otherwise do the same
review yourself, against the design and not against your own previews:

1. Table every element, glyph, color role, size, string per state, and action per state against the
   build: element, design, build, verdict, file and line.
2. Re-render from the real data path and compare those strings, not the previews you wrote.
3. Check the design-system rules in the code, and that a new indicator replaces nothing that was there.
4. Press every control again; list works, broken and untested per state.
5. Check accessibility (labels on icon-only controls, focus order, Reduce Motion) and large text.

Fix what you find, or report it. Never report a difference as acceptable: the user decides.

## 6. The pull request

[.github/pull_request_template.md](../.github/pull_request_template.md) has the UI section. The
`pr-body` workflow (`scripts/check_pr_body.py`) fails a change under `Sources/ShepherdApp`,
`Packages/ShepherdUI` or `App/iOS` whose body leaves these empty:

- **Departures:** every difference you kept, each with a reason. `none` counts.
- **Rendered:** the states and themes, from the real data path, and where the images are.
- **Controls used:** how each control was pressed and what you asserted.

Also fill **Design** (the saved image) and **Not verified**. Your final message has the same shape:
what matched, departures, what you ran, what you could not check.

A feature that acts on its own (a loop, background work, an unattended model call) also fills
Bounds, Data, Restart and stop and Decisions, and follows [rules.md](rules.md), Features that act on
their own.

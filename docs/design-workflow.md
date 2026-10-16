# Design workflow

> Read when you build a UI from a design the user gave, or review a change against one.

The design the user gave in the thread is the requirement. It outranks DESIGN.md, the specs, older
code and your taste, and a difference from it is the user's decision, never yours.

## Pin the design

- Save the image as `docs/design/boards/<Name>.png` ([boards/README.md](design/boards/README.md))
  and name it in the PR.
- Find the board with `python3 scripts/design_section.py --boards | grep -i <word>` and print its
  spec: `python3 scripts/design_section.py "<board or heading>"`. If the design disagrees with the
  spec, build the design and fix the spec.
- A detail the image cannot settle (a glyph's fill, a size, a color) is a question. Pick one, say
  which, and list it under Departures if it may differ from what the user meant.

## Build

- Draw what the design draws: every element in its order, its copy, its glyph (`bolt` is not
  `bolt.fill`), and its size, spacing, radius and color as tokens (`NW.Space`, `NW.Radius`,
  `NW.Height`, `Color.nw.<role>`, a ramp style). Status text, dots and fills come from
  `AgentState`, never a role with an alpha. `DesignRulesTests` fails on the literals
  ([rules.md](rules.md), Design tokens only).
- The board's copy is a mock. The app shows what its code produces (a store's presentation type,
  an extension's output, a formatter), so check those strings against the board; a difference is
  a departure or a bug.
- A control the design draws does something. If the code can't do it yet, say so instead of
  shipping a dead control.

## Look

Render the surface from real data in both appearances and open the PNGs beside the design:

```sh
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter ThreadPreviewTests
```

Previews live in `Tests/ShepherdPreviewTests` (docs/testing.md › Helpers). Cover the states the
design draws plus empty and long text; `Preview.renderMatrix` draws light and dark at each text
scale. Fix every difference you can name, then run the `Shepherd (Dev)` scheme and use the change.
A control a test needs to press goes through `ControlPress` (docs/testing.md › Pressing a control).

## The pull request

Fill the UI section of [the template](../.github/pull_request_template.md): the design, every
departure you kept with its reason (`none` counts), and the previews. Your final message has the
same shape: what matched, departures, what you ran, what you could not check.

A feature that acts on its own (a loop, background work, an unattended model call) also follows
[rules.md](rules.md), Features that act on their own, and lists its product decisions in the PR.

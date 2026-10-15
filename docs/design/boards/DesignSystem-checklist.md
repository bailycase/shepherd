# Design system page checklist

Boards: [DesignSystemPage](DesignSystemPage.png) (dark overview), [DesignSystemLight](DesignSystemLight.png),
[DesignSystemMenu](DesignSystemMenu.png), [DesignSystemColors](DesignSystemColors.png),
[DesignSystemColorsLight](DesignSystemColorsLight.png), [DesignSystemType](DesignSystemType.png),
[DesignSystemSpacing](DesignSystemSpacing.png) (Spacing and Corner radius), [DesignSystemSizes](DesignSystemSizes.png),
[DesignSystemComponents](DesignSystemComponents.png). Saved as given (2880x1800).

User decisions (2026-10-13): read-only, no new write contract. Appearance toggle switches the page and keeps both
color columns. "New design" uses the existing flow. Counts come from the data.
User decision (2026-10-14): the layout applies to every system. Principles, Voice, the tagline, the summary, the
provenance note and the sizes are the system's own copy, in `tokens.json` › `page`; a part it has nothing for is left
out.

## Elements, top to bottom

1. Header (`NWDesignHeader`, page style): nib, "Design systems" (back to Designs), "/", the system's name.
   Trailing: Dark | Light (`NWSegmentedPicker`), New design (`.nw(.primary)`, the one amber control), and the
   existing More menu (kept, see Departures).
2. Contents button (`list.bullet`, bordered `nwIcon`, 16pt from the top left) opening the section menu: label
   "SHEPHERD UI" (the system's name, mono micro, uppercase), Overview, Principles n, Voice, Colors n, Typography n,
   Spacing n, Corner radius n, Size n, Components n, a hairline, "USED BY", then each design that uses the system
   with its board count. Width 224, padding 6, rows 28, radius l, `nwPopover`.
3. Column 960 wide, 24 between parts. Hero: 256 tall, `bgBase`, hairline `lineSubtle`, radius l, 32 padding;
   the name at 64 bold, the tagline (body, `textSecondary`) 8 under it; at the right six tiles in a 4x3 grid, 8 gap,
   2x2 `lantern`, 1x2 `running`, `done`, 1x2 `bgRaised` with `lineStrong`, `lanternTint`, `failed`.
4. Lead paragraph and the provenance note (caption, `textTertiary`).
5. Principles (title 15 semibold, bullets with a bold lead) and Voice (lead, Say/Avoid table, three bullets).
6. Cards (`bgRaised`, hairline, radius l), each with a head (24 semibold, caption sub in `textTertiary`):
   Colors (5 groups: Surfaces, Lines, Text, Brand and state, Syntax; columns Name | Dark | Light),
   Typography (Display, Text, Mono; Name | Preview with a tag "Geist · 28 / 600"), Spacing (Name | Value | Shape bar),
   Corner radius (Name | Value and use | Shape), Size (Name | Value | Used for), Components (Name | Preview,
   "All groups" popup in the head).
7. A value is a read-only chip: 28 tall, 8 padding, `lineStrong`, radius s, `bgSunken`, a 16pt swatch for a color,
   mono value, and for the three text tokens a trailing contrast ratio against `--bg-window` ("check 15.9:1" in
   `done`, "warning 3.3:1" in `lanternText` below 4.5).

## Glyphs

`list.bullet` (contents), `checkmark` and `exclamationmark.triangle` (contrast), the nib `pencil.tip` (header, in
the component), `chevron.up.chevron.down` (popup, in the component). No `square.and.pencil` or `plus`.

## Strings from code

The name, every token name and value, type sizes and weights, spacing and radii, size values (control, field and
segment from `NWSettingsControlMetrics`, row from `NW.Height.row`, rail from `AppLayout.settingsNavWidth`, thread and
prose from `AppLayout`), every count, the "Used by" designs, the component names and groups. The system's own copy
(`tokens.json` › `page`): the tagline, summary, provenance note, Principles, Voice and sizes; a radius's `use`. The
app's copy: the group hints.

## States

Drawn: dark, light (toggle), menu open, empty "Used by" (the label and a "No designs yet" line is not drawn: the
section is left out), components filtered to one group. Not drawn, built plainly: the tokens not yet read (the
header alone), text scale 1.3 (rows grow, names truncate in the middle).

## Controls (each pressed with `ControlPress`)

- Dark, Light: set the page appearance only (`DesignSystemPage` state, not persisted, not the app's theme).
- New design: `vm.openNewDesign()`.
- Contents button: opens and closes the menu. Each section row scrolls to its part and closes the menu. Each
  "Used by" row opens that design.
- All groups popup: filters the components; the count line keeps the total.
- Design systems (breadcrumb): the Designs page.

## Not drawn on purpose (approved departures)

Edit icon per token and the editable value fields, "+ Add" per card (read-only, no write contract), and the per
component "open" icon (no existing destination for a component).

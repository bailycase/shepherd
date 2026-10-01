# Typography, space, elevation and density

> Read when you set type, spacing, radius, row height, elevation, an icon, or the density settings.

## Typography

Geist for prose and chrome, Geist Mono for anything the agent touched (paths, commands, code,
output, counts, times), both bundled (NWFoundations). Sizes are points:

- **Mac:** sizes don't follow Dynamic Type. Every size, in the ramp or one-off, scales with
  Settings ▸ Appearance ▸ Text size (`ThemeStore.textScale`, 85–130% in 5% steps, "App chrome
  only.").
- **iOS:** the phone and iPad boards' larger ramp (the iOS column), with the Mac's weights and
  line heights except body's 1.5. Every style follows Dynamic Type: `Font.nw` builds
  `.custom(_:size:relativeTo:)` with the style's text style (display `.largeTitle`, title
  `.title3`, headline `.headline`, body `.body`, ui `.callout`, caption `.caption`, code
  `.callout`, mono `.caption`, micro `.caption2`).

`.nwText(_:)` applies a style with its line height (extra leading from the face's real metrics);
`.font(.nw(_:))` alone suits single lines.

| Style (`NWTextStyle`) | Mac spec | iOS | Board use (NWFoundations) | Also in the app |
| --- | --- | --- | --- | --- |
| `display` | Geist 28/600/1.15 | 28 | Empty states, onboarding | Nothing in the Mac app: the one onboarding step, Bringing over your pi, is a sheet titled at 17/600; empty-state titles follow the Status board at 17/600, and Settings page titles the Settings boards at 22/600 (`Font.nwSans`) |
| `title` | Geist 15/600/1.3 | 16 | Thread and pane titles | Dialog and sheet titles. The toolbar title and pane headers follow the Navigation board at 13/600 (`Font.nwSans(13, .semibold)`) |
| `headline` | Geist 13.5/600/1.35 | 17 | Card titles, section heads | Markdown headings |
| `body` | Geist 13.5/400/1.6 | 16/1.5 | Agent prose, bubbles | The composer field |
| `ui` | Geist 12.5/500/1.3 | 15 | Rows, buttons, controls | |
| `caption` | Geist 11.5/400/1.35 | 12 | Secondary info ("Asked 2m ago · still working") | Descriptions, footnotes |
| `code` | Geist Mono 12/400/1.55 | 13 | Code blocks, output | The review's file headers |
| `mono` | Geist Mono 11.5/400/1.3 | 12 | Paths, commands, tool rows | Diff lines |
| `micro` | Geist Mono 10.5/500/1.2 | 11 | Section labels, uppercase ("AGENTS · 19") | Counts, times. A section label is `.nwSectionLabel()`: uppercase, tracked 6% (0.06em), `textTertiary` |

- `Font.nw(_:weight:)` takes a weight for the rare emphasis the ramp lacks. `Font.nwSans(_:_:)`
  and `Font.nwMono(_:_:)` exist for the one-off sizes the boards specify (the toolbar title at
  13, row meta at 10–11, the palette field at 15). Prefer a ramp style.
- **Two prose sizes:** `NWProseSize` (the `nwProseSize` environment value) sets thread prose and
  bubbles at the ramp (`regular`) or one step smaller (`small`: body at the `ui` size). The
  subagent inspector's transcript uses `small`.
- The terminal font (family and size) is its own setting in Settings ▸ Terminal and never
  follows the chrome's text scale. The boards set the terminal in Geist Mono 12 at a 1.6 line
  height (Terminal); the app's default is SF Mono 12.5 today (Known gaps).

## Space, radius, height, elevation

- **Space** (`NW.Space`, 4pt grid): `xxs 2`, `xs 4`, `s 6`, `m 8`, `l 12`, `xl 16`, `xxl 24`,
  `xxxl 32`. Padding and gaps use only these steps.
- **Radius** (`NW.Radius`): `xs 4` pills, keycaps, chips · `s 6` buttons, fields, rows · `m 8`
  cards, the composer, tool groups, code blocks · `l 12` popovers, the palette, and sheets
  Shepherd draws itself (a native `.sheet` keeps the system's corners).
- **Height** (`NW.Height`): rows `rowCompact 22` (diff lines, dense lists), `row 28` (sidebar,
  tool rows, menus), `rowComfortable 36` (inbox items, ledgers), all scaled by Density and rounded
  to whole points (`NW.Height.scaled(_:)` for other row heights); controls `controlS 24` (inline
  buttons), `controlM 28` (default controls), `controlL 32` (primary actions), which never scale;
  `touch 44` on iOS. NWFoundations also names the composer's Send for `controlL`, but the
  Composer board and the Mac draw it at 28 (`NWComposerMetrics.actionSize`); iOS draws it at 32.
- **Hairlines** are 1px, not 1pt: `NWHairline`, `.nwBorder(_:radius:)`, and
  `.nwBorder(_:in:dash:)` (any shape, optionally dashed) use `NW.hairline(displayScale)`. Every
  border of a control, field, pill, keycap, banner, card, or bubble draws through them. Three
  kinds of line stay in points: the layout's dividers (the edges of the docked
  sidebar and side pane, 1pt, because the window's arithmetic counts them), the checkbox's
  1.5pt border (the Controls board draws it heavier than its 1px lines), and the strokes of
  status dots and glyphs.
- **Elevation** (NWFoundations):
  - `.nwCard()`: flat, for panes and cards: a raised fill and a 1px line (`lineSubtle` unless
    given), radius 8 unless given. Separation is a line, never a shadow.
  - `.nwPopover()`: menus, the palette, popovers, toasts: a raised fill, a 1px `lineStrong` line,
    radius 12, and the system's only shadow, `popoverShadow` 12pt down with a 16pt radius (the
    board's `0 12px 32px`). Tooltips are the system's (`.nwHelp`), not popovers (see
    departures).
  - `.nwFloatShadow(_:)`: the popover's shadow on the sidebar or side pane while it overlays
    the window, and nothing while docked.
  - `.nwFocusRing()`: running blue at `focusRing` (60% dark, 50% light), 2pt wide, 2pt outside
    the control (a 2pt gap, then the ring), for keyboard focus only, never on a click. It turns
    off the system's focus effect (`.focusEffectDisabled()`). Every Night Watch control style
    and custom control draws it; a control left in its system style keeps the system's ring.
    `.nwFocusRing(_ visible:)` is for a field or card whose focus the caller tracks, and
    `.nwFocusRingCircle()` for icon buttons.
- **Icons** (NWFoundations, NWSwift): SF Symbols only (`Image(systemName:)`),
  `.symbolRenderingMode(.monochrome)`, weight `.medium`, 13–16pt: 14pt in icon buttons
  (`.nwIcon`). Go below 13pt only where a surface's board draws a glyph inline in a row (a
  chevron, an activity glyph, a chip's ×). Status glyphs come from `AgentState`
  (`NWStateGlyph`); never emoji. Apart from status dots and the spinner's arc, the only drawn
  marks are the crook (`NWCrook`) and the queue's glyph and grip (`NWQueueGlyph`,
  `NWGripGlyph`). The board's symbols:

  | For | Symbol | For | Symbol |
  | --- | --- | --- | --- |
  | Sidebar | `sidebar.left` | Search | `magnifyingglass` |
  | Compose (iOS; the Mac has no compose button) | `square.and.pencil` | Read | `doc.text` |
  | Send | `arrow.up` | Edit | `pencil` |
  | Stop | `stop.fill` | Bash | `terminal` |
  | Attach | `paperclip` | Grep | `text.magnifyingglass` |
  | Thinking | `lightbulb` | Warning | `exclamationmark.triangle` |
  | Check | `checkmark` | Automation | `bolt` |
  | Close | `xmark` | Mission (**not built yet**) | `scope` |
  | Subagents | `arrow.triangle.branch` | Host | `desktopcomputer` |
  | Review | `plus.forwardslash.minus` | Retry | `arrow.clockwise` |
  | More | `ellipsis` | Copy | `doc.on.doc` |
  | Disclosure, closed | `chevron.right` | Settings | `gearshape` |
  | Disclosure, open | `chevron.down` | Fork | `arrow.branch` |
  | Comment | `text.bubble` | Play, Run now | `play.fill` |

  An activity line carries one glyph per kind of work, not per tool, because calls of one kind
  merge into one line: the NWThread board draws them (Thread › Activity lines).
- **Wordmark** (`NWWordmark`, NWFoundations › Mark): the crook, then "shepherd" in lowercase
  Geist 600 in `textPrimary`. The crook is `lantern` on any background: `NWCrook`, drawn on a
  24pt grid with a 2.4 stroke, round caps and joins. `.large`: a 30pt crook, 26pt text at −3%
  tracking, 10pt apart. `.small`: a 16pt crook, 14pt text at −2% tracking, 6pt apart. It reads
  "Shepherd" to VoiceOver, and the crook alone is hidden from it. No shipped surface shows the
  wordmark yet (the Component Gallery does); `NWCrook` tops an `NWEmptyState` (unless
  `showsMark` is false) and the iOS About row.
- **App icon** (`App/AppIcon.icon`): always dark, in both appearances, with no light or tinted
  variant: a lantern in a field, the crook in `lantern` (a 2.2 stroke, its 24pt box at 40/72 of
  the tile) under a radial lantern glow (35%, clear by 70%) toward the upper right, on
  `#0d0e10`. **Shepherd Nightly** (`App/AppIconNightly.icon`) trades the lantern glow for a
  crescent in moonlight: a `textPrimary` crescent in the upper right and a `textPrimary` glow
  (22%, clear by 70%) toward the upper left, on the same black, so the two apps tell apart in
  the Dock and ⌘Tab.

## Density and row settings

Settings ▸ Appearance ▸ Layout has two independent row controls (SettingsAppearance). The
NWFoundations heights are their 100% values:

- **Sidebar rows** (`AppSettings.sidebarRowDensity`, an `NWDensity`): a segmented Compact ·
  Standard · Comfortable, captioned "Compact 22 · Standard 28 · Comfortable 36 pt, for the
  sidebar and menus.", default Standard. `RootView` sets it on the environment
  (`.nwDensity(_:)`). The sidebar's rows and the command palette's rows and placement read it,
  and use it as a minimum height, so larger text still fits. Compact rows set titles at 12pt
  instead of 12.5 (`NWDensity.rowTitleFont`).
- **Density** (`AppSettings.uiDensity`): a slider from 80 to 150% in 5% steps, default 100%,
  captioned "Row heights across the sidebar and chrome. Lower fits more agents." It multiplies
  every row height (`NW.Height.row…`, so the sidebar and palette rows above too), the Settings
  rows and nav, and the diff's lines and fold rows, rounded to whole points.
  Control heights never scale.

Text size, beside them, scales type only (Typography).

A sidebar row is therefore its density's base height × Density. `NavigationTokenTests` and
`TokenTests` (ShepherdUI) pin the heights, and `SidebarRowSettingTests` the setting.

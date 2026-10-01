# Theme model

> Read when you add or change a color, a theme, an AgentState look, or build on ShepherdUI's tokens.

All design values live in **ShepherdUI**. It is SwiftUI only and holds no app state. Views
read colors from `Color.nw`, fonts from `Font.nw(_:)`, and sizes from `NW.Space`, `NW.Radius`,
and `NW.Height`, plus the app's own surface dimensions in `AppLayout`. **Never hardcode a color,
font size, or dimension in a view.**

The token boards are **NWFoundations** (every color, type style, space, radius, height,
elevation, motion, icon, and the mark, with its Swift name) and **NWSwift** (how they map onto
SwiftUI, the component inventory, the package), each drawn dark and light (NWFoundationsLight,
NWSwiftLight). A pair carries the same tokens and text; only the rendered appearance differs.
The light boards call the light variant "Day Watch"; the app has one theme, Night Watch, with
`night-watch-dark` and `night-watch-light` variants.

The canvas's older `tokens.json` is Option A, superseded by Night Watch (its Foundations and
Components boards are gone from the canvas). Take no value, name, or component from them: IBM
Plex Sans and JetBrains Mono, the 2px spacing base, 7pt and 10pt radii, 32pt sidebar rows with a 22pt indent,
a 7px status dot, the composer's and the segmented thumb's shadows, a 3px composer focus ring,
`ShepherdButton`, `AgentStatusPill`, `InlineError`'s "open Terminal mode", and the
`bg.canvas`/`accent`/`warning` role names are all gone.

A theme is pure data (`ThemeDefinition`: hex strings, `Codable`), so the built-in theme and
future user themes go through the same model:

```text
ThemeDefinition { id, name, light: ThemeVariant, dark: ThemeVariant }
ThemeVariant    { colors:   ThemeColors     // the Night Watch roles below (#RRGGBB or #RRGGBBAA)
                  syntax:   SyntaxColors    // code blocks and diffs
                  terminal: TerminalColors  // Ghostty: background, foreground, cursor,
                                            // selection, 16-color ANSI
                }
```

- **`ThemeStore.shared`** (`@Observable`) holds the selected theme, the text scale, and the
  density. It resolves each theme once into an immutable `NWPalette` (every `Color` built when
  the theme changes) and each text scale into an `NWTypeRamp`, so a token read is a
  stored-property load.
- **Colors are dynamic:** every palette color resolves against the appearance of the view
  drawing it, so light and dark are never stored and never need a re-render.
- **Views never branch on `colorScheme` for a color** (NWSwift): light and dark come from the
  token layer. Read `colorScheme` only to force the appearance (`preferredColorScheme`) and to
  hand resolved colors to what SwiftUI doesn't draw: the Core Animation spinner and glow layers,
  the iOS terminal's UIKit view, and, through `ThemeManager`, Ghostty and the external editor variant marker.
- **`ThemeManager`** (app) owns only the appearance mode: System (the default; "System follows
  your Mac and switches with it."), Light, or Dark, set in Settings ▸ Appearance ▸ Mode or the
  Appearance menu. The board's rule: follow the system, and let Settings force either (NWSwift).
  `SHEPHERD_THEME=night-watch-dark` or `night-watch-light` forces one at launch (the older
  `shepherd-dark` still means dark), and Reset returns to it.
- **What `ThemeManager` pushes:** the resolved variant goes to what cannot follow appearance on
  its own. That is Ghostty surfaces (a live `setTheme`, never a remount or replay) and the
  `shepherd-active-theme` variant marker (`night-watch-dark|light`), which external editors such
  as Neovim watch. The marker's spelling is an external contract. pi keeps its own theme.
- **Fonts:** Geist and Geist Mono (SIL OFL, `Resources/Fonts/OFL.txt`) ship in the package
  bundle: Geist Regular, Medium, SemiBold, and Bold, each with its italic, and Geist Mono
  Regular, Medium, SemiBold, and Bold. They are registered for the process at launch on the Mac
  and iOS (`NWFonts.register()`), with no Info.plist entry (see departures). PostScript names
  are `Geist-<Weight>` and `GeistMono-<Weight>`. Terminals keep their own font setting.

## Roles (`ThemeColors`, read as `Color.nw.<role>`)

Values are the NWFoundations board's, as `NightWatch.swift` holds them, dark · light. The board
writes translucent roles as rgba; the theme stores them as `#RRGGBBAA`, rounded to the nearest
alpha byte: `bgHover` white at 4.5% · black at 4%, `bgSelected` white at 8% · black at 6.5%,
`lanternTint` `#f2a93b` at 13% · `#d98a12` at 13%, and each other tint its own state color at
`runningTint` 13% · 10%, `doneTint` 12% · 10%, `failedTint` 12% · 9%. The Use column is the
board's, plus where the app also uses the role.

| Group | Role | Dark | Light | Use |
| --- | --- | --- | --- | --- |
| Surfaces | `bgBase` | `#0a0b0c` | `#f2f2f0` | Sidebar, window chrome, Settings nav, the review's file strip |
| | `bgWindow` | `#0d0e10` | `#fbfbfa` | Thread, toolbar, panes, terminals, dialogs |
| | `bgRaised` | `#15171a` | `#ffffff` | Cards, the composer, menus, fields |
| | `bgSunken` | `#111316` | `#f5f5f3` | Code, tool output, card headers, the segmented track |
| | `bgBubble` | `#1a1d21` | `#efefec` | User messages |
| | `bgHover` | `#ffffff0b` | `#0000000a` | Row hover |
| | `bgSelected` | `#ffffff14` | `#00000011` | Selected row, the composer's focus ring |
| Lines | `lineSubtle` | `#1f2226` | `#e7e7e3` | Dividers, row separators, card borders |
| | `lineStrong` | `#2c3035` | `#d6d6d1` | Control borders, popovers, the composer |
| Text | `textPrimary` | `#e8e9ec` | `#151618` | Body, titles |
| | `textSecondary` | `#9aa0a9` | `#5f636b` | Labels, previews, descriptions |
| | `textTertiary` | `#5f656e` | `#9a9ea5` | Meta, timestamps, counts, section labels |
| | `textOnLantern` | `#17120a` | `#1a1206` | Text on a lantern fill |
| Brand and state | `lantern` | `#f2a93b` | `#e39a26` | Brand, the primary action, needs you |
| | `lanternText` | `#f7c16e` | `#945b00` | Lantern words on a tint ("ASK", "Needs you") |
| | `lanternTint` | `#f2a93b21` | `#d98a1221` | Needs-you backgrounds |
| | `running` | `#7aa7ff` | `#2f6fe0` | Running, links, focus |
| | `runningTint` | `#7aa7ff21` | `#2f6fe01a` | Running pills, menu and palette highlight |
| | `done` | `#46c37b` | `#1f9d5b` | Success, additions |
| | `doneTint` | `#46c37b1f` | `#1f9d5b1a` | Done pills, added lines |
| | `failed` | `#f0625e` | `#d9443f` | Failure, deletions, destructive |
| | `failedTint` | `#f0625e1f` | `#d9443f17` | Failed pills, removed lines, turn errors |
| Syntax (`SyntaxColors`) | `synKeyword` | `#d7a6ff` | `#8a3fb5` | Keywords |
| | `synType` | `#7ee0b5` | `#1a7f55` | Types |
| | `synString` | `#e8c07a` | `#9a6400` | Strings |
| | `synNumber` | `#9ec2ff` | `#2f6fe0` | Numbers |
| | `synFunction` | `#8fc1ff` | `#2a62c9` | Calls |
| | `synComment` | `#5f656e` | `#9a9ea5` | Comments |
| | `synVariable`, `synOperator`, `synPunctuation` | `#e8e9ec`, `#9aa0a9`, `#9aa0a9` | `#151618`, `#5f636b`, `#5f636b` | Names and punctuation: the text colors. Not on the board, which colors only the six roles above |

**Derived colors** live on `NWPalette`, not in the theme:

- `focusRing`: running at 60% (dark) / 50% (light)
- `focusDivider`: running at 34% in both appearances, for a divider beside a focused pane (no view
  draws it now that terminals are tabs)
- `popoverShadow`: `.nwPopover()`'s shadow color: black at 55% (dark), `#141414` at 12% (light)
- `scrim`: black at 30% in both appearances, behind the command palette
- `textOnFailed`: white, for labels on a `failed` fill
- `knobOn`, `knobOff`, `knobShadow`: the switch and slider knobs
- `lanternHover`, `lanternPressed`, `failedPressed`: the filled buttons' hover and pressed fills,
  the Controls board's hexes (`NWButtonFills`): primary lifts to `#f7b84f` · `#eca63a` and sinks
  to `#d9922a` · `#cf8a1c`; dangerFill stays put on hover and sinks to `#d24f4b` · `#bf3a35`
  (dark · light). The labels on them reach 4.5:1, except white on the dark pressed dangerFill
  (4.23), as the board draws it

**The terminal palette is derived from the roles.** Terminals sit on `bgWindow` with
`textPrimary` text, a `textPrimary` block cursor, and a selection on `running` at 13%
(TerminalSplit, TerminalPane; the app draws a lantern cursor and a running selection at 18% dark,
28% light, see Known gaps); each variant carries its own 16-color ANSI palette (the light one
darkened to stay readable). Translucent selection colors are flattened onto `bgWindow`, because
Ghostty wants opaque colors.

## One status enum

`AgentState` (`running`, `attention`, `done`, `failed`, `stuck`, `queued`, `idle`) gives every
status surface its color, tint, word, and glyph: pills, dots, glyphs, step strips, banners, and
toasts each take a state (NWSwift: "All driven by AgentState"), and the spinner and the bar draw
in `running` unless given a color. The app maps its lifecycles onto it in
`AgentStateMapping.swift` (agent status, subagent runs, tool calls). Only `attention` animates:
a 1.6s glow, the dot's opacity easing 1 → 0.35 → 1, static under Reduce Motion. Draw state with
`NWStatusDot` (6pt), `NWStateGlyph`, or `NWStatusPill`, never with a view's own
`repeatForever`: the glow and the spinner run on the render server (see Motion and departures).

| `AgentState` | Word | Color | Pill fill | Glyph (`NWStateGlyph`) | App meaning |
| --- | --- | --- | --- | --- | --- |
| `running` | Running | `running` | `runningTint` | spinner | agent working, a live run or call |
| `attention` | Needs you | `lantern` (words `lanternText`) | `lanternTint` | `exclamationmark.circle` | agent blocked on a question, a run asking |
| `done` | Done | `done` | `doneTint` | `checkmark` | a finished agent, run, or call |
| `failed` | Failed | `failed` | `failedTint` | `xmark` | a failed run or call, a lost connection |
| `stuck` | Stuck | `failed` | `failedTint` | `exclamationmark.triangle` | (unused by the app today; a mission's stuck station and lane, not built: see Missions) |
| `queued` | Queued | `textTertiary` (words `textSecondary`) | none, outlined; hollow dot | `circle` | a queued or paused run |
| `idle` | Idle | `textTertiary` (words `textSecondary`) | none, outlined | `circle.fill` | an idle agent |

## Contrast rules

`ShepherdUIUnitTests` checks every built-in variant (translucent fills are painted over the
surface they sit on):

- `textPrimary`, `textSecondary`, and `textTertiary` reach 4.5:1 on `bgBase`, `bgWindow`, and
  `bgRaised`, and `textPrimary` on `bgSelected`.
- `lanternText` on `lanternTint`, each state color on its own tint (over `bgWindow` and over
  `bgRaised`), and `textOnLantern` on `lantern` reach 4.5:1.
- `lantern`, `running`, `done`, and `failed` reach 3:1 on `bgWindow` as dots and glyphs, and stay
  distinguishable from each other.
- **Documented exceptions** (the board's colors, kept; the test pins their measured ratios):
  `textTertiary` meta text (dark 3.06–3.35, light 2.40–2.69), the light state pills' words on
  their own tints (running 3.98, done 3.01, failed 3.71 over the window), the light lantern as a
  mark (2.27), white on `failed` (dark 3.18, light 4.33), and white on the dark pressed
  dangerFill (`failedPressed`, 4.23). `textOnLantern` on the primary button's hover and pressed
  fills reaches 4.5:1.
- Every role parses, only hover, selection, and the state tints may be translucent, surfaces
  and lines stay distinct, the ANSI palette has 16 entries, the terminal background equals
  `bgWindow`, and the theme round-trips through JSON.

## Adding a theme or a role

- **A theme:** write a `ThemeDefinition` that fills every field of `ThemeColors`,
  `SyntaxColors`, and `TerminalColors` for both variants (the memberwise
  initializers make the compiler enforce completeness). Add it to the list the ShepherdUI unit
  tests iterate and fix values until they pass. Then teach `ThemeManager` and the app's
  `ShepherdTheme` to resolve it for Ghostty and the editor variant marker; today they resolve Night Watch
  only. Keep the variant marker's `<theme>-dark|light` spelling.
- **A role:** add a field to `ThemeColors`, a value in every theme's light and dark variant, a
  property on `NWPalette`, and a contrast rule if it carries text.

## Building on ShepherdUI

The NWSwift board is the implementation plan. ShepherdUI is its `ShepherdDesign` package
(renamed; see departures), shared by the Mac app and the iOS client:

```text
Packages/ShepherdUI/Sources/ShepherdUI/
  Tokens/       Colors (NWPalette, Color.nw), Typography (NWTextStyle, Font.nw, NWFonts),
                Metrics (NW.Space, NW.Radius, NW.Height), Motion, Elevation, AgentState,
                ThemeDefinition, NightWatch, ThemeStore, HexColor, Platform
  Resources/    Fonts/: Geist-*.otf, GeistMono-*.otf, OFL.txt (no asset catalog)
  Components/   Controls, Status, Containers, Navigation, Thread, Composer, Agents, Review,
                Dialogs, Automations, Fleet, Terminal
  Previews/     a file per domain (and its touch variants); every component in both appearances
  Diagnostics/  NWRenderProbe (debug builds only)
```

- **Tokens in Swift:** `Color.nw.<role>` (one per Foundations color), `Font.nw(.<style>)` over
  the bundled faces, `NW.Space`, `NW.Radius`, `NW.Height` (including `touch 44`), `NW.Motion`,
  and hairlines at `1 / displayScale`. No view branches on `colorScheme` for a color (Theme
  model).
- **Controls are styles on native controls:** `.buttonStyle(.nw(_:size:))` and `.nwIcon`,
  `.toggleStyle(.nwSwitch)` and `.nwCheckbox`, `.textFieldStyle(.nw)` and `.nwSearch`,
  `.progressViewStyle(.nwSpinner)` and `.nwBar`; plus `NWKeycap`, `NWCountBadge`, `NWTag`. The
  board's `PickerStyle` `.nwSegmented` and `.nwPopup` are views, `NWSegmentedPicker` and
  `NWPopupMenu`, because SwiftUI has no public custom `PickerStyle`; they present themselves to
  accessibility as the native segmented `Picker` and a native `Menu`.
- **Status:** `NWStatusPill`, `NWStatusDot`, `.nwSpinner`, `.nwBar`, `NWStepStrip`,
  `NWSparkline`, `NWBanner`, `.nwToast(item:)`, `NWEmptyState`, `.nwShimmer()`, and live text's
  `.nwShimmer(active:)`. Whatever shows a
  state takes an `AgentState` (see One status enum).
- **Thread:** prose is Markdown; inline markup goes through `AttributedString(markdown:)`
  (inline only, whitespace kept), with blocks split by the thread's own renderer. Consecutive
  calls of one kind merge into one activity line.
- **Composer and menus:** the composer's menus are overlays that float over the thread, left-aligned
  above the composer card and growing from it (`.nwTransition(.overlay, anchor: .bottomLeading)`);
  context menus are native `.contextMenu`.
- **Review:** diff lines sit in a `LazyVStack` as `NW.Height.rowCompact` rows (22pt at 100%
  Density), for fast scrolling.
- **Layout:** the Mac window lays itself out (minimum 720×600): the sidebar and the side pane
  dock when they fit and overlay below (Window and adaptive layout). The iPad client uses
  `NavigationSplitView` with `.inspector`.
- **Light and dark:** both follow the system, and Settings ▸ Appearance can force either. Every
  component has a preview in both appearances (`NWPreviewBoth` draws them side by side), and the
  preview tests render every surface in both.
- **Icons:** SF Symbols only, `.symbolRenderingMode(.monochrome)`, weight `.medium` (see Icons).
- **Keyboard:** every action is reachable from the keyboard: on the Mac as a menu-bar item, with
  a `.keyboardShortcut` whose chord comes from `KeybindingsStore` where the action has one.
  Custom controls draw their own focus ring after `.focusEffectDisabled()` (`.nwFocusRing()`).
- **iOS and iPadOS:** the same package. Controls grow their hit area to 44pt (`NW.Height.touch`,
  `.nwTouchTarget(height:)`), and fonts follow Dynamic Type through `relativeTo:`.
- **Nothing else:** no permission or approval components, and nothing under the composer but its
  controls.

**Not built yet** (NWSwift's inventory for the future boards; each surface's own section or
board holds its spec, and its parts go in a `Components/<Domain>/` folder of their own):

- Agents: `NWMissionNode`, `NWInboxItem`, and `NWClaimRow` (NWAgents, NWSwift; specified under
  Mission components). Experimental surfaces reuse the same parts. The iPhone and iPad Needs you
  lists (MobileInbox, iPadInbox) are built from `NWAttentionCard` instead, with no state-colored
  leading rule; `NWInboxItem` itself is not built.
- Missions map (`Components/MissionMap/`): `NWMissionMap`, `NWStation`, `NWTerminus` (MXVocab),
  `NWFlowWire`, `NWDataWire`, `NWForkBar`, `NWJoinBar`, `NWLane`, `NWFog`, `NWFrontierChip`,
  `NWOutcomeChip`, `NWPinRow`. A `Canvas` draws the wires and the stations are views on top. Layout
  is automatic: rows from time order, columns from lanes.
- Mission screens (`Components/Missions/`): `NWMissionHeader`, `NWPhaseBar`, `NWBudgetMeter`,
  `NWHostChip`, `NWChoiceCard`, the mission question card (NWSwift's `NWQuestionCard`, which needs
  its own name: the phone's agent question already has it), `NWPlannerNote`, `NWAttemptRow`,
  `NWCheckpointRow`, `NWSpendBar`, `NWTrainCard`, `NWTrainGateRow`, `NWTrainRuleRow`,
  `NWRepoTimeline`, `NWPathLockRow`, `NWContractRow`, `NWDiffAnnotation`, `NWTraceSpan`,
  `NWMergeActions` (NWMissions), `NWRollbackRow`, `NWTemplateInput`. A mission asks through
  `NWChoiceCard` lists with one planner's pick; none of it is a permission prompt.
- Design tool (`Components/DesignTool/`): `NWDesignCanvas`, `NWBoardFrame`, `NWSelectionRing`,
  `NWCommentPin`, `NWCommentCard`, `NWCommentThread`, `NWBoardActions`, `NWCanvasToolbar`,
  `NWTweakRow`, `NWTokenChip`, `NWDesignSystemChip`, `NWTokenSwatch`, `NWExportFormatCard`,
  `NWLiveLinkField`. Boards render in a `WKWebView` per frame; everything around them is native.
- iPhone extras: `NWMissionLiveActivity`, `NWMissionNotification`, `NWLaneStrip`. ActivityKit
  shows progress, and answers are `UNNotificationAction`s, so replying never opens the app.

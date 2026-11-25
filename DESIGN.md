# Shepherd design: the rules

Every UI change on the Mac, iPhone and iPad follows these rules. The design boards are PNGs in
`docs/design/boards/`, named after the board ([how to save one](docs/design/boards/README.md)).
The code is the spec for everything a board doesn't draw.

## Precedence

The first of these that speaks wins:

1. **The design the user gives you in this thread**: an image, a board, a design reference, or
   words describing the change.
2. The design canvas's board, saved in `docs/design/boards/`.
3. The rules in this file.

- These rules never override a design the user just gave. If they disagree, build the design.
- A departure from a design is the user's call, never yours. Name each one in your final
  message and the PR with the reason.
- Every value lives in code. Tokens and shared components are in `Packages/ShepherdUI`. The
  Mac's own surface dimensions are in `Sources/ShepherdApp/AppLayout+<Domain>.swift`.

## What the app is for

Shepherd supervises agents. It is not a chat app: each thread is a live `pi` process you watch.
Every decision has to pass one test: does this help one person supervise ten working agents?

- An agent has a short task title it gave itself (`Fix plan mode`), a workplace, and a
  lifecycle: working, needs you, done, failed, idle. It renders only as a native thread.
- Terminals are tabs under a thread, one terminal per tab. No splits, no global shells. Browser
  pages are tabs in the thread's Browser pane.
- A Space is the folder a thread runs in. A Project is the feature above Spaces and owns the
  word; copy never calls a folder a project.
- Copy says "the agent", never "pi". The exception is where the user's own pi is the subject
  (Settings ▸ Models ▸ Your pi).
- Experiments (Projects, Goals) are off by default and turning one off never discards its data;
  turning it back on never resumes work by itself.

## Principles, in priority order

1. **Readable measure.** The thread column is at most 820pt wide and agent prose 640pt.
   The image viewer floats over the thread, its actions in a pill
   under the picture. Paging arrows sit beside the fitted image, not at the window edges.
2. **Shape, not labels.** No speaker labels or avatars. A user turn is a trailing bubble; agent
   output is unboxed prose.
3. **One line per stretch of work.** The tool calls between two pieces of prose are one activity line
   (`docs/design/boards/ToolActivity.png`): live, it says what the running call is doing; finished,
   it is a recap built from the calls' own arguments and results. Every tool has its own words,
   never "Used <tool>". The turn keeps the order it ran in: thinking you can read, and the pictures
   a call returned, stand where they happened and end the line before them. Pictures stack in one
   column, one per row.
4. **One thing moves at a time.** The live line's spinner and shimmer are the only motion in the thread.
5. **Nothing in the default view that isn't useful.** No key-hint rows (the question dock's
   footer is the one exception: its 1–N and ↩ hints, QuestionDockRadio), no repeated status text,
   no footers in menus, nothing under the composer but its controls.

What follows from them:

- **Flat surfaces, 1px lines.** Surfaces step `bgBase` (chrome), `bgWindow` (thread),
  `bgRaised` (cards, composer, menus), `bgSunken` (code, headers). A hairline separates them,
  never a shadow.
- **One shadow**, `.shPopover()`, for menus, palette, popovers and toasts. The sidebar and side
  pane borrow it (`.shFloatShadow`) only while they float. No vibrancy, translucency or gradients.
- **Honest affordances.** Never draw a control that does nothing, a shortcut that isn't wired,
  or sample data in place of real data. Hide what is unsupported, or say why.
- **Keep the reader's position.** Growth and completion follow the tail only while the reader
  follows it. A live reply shrinking does not move a detached reader to the tail.
- **No permission model.** Agent tool calls open no approval UI, including cross-thread calls and
  deletion. Questions retain the answers the asker offered. There is no agent-to-agent permission
  row in Settings, and legacy permission choices have no effect.
- **Status is a dot or glyph plus a word.** `AgentState` colors every status surface. Color is
  never the only signal.
- **Lantern means you.** Amber marks the primary action and what needs you. Running blue marks
  work in progress, links and keyboard focus.
- **The sidebar is the primary navigation.** The command palette is a second way to jump. In the
  Spaces layout, pinned spaces appear once in Pinned, below Projects and above Spaces, regardless
  of their stored parent. Unpin restores their ordinary nesting.
- **One primary action per surface.** A destructive action is never the ⏎ default.
- **Native controls, Shepherd Design styles.** A control is a Shepherd Design style on a native
  `Button`, `Toggle`, `Picker` or `TextField`. Context menus are native `.contextMenu`. Shared
  views are `SH`-prefixed.

## Matching a design

- Draw what the design draws: every element in its order, with its copy, its glyph, its size,
  spacing, radius and color as tokens.
- Draw every state it shows (rest, hover, pressed, focused, disabled, selected, loading, error,
  empty) in both appearances.
- Don't add an element the design lacks, and don't drop one it has.
- Every control it draws does something. If the code can't do it yet, say so instead of
  shipping a dead control.
- A value with no token uses the nearest one, and you list the difference. A new color is a
  theme role.
- Copy is the design's: sentence case in drawn UI, Title Case in native menus.
- Render from the real data path. A preview built from the board's strings looks right and
  hides copy bugs.

## Settings

The Settings board set (`docs/design/boards/Settings*.png`, `MobileSettings*.png`,
`iPadSettingsInstructions.png`; pages "macOS - Settings" and "Components - Settings", revision 3069)
is the source of truth for every Settings page, on the Mac and on iPhone and iPad.

- **Navigation** is a 220pt list on `bgBase` with no icons, in groups: General, Appearance,
  Keyboard · Agents: Models, Agents, Instructions, Skills, Tools, Hooks · Work: Spaces, Git, Apps,
  Fleet · Advanced, Experiments. Keyboard is on the Mac only; the iPhone and iPad list
  has the rest, with Apps read-only (runs and output; add and edit stay on the Mac). Esc leaves a
  sub-page for its parent, else leaves Settings.
- **Pages** are one centered 620pt column: a 15/600 title, then groups. A group has a
  sentence-case caption label (optional links at its right), a card on `bgRaised` (radius `l`,
  1px `lineSubtle`) and an optional footnote. Rows are 44pt with a one-line hint.
- A sub-page (a profile, a skill, a server, a space, an editor) shows "‹ Parent" above its title.
- Every row is wired: a row exists only if changing it changes the app, and a change applies at
  once with no Save, except editors, which keep an explicit Save.
- On the Mac every multi-line text input has Open in ▾ at its top right: it opens the draft in an
  app for its type (`ExternalDraft`), and saves there come back into the draft. iOS has none.

## Shepherd Design

Never hardcode a color, font size, dimension, duration or curve in a view. Use a shared
ShepherdUI component before hand-rolling chrome. A reusable part goes in `Packages/ShepherdUI`
with a `#Preview` in both appearances.

**Color** is `Color.sh.<role>`, dynamic per appearance (values in `ShepherdDesign.swift`):

| Group | Roles and use |
| --- | --- |
| Surfaces | `bgBase` sidebar and chrome · `bgWindow` thread, toolbar, panes, dialogs · `bgRaised` cards, composer, menus, fields · `bgSunken` code, tool output, card headers · `bgBubble` user messages · `bgHover`, `bgSelected` |
| Lines | `lineSubtle` dividers and card borders · `lineStrong` control borders, popovers, composer |
| Text | `textPrimary` · `textSecondary` labels and previews · `textTertiary` meta, times, counts · `textOnLantern` |
| Brand and state | `lantern` (+`lanternText`, `lanternTint`) primary action, needs you · `running` (+Tint) work, links, focus · `done` (+Tint) · `failed` (+Tint) destructive |
| Syntax | `syn*` for code blocks and diffs |

- Views never branch on `colorScheme` for a color. A new color is a role on `ThemeColors`,
  filled in both variants, with a `SHPalette` property and a contrast rule if it carries text.
- Borders and hovers are theme roles, never ad-hoc alphas. Status colors come from
  `AgentState`: `textColor` for the word, `color` for dots and glyphs, `tint` for the fill.
  Never apply `.opacity(…)` to a role. Draw state with `SHStatusDot`, `SHStateGlyph` or
  `SHStatusPill`.

**Type** is Geist for prose and chrome, and Geist Mono for anything the agent touched. Use only
`Font.sh(_:)` or `.shText(_:)`, which follow Settings ▸ Appearance ▸ Text size on the Mac and
Dynamic Type on iOS. Use `Font.shSans`/`shMono` only for a size a board gives outside the ramp.

| Style | Mac | Use |
| --- | --- | --- |
| `display` · `title` · `headline` | 28/600 · 15/600 · 13.5/600 | onboarding · dialog titles · card titles, headings |
| `body` · `ui` · `caption` | 13.5/400 · 12.5/500 · 11.5/400 | prose, bubbles, composer · rows, buttons · secondary info |
| `code` · `mono` · `micro` | Mono 12 · 11.5 · 10.5/500 | code, output · paths, commands · section labels, counts |

**Space** (`SH.Space`, 4pt grid): 2, 4, 6, 8, 12, 16, 24, 32. **Radius** (`SH.Radius`): 4 pills
and keycaps · 6 buttons, fields, rows · 8 cards, composer, code · 12 popovers, palette, sheets.
**Height** (`SH.Height`): rows 22 · 28 · 36 (scaled by Density), controls 24 · 28 · 32 (never
scaled), touch 44. Hairlines are 1px (`SHHairline`, `.shBorder`).

**Elevation**: `.shCard()` is flat (raised fill, 1px `lineSubtle`, radius 8). `.shPopover()` is
the only shadow. **Focus**: `.shFocusRing()`, a 2pt `running` ring for keyboard focus only.

**Icons**: SF Symbols, monochrome, weight `.medium`, 13 to 16pt, never emoji. Use the exact
symbol and fill variant the design shows (`bolt` is not `bolt.fill`). Where a board draws its
own outline (Settings' nav), it ships as a vector in `SHGlyph.Settings`. A glyph more than one
view draws is an `SHGlyph` case. `DesignRulesTests` fails on a literal font size, a tinted
status color, a raw color, a raw glyph name, or a symbol renamed where an animation can reach it.

**Motion** uses `SH.Motion` anchors, never a literal duration or curve:

- `hover`, `content` 120ms · `disclosure`, `list`, `pane`, `overlay` 180ms · `sheet`,
  `emphasis`, `scroll` 240ms, all springs; `glow` 1.6s (attention only), `spin` 1s, `shimmer`
  1.8s (live text only), `pulse` 1.4s.
- A store-driven change uses `.shAnimation(_:value:)` and `.shTransition`. An action-driven
  change uses `withSHAnimation`. Never use an ad-hoc `withAnimation`.
- Switching agents, keyboard navigation, selection, streaming text and terminal resizes land at
  once (`.shInstant()`); the one exception is the composer's focus ring in the layout a switch
  brings on screen, which fades in over the `hover` 120ms (an ease-out, never a spring) and lands at
  once under Reduce Motion. Under Reduce Motion nothing travels: cross-fade in 120ms or stand still.
- Spinners and glows are Core Animation layers, never a view redrawn every frame; so is the
  composer's focus line and ring, since a SwiftUI animation lays the visible layout out again on
  every frame it lasts.
- A glyph that swaps for another (Send and Stop, copy and its check) is two fixed images
  cross-faded by opacity, or one image keyed on its state; a disclosure chevron is one
  `SHTurningChevron` that turns. Renaming one symbol under any animation (a content transition,
  an ancestor's `shAnimation`, a `withSHAnimation`) draws it through RenderBox, which loads about
  258 MB of drawing pool for 1.2 to 1.6 s on every change. `DesignRulesTests` fails a name that
  follows state; a menu item, or a symbol fixed for its row, is allowlisted with why.

**Density**: Settings ▸ Appearance sets sidebar row height (22 · 28 · 36) and a Density of 80 to
150 that scales row heights, never controls. Text size scales type only.

## Interaction and keyboard

- In Spaces, dragging an inactive thread onto a space moves its conversation and working directory
  there. The thread menu offers Move to Space as the keyboard-accessible alternative.
- The keyboard is first-class, and the fast path never needs a dialog. The workplace menu's ↑↓
  navigation includes its visible Base row, and Return opens the branch picker. Every action is a
  menu-bar item. A chord lives in `KeybindingsStore` and nowhere else. A hint is never shown
  for a chord that isn't wired.
- A rebound chord must include ⌘ and avoid ⌘1–9, ⌘, and the plain system chords. A chord the
  app chrome uses goes in `appOwnedChords`, so a focused Ghostty surface can't eat it.
- Keycaps (`SHKeycap`) put modifiers in Apple's order, ⌃⌥⇧⌘, one cap per key.
- The Mac's image-capable composers handle native Paste (⌘V, Edit and the text menu) in their
  own field editor, reusing dropped-image resizing and attachment chips. Text paste, selection,
  undo and input-method composition stay native; other fields and terminals are unchanged.
- Opening Choose Model gives Search models the keyboard after the previous menu releases it;
  a simultaneous pane-focus claim never takes that keyboard back.
- In a sheet, ⏎ confirms and ⎋ cancels. Esc closes a menu, then the command list, then stops pi
  while it works. It never stops pi while a question waits.
- Status events are banners inside the pane they concern, never a modal alert.

## Accessibility

- Every control is a real `Button`, `Toggle` or field, or carries button traits and an action.
  Icon-only buttons have an `accessibilityLabel`. A hover-only affordance is also reachable as
  a button or a named action. Rows read as one element ("title, running").
- Color always comes with a word or a glyph shape. Text roles keep
  their contrast in both appearances.
- A value the design draws without its unit still reads with it ("100 percent").
- Mac type scales with Text size. iOS follows Dynamic Type and keeps 44pt touch targets.

## Performance

A list is as fast with three hundred rows as with thirty. Budgets in `ListPerformanceTests` pin
each rule. Add a budget with any new long list.

- Anything that can outgrow a screen is a lazy stack with stable ids.
- A lazy `ForEach` makes exactly one view per element. Wrap an `if` or `switch` in a container.
- Rows are plain `Equatable` values. Closures stay out of `==`, highlight and selection arrive as
  a `Bool`, and hover lives in the row. Stores derive rows once per change, never in `body`.
- Hidden agents stay out of the visible one's updates (switching is a visibility flip).
- Paging older thread rows completes pending native layout before measuring its viewport anchor.
- A cached visible bottom marker never overrides a following thread's measured gap from its tail.
  Cached current-row IDs require a live, nonhidden native row probe intersecting the Mac viewport;
  physical placement is not proof of compositor paint.
- Motion no one sees costs nothing (`shMotionPaused`).

## Verifying visuals

Render affected surfaces and states with
`SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews scripts/check.py ShepherdPreviewTests '<preview suite or test>'`.
Use real data and inspect the light and dark PNGs beside the design; unrelated previews need not run.
Appearance-only changes do not also require launching the app. For interactions, focus, menus or
app lifecycle, use integration tests; add a manual Dev-app check only where the isolated harness
cannot establish the behavior. Tests use `ControlPress`, never posted input or the installed app.

# Platform: iPhone Duo

> Read when you lay out anything that can run on iPhone Duo (every iOS surface does): its two displays, poses, vertical bars, the fold and arrangement views.

iPhone Duo (`iPhone19,4`, simulator device type `V68`) is a foldable iPhone. Closed, it's a short,
wide phone. Open, it's a small, nearly square tablet. Half open, its fold splits the inner display
in two. Everything in [platform-iphone.md](platform-iphone.md) holds on the outer display and
everything in [platform-ipad.md](platform-ipad.md) on the inner one. This file covers what the Duo
changes. A proposal mock that applies it to Shepherd is in `docs/design/mockups/iphone-duo/`
(not built).

## Geometry (Xcode 27.1 simulator profile)

| | Outer display (closed) | Inner display (open) |
| --- | --- | --- |
| Points (@3x) | 466 × 678 portrait | 951 × 669 landscape; 669 × 951 portrait |
| Pixels | 1398 × 2034 | 2853 × 2007 |
| Corner radius | 8pt on the hinge (leading) side, 59pt on the trailing side | 55pt, all four |
| Camera | Always visible, top trailing corner; it becomes the Dynamic Island for Live Activities | Behind the display at the top of the trailing half, hidden until the camera is active, then the UI moves aside |
| Size class | compact width → `PhoneShell` | regular width → `PadShell` |

- The outer display is wider and shorter than any other iPhone. Don't draw it at 390×844.
- The fold runs through the middle of the inner display, at x ≈ 475 in landscape and y ≈ 475 in
  portrait, and is about 27pt wide. It's a reserved region **only while the phone is half open**.
  Fully open, nothing is reserved. Each half is about 462 × 669, close to the outer display's size.

## Poses

The HIG shows six: closed in portrait, tent (standing on its edges, folded outward), open flat in
landscape, book (half open, the fold vertical), open in portrait, and laptop/tabletop (half open,
the fold horizontal, lower half flat). **Don't design a separate layout for each pose.** Use the
compact layout on the outer display and the regular one on the inner display, let it grow with
the space, and move only what has to clear the fold. Folding should never rearrange the screen
(HIG Device poses, Reserved regions).

## Vertical bars (the core Duo pattern)

On the outer display, and on the inner display in landscape, the system moves the navigation bar,
toolbar and tab bar into a **column on the trailing edge**. From top to bottom it holds the
Dynamic Island (outer only), the status bar (time over Wi-Fi), the toolbar (Back or Close first,
then prominent actions such as Done or Compose), a gap, then the tab bar. The inner display in
portrait keeps ordinary horizontal bars. The column stays on the trailing side in right-to-left
languages. On the outer display it's roughly 76pt wide and leaves Shepherd a column of about
390pt (measured from a screenshot, not documented).

- **Use system bars and placements, never custom bars.** SwiftUI does this for `.toolbar` on a
  `NavigationStack` or `NavigationSplitView` and for `TabView`. A row of buttons you draw yourself
  stays horizontal and fights the column.
- **Order:** Back/Close at the top (`.cancellationAction`; `.topBarPinnedTrailing` for a pinned
  Done), then the prominent action, then the rest in their groups (`ToolbarItemGroup`). Never add
  spacing by hand.
- **Every item needs an SF Symbol.** In the column the system shows only the icon. An item with a
  title and no icon, or a custom view, stays in a horizontal bar. Give it a title too, for overflow
  and VoiceOver (`Label("Cancel", systemImage: "xmark")`). Keep text buttons to a minimum.
- **Overflow runs bottom to top.** Set `.visibilityPriority` so frequent actions (New thread) and
  items that show status (badges) stay visible longest. Put the rest in `ToolbarOverflowMenu`, and
  never in an ellipsis menu of your own.
- **When space runs short:** a navigation screen keeps the tab bar and overflows toolbar items. A
  task screen (a composer, a sheet with a form) keeps its toolbar and shrinks the tab bar to one
  control (`toolbarVerticalCompressionBehavior`).
- **Sheets on the outer display get vertical bars by default** (`toolbarVerticalBehavior` turns this
  off). On the inner display, a centred or leading sheet gets horizontal bars and a trailing sheet
  vertical ones (`presentationPlacement`).
- **Split views:** the sidebar or content pane keeps horizontal bars at its top. The detail pane's
  bars go in the trailing column. Controls that act on one pane stay with that pane, as Mail's list
  filter stays above the list.
- **Inspectors keep horizontal bars.**
- `toolbarVerticalEdge` (environment) tells a custom view whether bars are vertical and on which
  edge. `backgroundExtensionEffect()` extends a hero image under the column.
- A layout with no bars (a full-bleed visual) may use the whole width, as long as it stays clear of
  the island and the status bar.
- In Split View multitasking on the inner display, each app puts its column on its outer edge, so
  the leading app's column is on the leading side.

## The fold and reserved regions

- **System containers handle the fold.** Alerts, menus and sheets move clear of it. A
  `NavigationSplitView` becomes two equal halves split at the fold, as Notes does when half open,
  and fully open has a narrower sidebar. Don't give a column a fixed width while the phone is half
  open: `PadShell` drops `columnWidth` when `verticalFold` is set.
- **Custom views read `GeometryProxy.reservedRegions(kind: .division)`.** Shepherd wraps this as
  `GeometryProxy.verticalFold` (`App/iOS/Support/Fold.swift`). It's nil when the phone is closed,
  fully open, or held sideways. `onHingeClosedChange` reports only whether the phone is shut, not
  every degree of the hinge. Review (`PadReviewScreen`) and Designs (`PadDesignScreen`) end one
  pane at the fold and start the next after it.
- **Grids use an even number of columns,** so the content divides cleanly at the fold.
- **Nothing important sits under the fold or the camera** unless the system moves it.

## Arrangement views

`ArrangementView { primary } secondary: { secondary }` (SwiftUI; `UIArrangementViewController` in
UIKit) lays out two views around the fold:

- `.split`: side by side when the space is wider than tall, stacked when taller, and adjusted to the
  fold. Use it in place of an `HStack` or `VStack` of two panes. `.split.axes(.horizontal)` limits
  it to one axis.
- `.overlay`: the primary view floats over the secondary one when the phone is closed or fully
  open. When half open, the primary goes to the trailing or bottom part and the secondary to the
  leading or top part. Use it in place of a `ZStack`. Example: a composer (primary) over a transcript
  (secondary) gives you reading above the fold and typing below it in the laptop pose, with no
  code for the pose.
- **Never put an ArrangementView inside a `NavigationSplitView`, list or scroll view.** Navigation
  goes around it, not inside it. In Shepherd that means the view must take the whole window, as
  Review does (`MobileNavigator.padTakesWindow`).

## Continuity

- Keep functions and state the same across displays. Unfolding may show one more level of
  hierarchy. Mail shows the list or a message when closed, and both when open.
- Closing and opening keeps the open thread, its scroll position and the unsent draft. `PadShell`
  rebuilds its columns when the style changes, so a draft must live in the model or the navigator,
  never in a view's `@State`.
- Multiple windows exist only on the inner display held upright (`WindowAvailability`; CONTRACTS ›
  Windows). Closed or held sideways, a new window replaces the one showing.

## Shepherd today (measured on the outer display, 2026-10)

- `PhoneShell` has five tabs (Home, Designs, Projects, Automations, Settings); the system draws
  them as the column's lower capsule. Home's New thread (prominent, highest visibility priority)
  and Search sit at the top of the column, and Home is only the inbox.
- The New thread sheet's Cancel (`xmark`) and Send (`arrow.up`) are toolbar items in the column;
  the worktree switch and Attach follow them, and go to the column's overflow menu while the
  keyboard is up. The prompt fills down to one row of chips.

## Checking it

The Duo simulator needs `DEVELOPER_DIR` set to Xcode 27.1. Pose it with `run-simulator.sh -f
closed|book|open` ([docs/ios/VALIDATION.md](../ios/VALIDATION.md)). Check each surface closed,
open, and in book, and rotate each. Never switch displays with `simctl io … screenConfig power`;
it crashes SpringBoard.

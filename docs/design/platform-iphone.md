# Platform: iPhone

> Read when you lay out an iPhone surface and need the iOS platform rules: compact width, one hand, tab bars, sheets and the keyboard.

The phone is for checking in and steering, often one-handed and in short bursts. Shepherd's phone
surfaces are in [ios-iphone.md](ios-iphone.md) and [ios-iphone-pages.md](ios-iphone-pages.md).
This file is the platform rules they follow. An iPhone Duo folded shut is also a compact-width
iPhone, but its bars move to the side: read [platform-iphone-duo.md](platform-iphone-duo.md) too.

## The device (HIG Designing for iOS)

- A medium-size display, held in one or two hands, about a foot away, in portrait or landscape.
- Input is Multi-Touch, the on-screen keyboard and Siri. Sessions are often a minute or two, and
  people switch apps often.
- Size classes: compact width in portrait; compact width and compact height in landscape on most
  models. The Pro Max and Plus models are regular width in landscape. Shepherd's boards draw a
  390×844 screen, but no layout may assume that size.

## Rules Shepherd follows

- **Limit what's on screen.** Show the main task and its content. Put secondary details and actions
  behind one tap or swipe (menus, swipe actions, a detail screen).
- **Put frequent actions where a thumb reaches them.** That means the middle and bottom of the
  screen: swipe to go back, swipe actions on rows, and the composer at the bottom.
- **Tab bar = navigation only.** Shepherd has two tabs, Home and Settings, each with its own
  `NavigationStack` (`PhoneShell`). Actions on the current screen go in its toolbar, never in a
  tab. Keep the tab bar visible except under a modal, and don't hide or disable a tab (HIG Tab
  bars). The tab bar floats over content on Liquid Glass and may include a search tab at its
  trailing end.
- **Toolbars use system placements.** Cancel uses `.cancellationAction` and the main action
  `.confirmationAction`. Give each item an SF Symbol and a title, so the same toolbar works on the
  Duo's vertical bars. Don't build a custom nav row inside a sheet.
- **Sheets for short tasks** (New thread, a picker). A sheet's controls go in its toolbar, not in
  the content. The keyboard takes roughly the bottom 40% of the screen, so the content of a
  sheet that holds a text field must fit above it.
- **Touch targets are at least 44×44pt** (`SH.Height.touch`). Nothing relies on hover: details
  show at rest (`SHPlatform.showsHoverDetails`).
- **Adapt to Dynamic Type, Dark Mode and rotation.** Side-by-side items stack at large text sizes,
  and rows grow taller rather than cut text off (HIG Layout).
- **Ask before using device data** (notifications, location) and only when it helps the task.
- **A split view needs regular width.** Don't try to fit two panes into compact width. Push the
  detail instead (HIG Split views).

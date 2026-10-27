# Platform: iPad

> Read when you lay out an iPad surface and need the iPadOS platform rules: regular width, split views, resizable windows, multiple windows, keyboard and pointer.

The iPad is for supervising and reviewing on a large touch screen, often with a keyboard attached.
Shepherd's iPad surfaces are in [ios-ipad.md](ios-ipad.md) and
[ios-ipad-pages.md](ios-ipad-pages.md). This file is the platform rules they follow. The iPhone
Duo's inner display also runs `PadShell`: read [platform-iphone-duo.md](platform-iphone-duo.md)
for what it changes.

## The device (HIG Designing for iPadOS)

- A large display that people hold, prop on a stand or put on a desk, within about 3 feet.
- Input mixes Multi-Touch, the on-screen or a hardware keyboard, a trackpad or mouse, and Apple
  Pencil, often several at once.
- Apps run full screen or windowed. Windowed apps resize freely, like on a Mac, and the app is never
  told which configuration it's in (HIG Multitasking). Shepherd's boards draw an 11-inch iPad at
  1180×820 landscape and 820×1180 portrait. Every width in between, and compact widths, must
  work.

## Rules Shepherd follows

- **Use the space for content, not chrome or modals.** Fewer full-screen transitions. Put the list
  beside the detail (`NavigationSplitView` in `PadShell`), and use sheets only for short tasks.
- **Design the split view at narrow, middle and wide widths** (HIG Split views). Shepherd decides
  from the window's shape, not the device's orientation (`PadSplitLayout.sidebarOverlays`). In a
  window taller than wide, the sidebar slides over the thread (340pt). In a wider one, it sits
  beside the thread (300pt). In compact width, the phone shell takes over. Keep the selected row
  highlighted.
- **A list with a detail screen** (Settings, Automations, Hosts) uses `PadListDetail`. When the
  detail would be narrower than `MobileLayout.splitDetailMinWidth` (280pt), show the list alone and
  push the detail.
- **Windowed mode puts window controls at the leading edge of the toolbar.** Don't put leading
  toolbar buttons where those controls would cover them; move them inward (HIG Windows).
- **Support multiple windows.** Offer "Open in new window" from a context menu or the File menu.
  Don't open a new window unprompted (HIG Windows). Shepherd's rules for this are in
  `WindowAvailability` and [docs/ios/CONTRACTS.md](../ios/CONTRACTS.md) › Windows (iPad).
- **Hardware keyboard and pointer.** Every main action has a chord (`.keyboardShortcut`): ⌘↩ sends
  from the composer and ⌘K opens search. The system lists the chords when ⌘ is held. Rows and buttons give hover and pointer feedback. Drag and drop
  works between panes and between apps.
- **Tab bar or sidebar.** On iPad a `TabView` sits near the top and can become a sidebar. Shepherd
  uses a `NavigationSplitView` sidebar instead, because its destinations and threads don't fit in
  tabs (HIG Sidebars). Show no more than two levels of hierarchy in the sidebar.
- **Touch targets stay 44pt** even with a pointer. Details show at rest, because a finger can't
  hover.
- **Density follows viewing distance.** The iPad keeps the phone's type ramp and gets a wider
  readable measure (`MobileLayout.threadMaxWidth`, 780pt), not smaller text.

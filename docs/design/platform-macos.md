# Platform: Mac

> Read when you lay out a Mac surface and need the macOS platform rules: windows, toolbars, the menu bar, keyboard and pointer.

The Mac is where people supervise many agents for hours, with the keyboard and the pointer. Window
geometry and the Mac's own surfaces are in [window-and-toolbar.md](window-and-toolbar.md) and
[sidebar.md](sidebar.md). This file is the platform rules they follow.

## The device (HIG Designing for macOS)

- A large, high-resolution display, often more than one. People sit 1 to 3 feet away, so Mac density
  can be higher than on touch platforms (the compact row heights in [foundations.md](foundations.md)).
- Input is keyboard plus pointer, both precise. Sessions run from minutes to hours, with several
  apps open at once.

## Rules Shepherd follows

- **Show more at once instead of nesting.** Use the large display for side-by-side content (the
  sidebar, the thread and the side pane), not for more push levels or modals.
- **The window is resizable and keeps working small.** Its minimum is 720×600 and its default
  1440×900 (`AppLayout+Navigation.swift`, `.windowResizability(.contentMinSize)`). Every layout
  adapts down to the minimum; how it adapts is in window-and-toolbar.md › Window and adaptive
  layout. Support full screen.
- **Don't put critical controls at the bottom edge of a window.** People drag windows partly off
  the bottom of the screen (HIG Layout › macOS). The composer is the deliberate exception, because
  it sits with the thread it writes to.
- **Keep content out from behind the camera housing** at the top of the screen in full screen.
- **Every command is in the menu bar** and has a keyboard shortcut. Chords resolve through
  `KeybindingsStore`, and every chord the chrome uses is in `appOwnedChords`
  ([keyboard-and-accessibility.md](keyboard-and-accessibility.md)).
- **Use hover, but never as the only way to reach something.** The Mac shows details on hover. iOS
  shows the same details at rest (`SHPlatform.showsHoverDetails`), so a design must work both ways.
- **Toolbars use symbols without borders,** and the system adds the overflow menu when items don't
  fit. Don't add an overflow menu by hand, and don't design a toolbar that overflows by default
  (HIG Toolbars).
- **Split view panes** have sensible minimum and maximum widths, keep a visible 1pt divider, can be
  hidden, and can be brought back by a button, a menu command and a shortcut (HIG Split views).
  Shepherd's side pane: 600pt, minimum 380, at most half the window.
- **Window states.** The key window is the active one; inactive windows lose vibrancy and colour in
  the window controls. Don't draw custom window frames or window controls (HIG Windows).
- **Persistent selection.** The selected sidebar row stays highlighted while its thread shows (HIG
  Split views).

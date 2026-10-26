# Platforms

> Read when you design or lay out a screen for a platform: Mac, iPhone, iPad or iPhone Duo. Start here, then open that platform's file.

Shepherd runs on four kinds of screen. Each platform file below sums up Apple's Human Interface
Guidelines (HIG) for it, the device geometry, and how Shepherd's code maps onto both. They hold the
platform rules. A surface's own spec (`ios-iphone.md`, `ios-ipad.md`, `thread.md`, ...) holds what
Shepherd draws. When they disagree, the user's design wins first, then the surface spec. Tell the
user when a design breaks a platform rule in these files.

| Platform | File | Shell in code | Size class |
| --- | --- | --- | --- |
| Mac | [platform-macos.md](platform-macos.md) | `Sources/ShepherdApp` (one `Window` scene) | n/a (window sizes) |
| iPhone | [platform-iphone.md](platform-iphone.md) | `App/iOS/App/PhoneShell.swift` | compact width |
| iPad | [platform-ipad.md](platform-ipad.md) | `App/iOS/App/PadShell.swift` | regular width |
| iPhone Duo (foldable) | [platform-iphone-duo.md](platform-iphone-duo.md) | both: phone shell closed, pad shell open | compact closed, regular open |

## Rules for every platform

- **Choose a layout by size class or window size, never by device or orientation.** `MobileRoot`
  picks `PhoneShell` or `PadShell` from `horizontalSizeClass` alone, so an iPad in a narrow window
  and a Duo folded shut both get the phone shell. Never branch on `userInterfaceIdiom`, the device
  model or the screen's bounds. Measure the view or scene you're in (HIG Layout › Size classes).
- **Keep the same functions at every size.** A bigger window may show more at once (a list beside
  a thread, a tab bar that becomes a sidebar). It never adds or removes a function. Anything you
  can do in one layout you can do in every layout (HIG Layout).
- **Keep state through a resize.** Rotating, resizing, folding or moving to another display keeps
  the selection, the scroll position and any unsent draft (HIG Multitasking; Duo "Create a
  consistent experience").
- **Use system containers and bars before custom ones.** `NavigationSplitView`, `TabView`,
  `NavigationStack` plus `.toolbar`, sheets and popovers adapt to every platform's chrome by
  themselves, including the Duo's vertical bars and fold. A custom bar is drawn the same everywhere
  and is wrong on at least one of them.
- **Respect safe areas and reserved regions.** Lay out inside the safe area. On the Duo, also keep
  out of the reserved regions (the camera, and the fold while the phone is half open).
- **Every toolbar item has an SF Symbol and a title.** The system shows the icon in a vertical or
  compact bar and the title in overflow menus and to VoiceOver.
- **Render the smallest and the largest layout** of the surface you changed, in light and dark
  ([verifying.md](verifying.md); iOS: [docs/ios/VALIDATION.md](../ios/VALIDATION.md)).

## Sources

Apple HIG: Designing for macOS, iOS, iPadOS and iPhone Duo; Layout; Windows; Multitasking; Split
views; Toolbars; Tab bars; Sidebars (developer.apple.com/design/human-interface-guidelines/). The
developer article "Preparing your app for iPhone Duo" (developer.apple.com/documentation/
technologyoverviews/preparing-your-app-for-iphone-duo). The Duo's measurements come from Xcode
27.1's simulator profile. Apple can revise these pages, so check them again before quoting a rule
as current.

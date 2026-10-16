# Image viewer runtime verification

Verified the checkout-built Shepherd Dev app after integrating `origin/nightly`.
The user supplied ThreadImageOpen and then reported the toolbar overlapping the
window controls and controls stranded at the corners.

The Dev app ran with a scratch home, support directory, defaults suite and stub
engine. The real server loaded a saved message containing portrait and landscape
PNG attachments. No provider requests or changes to the running Nightly app.

## Screenshots

- [Light landscape, sidebar hidden](dev-viewer-light-landscape.png)
- [Dark portrait, sidebar hidden](dev-viewer-dark-portrait.png)
- [Dark portrait, narrow window](dev-viewer-dark-narrow.png)

Opened the saved-message thumbnails with AXPress, stepped backwards, closed the
viewer, hid the sidebar, reopened the viewer and pressed Add to message. The
composer then contained the selected image and its Remove control. Also inspected
the wide light viewer with the sidebar shown. Resized the real Dev window to
760 × 700 through its accessibility size attribute, without posted input events.

The toolbar stays clear of the traffic lights. Its controls form a centered,
bounded column rather than occupying opposite window corners. Paging arrows sit
16pt beside the fitted image in both orientations. The image retains its aspect
ratio. The narrower window preserves readable metadata and reachable controls.

ControlPress tests separately exercise Copy, Add to message, Show in Finder,
Close, paging and the icon-only narrow toolbar, with action and hit-area
assertions. Preview tests cover wide and narrow layouts in light and dark and
at text scale 1.3.

## Departures

The user's correction changes the board's toolbar layout to a centered 820pt
column with space reserved for the traffic lights. Narrow layouts use named
icon-only actions when labels do not fit. Image-side paging matches the board.
No other intentional departure was introduced by this change.

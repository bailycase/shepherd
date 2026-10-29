# Side pane: Files

> Read when changing the Files browser, source viewer, word wrap or Markdown preview.

The selected direction is the user-supplied [FileOpenSplit board](boards/FileOpenSplit.png).
Files sits after Browser in the existing side pane. Its fixed shortcut is ⌃5, preserving
Subagents on ⌃4 (⌃3 belonged to the removed Artifacts tab). The existing pane controls resize, maximize and close it.

For a local thread, the browser reads the thread's effective working directory (including its
worktree). Moving the thread replaces the browser's root. The browser is read-only: selecting
files never modifies them or sends their contents to an external service.

The viewer is on the left; a lazy, resizable directory tree is on the far right. Either the
viewer header's tree button or the tree header's collapse button hides the tree; Show file
tree brings it back. Open files have selectable, closable tabs, a relative path and available
size/line metadata. The model retains open tabs while the thread exists.

Text uses a native selectable, horizontally scrollable text view with line numbers, native
Find (⌘F), and the existing Tree-sitter grammars and syntax roles. Unsupported grammars stay
plain text. Refresh rereads the selected file, even if its path and line count did not change.
Appearance, theme and text-size changes update the mounted viewer. Common raster images use
bounded ImageIO thumbnails; SVG is readable source text. Binary, oversized, inaccessible and
special files have explicit error states instead of an empty viewer.

The filter explicitly applies to expanded folders, not an unbounded recursive search. The
eye button includes hidden files on demand. Refresh preserves expanded folders and rereads
the selected file. Directory errors, loading, empty directories and missing files are visible.
Symlinks cannot escape the root or recursively traverse an ancestor. File reads are bounded.

A remote thread's Files reads the thread's folder on its host over `files.v1`
([remote-protocol](../remote-protocol.md)): the same tree, read-only, with paths sent relative to
that folder. The host answers with the same resolver (`ThreadFileSystem`, ShepherdProtocol), so the
root, symlink, hidden-file and bounded-read rules above hold there too. A remote read is UTF-8 text
of at most 256 KiB (images read as binary), and a listing at most 2,000 entries. A host without
`files.v1` (an older Shepherd) keeps the tab and says Files needs a newer Shepherd on it. The iPhone
and iPad client draws the same tree as `ThreadFilesPane` (`App/iOS/Files`; DuoSidePaneTabs' Files
card). No synthetic "Added by this thread" label, or added/modified mark, is shown without
provenance: the host's recorded turns name repository paths, can be partial and can be undone, so
they are not an accurate per-file mark for the folder.

Design departures: refresh is manual rather than live. The footer counts visible files and
folders, and metadata includes file size instead of a thread-origin badge. Added-line fills,
change-status marks and a live cursor are omitted because this read-only filesystem viewer
does not have a thread-to-patch mapping. Existing Changes remains the diff surface.

The viewer header also has word wrap for source and a source/preview toggle for `.md` and
`.markdown` files. Both preferences are saved across files, threads and app launches; initially
source is unwrapped. Wrapped source keeps logical line numbers and reflows with the viewport.
Markdown preview reuses the thread's native prose renderer, with no scripts or automatic image
fetching; local image references remain chips rather than bypassing the browser's root checks.
These toolbar controls extend the original board at the user's request.

The preview suite renders real directory listings and source-file reads in light/dark and at
the larger text scale. File-system and native-viewer integration tests cover the data path.

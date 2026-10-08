# Add child project

> Read when: changing local child-project creation, registration, or its dialog.

The user's requested UI supports creating a new folder or registering an existing folder
inside a parent project. This supplements SettingsProjects and Sidebar Projects. No image
was supplied. The shared Night Watch dialog is the reference for layout.

## Implementation checklist

- A local sidebar project's native menu has "Add Child Project…" after New Thread, before
  Reveal in Finder. No additional glyph. Settings' existing "Add subproject" opens the same
  dialog for local projects. Remote projects retain their existing directory-picker flow.
- Dialog elements, in order: "Add child project" heading; parent name and path; a segmented
  "Folder source" picker with "New folder" and "Existing folder"; "Folder name" for new
  folders or "Folder path" and "Browse…" for existing folders; "Display name" with the
  placeholder "Defaults to folder name"; status/error; Cancel and the primary action.
- Use NWDialog and NWDialogMetrics.width/inset, NWSheetRow, NWSegmentedPicker, nwField,
  NW.Space spacing, nw primary/ghost/secondary button styles, and existing
  body/caption/mono typography. No new colors, dimensions, animation, or glyphs.
- New folder is initially selected. Its primary action is "Create and add". Existing folder
  uses "Add project". Blank folder input disables the primary action. An empty display name
  uses the folder's basename. "Adding project…" replaces status during submission, and the
  fields, picker, Browse, and footer actions are disabled. The sheet cannot dismiss mid-save.
- Browse uses the existing RemoteDirectoryPicker, rooted at the parent, with title
  "Choose child folder", action "Choose", and host "This Mac". Its standard loading, empty,
  hidden-directory, navigation, and error states are unchanged. Choosing a directory updates
  the form, not registration. Canonical containment is checked on submission.
- Status appears below the fields, above the footer, as wrapping caption text with no line
  limit. It uses textSecondary when idle or busy and failed for errors. The first preview
  exposed truncated error text in the dialog footer, so status uses the content area's full
  width instead. Idle status is "The folder must be inside the parent project.". Validation and filesystem
  failures appear through the service's error text. They leave input intact and enable retry.
  Creation never overwrites an existing entry, creates intermediate folders, or initializes Git.
  If registration fails after mkdir, the new empty folder stays. The error says where it was
  created and asks the user to select Existing folder to retry; nothing is deleted automatically.
- Cancel dismisses without filesystem/state changes. Success adopts live state, refreshes the
  Projects list, and dismisses without selecting the child or starting a thread. Registration
  preserves any existing canonical registration. Projects settings groups by the outermost
  ancestor as before. The user's subsequent request also nests sidebar child-project rows.
- Render new/empty, filled, existing, error, busy, and long parent/path/name at text scales 1
  and 1.3 in light and dark. Use real model/service output for labels and errors.
- ControlPress must exercise both modes, Browse/Choose/Cancel, both submit actions, validation
  errors, duplicate registration, busy controls, and the sidebar/settings entry points. Assert
  filesystem state, live registration/selection, and 24pt hit areas.

## Nested sidebar checklist

The user's subsequent request supersedes the initial flat-sidebar behavior.

- Derive parent relationships from registered folder paths on the same host. Use the outermost
  visible registered ancestor, matching Settings' one grouping level. A hidden parent does not
  hide a child implicitly. A name-merged remote project with ambiguous host/path ownership stays
  at the top level rather than guessing a parent.
- Parent row, its own threads, then its child project rows. Keep root order and sibling order
  from the saved spaces. A newly registered child appears inside its parent, never above it.
- Reuse NWProjectRow and NWSidebarRow unchanged. Child projects receive one additional leading
  inset of NWProjectMetrics.chevronSlot + NWProjectMetrics.gap. Their thread rows receive the
  same extra inset on top of existing thread nesting. No new glyph, size, color, or animation.
  Outline folder, existing chevrons, labels, plus/menu actions, and status colors remain unchanged.
- Parent collapse hides child project rows and their threads. Child collapse hides its own
  threads only. Parent counts and collapsed attention/running indicators include descendants.
  A new registration expands its parent so the child is visible, without changing selection.
  Revealing a selected child thread expands both its project and parent. Keyboard shortcuts
  follow only visible threads. Dragging reorders siblings, never reparents directories.
- Render open, parent-collapsed, child-collapsed, empty, long names, and attention states in
  both appearances at text scales 1 and 1.3. Press parent/child disclosures and child actions,
  assert indentation, selection reveal, hidden rows, shortcut order, and drag sibling boundaries.

## Remove project checklist

The user requested removing a project or child project without deleting its folder.

- Add native "Remove Project…" after Hide from Sidebar, separated by a divider, in a local
  project's sidebar menu. Use the native destructive role, no new glyph or style. Settings'
  local registered project rows offer the same context-menu action. Unregistered history rows
  and remote-only projects do not expose this local removal action.
- Reuse SpaceDeleteDialog and the existing deleteSpace flow. Title and destructive action:
  "Remove project". Cancel stays the ghost cancel action; removal is never the Return default.
- Subtitle uses the selected project's name and live direct-agent count: "Removes <name> from
  the sidebar and stops its <count> agent(s). The local folder and all its files are kept.
  Saved conversations and project history remain. Child projects stay registered."
- Keep NWDialogMetrics.width, shared DialogSheet styles, typography, spacing, and colors. Long
  project names wrap in the message. Zero, one, and several agents use the existing count and
  pluralization. The existing dismissal-before-layout-teardown timing stays unchanged.
- Cancel changes nothing. Confirm removes only the selected registration and its own agents,
  tabs, and live sessions. Child/sibling registrations and their processes survive. Parent
  removal promotes visible child projects to top-level rows. No repository, folder, worktree,
  branch, project file, or saved conversation is deleted. Settings retains directory history.
- Render parent/child, zero/one/several agents, and long names at scales 1 and 1.3 in light/dark.
  ControlPress exercises both menu entry points, Cancel and Remove project, with 24pt dialog
  hit areas. Verify committed state, surviving registrations, stopped/surviving processes, and
  byte-for-byte retention of files in both parent and child directories.

## Verification

The six-state matrix was rendered and inspected in light/dark at scales 1 and 1.3.
`ChildProjectTests` presses both modes, Browse/Choose/browser Cancel, form Cancel, both submit
actions, retries, disabled busy controls, and both entry points. The Settings test types into
the native field and creates the child while the real list reload task is active. It checks
live grouping and does not start an agent. Integration checks also cover canonical escape,
existing-entry preservation, on-disk registration, and retention of a folder after a failed
state write. The nested-sidebar follow-up adds disclosure, indentation, selected-thread reveal,
host isolation, sibling-drag tests, and a 300-child lazy-render budget. Its six states were
also inspected in both appearances at scales 1 and 1.3. No design departures. The Dev build
compiles; Josh's foreground app verification is still pending before publishing the PR.

# Spaces

Settings > Spaces lists folders by host and canonical directory, not by display name.
It includes sidebar-hidden spaces, current agent working directories and retained space
history. Removing a space does not remove its history. The reserved automation and
design spaces never appear in the list.

The list has a name/path/host filter, host selection and Add space. Add space uses the
existing directory picker and creates a space on the selected host. It does not start an agent,
initialize git or write configuration files. All hosts defaults Add space to This Mac.
An unavailable host keeps its known rows, but cannot accept edits or new spaces.

For a local child space, use **Add subspace** on its parent in Settings, or
**Add Child Space…** in the parent's sidebar menu. Choose **New folder** to create one
empty direct child folder, or **Existing folder** to select an existing descendant. An
optional display name defaults to the folder name. Existing folder capitalization is preserved:
requesting `Docs` reuses `docs`, rather than creating or renaming a second directory.
Adding updates live state without selecting
the space or starting a thread. Existing registrations remain unchanged. No Git repository
is initialized. The folder must resolve inside the parent; symlinks cannot point outside it.
A failed registration leaves a newly created folder in place, so retry with Existing folder.
Remote spaces retain the existing picker and cannot create folders through this dialog.
Settings and the sidebar infer the outermost visible parent on the same host for older
registrations. New child registrations and explicit edits keep their chosen parent, including
multiple levels. These display relationships never change filesystem/config ancestry.
The sidebar indents child spaces and their threads. Collapsing a parent hides its children;
its count and attention indicator include their threads. Selecting a child thread reopens
both levels. Dragging reorders siblings, not parent relationships. Hiding a parent leaves its
visible children as top-level spaces.

To rename a local space or subspace after adding it, choose **Rename Space…** from its
sidebar menu or Settings row's context menu/accessibility actions. Confirming changes the
display name, not its ID, folder name, path, parent, or files. Cancel changes nothing.

Agents can edit names and display parents with `project_edit`, and request removal confirmation
with `project_delete`. Editing defaults to metadata only. Physical folder move/copy requires an
explicit user request and explicit `folderAction`/`destinationPath` arguments. See the exact
schemas, refusal conditions, and recovery behavior in [space tools](agent-coordination.md#space-registration-and-refresh).

To remove a local space or subspace from the sidebar, choose **Remove Space…** from
its sidebar menu or its Settings row's context menu, then confirm **Remove space**. This
stops that space's agents and closes its tabs, but keeps the local folder, all files,
worktrees, saved conversations, and Settings directory history. Child spaces are separate
registrations and survive parent removal, becoming top-level sidebar rows. Cancel changes
nothing. History-only Settings rows and remote spaces have no local removal action.

Open a space to edit its existing files, or create the standard instruction, pi settings or MCP
files when they are missing. The categories are Instructions, Pi settings, Skills, Extensions
and MCP servers. Text files use the existing Instructions editor. MCP uses the same server
cards and add/edit forms as Settings > MCP servers, with file tabs for `.pi/mcp.json` and
`.mcp.json`. Changes save through the selected host's file API, with conflict checks. Native
space MCP uses `enabled`, `exposure`, `timeout` and `oauth`; shared `.mcp.json` uses `disabled`
and keeps tools searchable. Unknown fields and other top-level sections stay intact.
Space forms keep credentials and environment references in the space file, never the
local global Keychain. They neither connect to servers nor report global runtime status as
space status. Invalid files show an error and cannot be replaced by form edits. Open in editor
remains available for repair and unsupported advanced fields. Extensions also includes
`.pi/settings.json`, where pi's extension and package paths live. Saving does not execute a
skill, extension or MCP server, change project trust, or restart an agent. Running agents must
restart before they use the changes.

The native MCP page separately shows whether Pi approves project resources. "Trust this
space…" requires confirmation covering settings, executable extensions, MCP commands and
package installation. The selected host saves its own Pi decision for that canonical folder;
it never approves a parent or the home folder. New threads use it without a global trust
override. "Credentials saved" means OAuth tokens exist on that host, not that a thread has
loaded or connected the server. The approval card also distinguishes checking, unavailable
hosts, old hosts and errors. See [MCP approval](mcp.md#space-approval-and-thread-loading).

## Storage and safety

`<support>/projects.json` holds directory/name history separately from `state.json`. A page
request also imports session-header working directories for older deleted agents. It reads no
conversation text. This migration has a five-second, 20,000-entry scan limit per app launch.
On a very large session tree it may not find every historical folder in one scan.

The list derives summaries from the space's files and pi configuration. A design-system
marker comes from Shepherd's existing `design-systems/*/system.json` metadata and its space ID.
Unknown pi settings stay in the file; the editor never rewrites a JSON object from a subset of
fields.

The file API allows only `AGENTS.md`, `AGENTS.override.md`, `.pi/SYSTEM.md`,
`.pi/APPEND_SYSTEM.md`, `.pi/settings.json`, `.pi/mcp.json`,
`.mcp.json`, discovered `.pi/skills/*/SKILL.md`, `.agents/skills/*/SKILL.md` and discovered
JavaScript/TypeScript files directly under `.pi/extensions`. It refuses unknown directories,
traversal, symbolic links, devices, non-UTF-8 data and files over 64 KiB. Missing files differ
from empty files. JSON saves require an object. Pi settings accept the comments and UTF-8 BOM
that pi accepts. Saves compare the last-read contents again through the destination directory
descriptor, preserve permissions, and replace atomically. Detected conflicts leave the disk
file and the editor's draft unchanged. The home directory and global pi, instructions, skills
and configuration directories cannot become space editors. A changed remote endpoint
invalidates an open space's editor.
Changing category/file or closing a dirty detail asks before discarding. Failed reads cannot
be saved.

`projects.details.v1` adds metadata/context and host-local editor opening to `projects.v1`.
Older hosts retain file editing, disable editor opening and cannot supply context counts.
Editor opening validates the allowlisted file through directory descriptors and pins its
identity with a macOS file reference before asking that host's editor to open it.

`projects.v1` carries list, files, read and save requests over the authenticated existing remote
connection. The host validates every request and accesses only its own space files. An older
host requires an update. The transport has no TLS; space contents travel over the same
connection as the rest of remote Shepherd, never to a model provider. No file contents are
logged.

## Design and checks

The list follows [SettingsProjects](design/settings-projects.md), revision 492. The detail
follows [ProjectInstructions](design/project-instructions.md), revision 562, with a line-numbered
editor and host-scoped context cards. Context uses pi's actual context-file chooser, so a
present `AGENTS.override.md` replaces `AGENTS.md` in the read order.

[ProjectBrowser](design/project-browser.md), revision 572, defines the Browser tab. It manages
the same space store as thread pages. Normal threads and worktrees share the SpaceID's
persistent store. A remote space adds the configured connection UUID to that key; its
cookies still remain on this Mac. The listing supplies the exact active space ID, even when
the displayed directory has a standardized spelling. Clear actions require confirmation and
remove only cookies. They leave local storage/cache and all other space stores unchanged.
`SpacesTerminologyTests` pins the visible names against the stored values and tool ids that keep
the old spelling. `ProjectSettingsTests` covers scoped/conflict-safe local and remote IO, retained history and
rejected file paths. `ProjectsModelTests` covers host identity, filters and dirty navigation.
`ProjectsControlTests` presses rendered controls through accessibility without focusing a
window. `ProjectsPreviewTests` renders real scratch local and remote space files in light,
dark and text scale 1.3.

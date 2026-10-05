# Projects

Settings > Projects lists folders by host and canonical directory, not by display name.
It includes sidebar-hidden spaces, current agent working directories and retained project
history. Removing a space does not remove its project history. Reserved automation and
design spaces are not projects.

The list has a name/path/host filter, host selection and Add project. Add project uses the
existing directory picker and creates a space on the selected host. It does not start an agent,
initialize git or write configuration files. All hosts defaults Add project to This Mac.
An unavailable host keeps its known rows, but cannot accept edits or new projects.

Open a project to edit its existing files, or create the standard instruction, pi settings or MCP
files when they are missing. The categories are Instructions, Pi settings, Skills, Extensions
and MCP servers. Text files use the existing Instructions editor. MCP uses the same server
cards and add/edit forms as Settings > MCP servers, with file tabs for `.pi/mcp.json` and
`.mcp.json`. Changes save through the selected host's file API, with conflict checks. Native
project MCP uses `enabled`, `exposure`, `timeout` and `oauth`; shared `.mcp.json` uses `disabled`
and keeps tools searchable. Unknown fields and other top-level sections stay intact.
Project forms keep credentials and environment references in the project file, never the
local global Keychain. They neither connect to servers nor report global runtime status as
project status. Invalid files show an error and cannot be replaced by form edits. Open in editor
remains available for repair and unsupported advanced fields. Extensions also includes
`.pi/settings.json`, where pi's extension and package paths live. Saving does not execute a
skill, extension or MCP server, change project trust, or restart an agent. Running agents must
restart before they use the changes.

## Storage and safety

`<support>/projects.json` holds directory/name history separately from `state.json`. A page
request also imports session-header working directories for older deleted agents. It reads no
conversation text. This migration has a five-second, 20,000-entry scan limit per app launch.
On a very large session tree it may not find every historical folder in one scan.

The list derives summaries from the project's files and pi configuration. A design-system
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
and configuration directories cannot become project editors. A changed remote endpoint
invalidates an open project's editor.
Changing category/file or closing a dirty detail asks before discarding. Failed reads cannot
be saved.

`projects.details.v1` adds metadata/context and host-local editor opening to `projects.v1`.
Older hosts retain file editing, disable editor opening and cannot supply context counts.
Editor opening validates the allowlisted file through directory descriptors and pins its
identity with a macOS file reference before asking that host's editor to open it.

`projects.v1` carries list, files, read and save requests over the authenticated existing remote
connection. The host validates every request and accesses only its own project files. An older
host requires an update. The transport has no TLS; project contents travel over the same
connection as the rest of remote Shepherd, never to a model provider. No file contents are
logged.

## Design and checks

The list follows [SettingsProjects](design/settings-projects.md), revision 492. The detail
follows [ProjectInstructions](design/project-instructions.md), revision 562, with a line-numbered
editor and host-scoped context cards. Context uses pi's actual context-file chooser, so a
present `AGENTS.override.md` replaces `AGENTS.md` in the read order.

[ProjectBrowser](design/project-browser.md), revision 572, defines the Browser tab. It manages
the same project store as thread pages. Normal threads and worktrees share the SpaceID's
persistent store. A remote project adds the configured connection UUID to that key; its
cookies still remain on this Mac. The listing supplies the exact active project ID, even when
the displayed directory has a standardized spelling. Clear actions require confirmation and
remove only cookies. They leave local storage/cache and all other project stores unchanged.
`ProjectSettingsTests` covers scoped/conflict-safe local and remote IO, retained history and
rejected file paths. `ProjectsModelTests` covers host identity, filters and dirty navigation.
`ProjectsControlTests` presses rendered controls through accessibility without focusing a
window. `ProjectsPreviewTests` renders real scratch local and remote project files in light,
dark and text scale 1.3.

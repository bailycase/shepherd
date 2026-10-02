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
and MCP servers. The editor uses the existing Instructions editor. Extensions also includes
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

The file API allows only `AGENTS.md`, `.pi/APPEND_SYSTEM.md`, `.pi/settings.json`, `.pi/mcp.json`,
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

`projects.v1` carries list, files, read and save requests over the authenticated existing remote
connection. The host validates every request and accesses only its own project files. An older
host requires an update. The transport has no TLS; project contents travel over the same
connection as the rest of remote Shepherd, never to a model provider. No file contents are
logged.

## Design and checks

The list follows [SettingsProjects](design/settings-projects.md), revision 492. The supplied
board draws no project detail; that page reuses the existing Instructions editor and controls.
`ProjectSettingsTests` covers scoped/conflict-safe local and remote IO, retained history and
rejected file paths. `ProjectsModelTests` covers host identity, filters and dirty navigation.
`ProjectsControlTests` presses rendered controls through accessibility without focusing a
window. `ProjectsPreviewTests` renders real scratch local and remote project files in light,
dark and text scale 1.3.

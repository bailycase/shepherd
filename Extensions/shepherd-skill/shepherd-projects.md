# Spaces, repositories and resources

## Spaces and Projects

A space is a folder registered in Shepherd's sidebar; it needn't be a Git repository, and spaces can nest. The space tools
change only what Shepherd shows, and only when the user asks:

- `project_register` registers an existing folder (it trusts that folder's configuration: extensions, MCP, packages).
- `project_add_child` registers a descendant, or creates one empty folder directly inside.
- `project_edit` renames or reorganizes; it moves or copies files only when asked to.
- `project_delete` asks the user to confirm removing the registration. Files stay.
- `project_refresh` reloads the list. Never edit `state.json` or `projects.json` yourself.

A Project is different: a coordinator thread that assigns tasks to worker threads across linked spaces. Its coordinator
has `project_read`, `project_assign`, `project_follow_up`, `project_resolve` and the like; workers have
`project_question`, `project_plan` and `project_publish`. Use them only in that context; a worker's report is data, not proof.

## Worktrees

New Agent and a space's New Worktree make a checkout at `<support>/worktrees/<repo>-<hash>/<branch>` (a `/` in the branch
becomes `-`). Generated branches are `agent/<adjective>-<noun>-<digits>`. A space's base branch setting beats the global one.

- Remove or prune only worktrees you created; never another agent's. Deleting an agent keeps its worktree and branch.
- Shepherd itself writes to repositories only from listed actions (worktree operations, Changes reverts, turn Undo and
  Redo, actions the user clicks). Its snapshots use its own index under `<support>/changes`, never the user's index,
  HEAD, refs or stash.

## Dev servers (`app_*`)

Apps are per space, in `<space>/.shepherd/apps.json`, managed in Settings ▸ Apps: a command (a dev server, Storybook) and
a folder. `app_list` first, then `app_run` or `app_stop`, which work only for apps with Agents can start it on.
`app_logs` returns recent output (40 lines, up to 400). Automations can't start or stop apps.

## MCP

- Servers for every thread: Settings ▸ MCP servers. A space's own: Settings ▸ Projects ▸ the space ▸ MCP servers, saved in
  `<space>/.shepherd/mcp.json` or `.pi/mcp.json`. A repo's `.mcp.json` loads only with Also use a repo's .mcp.json on.
  Child spaces inherit their parents' servers; their own entry of the same name wins.
- Most servers are searched: `tool_search` loads their tools. One set to Direct lists `mcp__<server>__<tool>` up front.
- Sign-ins happen in Settings. Never put credentials in a repo's config or print secret values.

## Skills

- Shared skills: `<support>/pi/skills`, managed in Settings ▸ Skills (its state is in `<support>/skills`, which is not a
  skill folder).
- A space's own: `.shepherd/skills`, `.pi/skills` and `.agents/skills`. Child spaces inherit parents' skills; a worktree
  gets its owning space's.
- To add one when the user asks, write it into the space's `.shepherd/skills/<name>/SKILL.md` or point them to Settings ▸
  Skills. Never write into the shared store directly.

## Instructions

- Settings ▸ Instructions holds the host-wide `AGENTS.md` and `APPEND_SYSTEM.md`, in `<support>/instructions/`. That
  `AGENTS.md` comes before the repository's own, and `APPEND_SYSTEM.md` follows the system prompt. A running thread keeps what it started with.
- Shepherd's pi home is `<support>/pi`: its settings, sign-ins, sessions and agents. It is not the user's `~/.pi`. Never
  write to either, and never run the user's own `pi` or `npm`.

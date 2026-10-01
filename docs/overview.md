# Shepherd in brief

> Read when you need the product model on one page: agents, terminals, spaces, lifetime and remote.

Shepherd is a native macOS app (SwiftUI, macOS 26+) for running and supervising many `pi` coding
agents.

- **Agents:** every agent is `pi --mode rpc` on pipes, owned in-process (`RPCSession` and
  `RPCThreadState` in `ShepherdSessions`), and rendered only as a native thread
  (`Sources/ShepherdApp/Thread/`). There are no terminal agents and no Terminal/Native switch.
- **Terminals:** the only terminals are tabs of an agent's terminal panel, one terminal per tab,
  opened by the user with ⌘D, ⌘J (when the thread has none) or the panel's + or by an agent's
  `terminal_*` tools. The Mac shows them in the terminal panel under the thread (tabs, maximize,
  ⌘J to show or hide; docs/design/terminal.md › Terminal panel), as does the iPad; the iPhone opens them full
  screen. There are no splits, and the panel is never empty: it closes with its last terminal. On
  the Mac they are real PTYs rendered with libghostty; the iOS client attaches to the host's over
  the remote protocol and renders them with SwiftTerm. There are no global shells and no space
  shell workspaces.
- **Spaces** are projects: the folders threads start in. The default Activity sidebar has no
  tree; the optional Projects style groups threads in a project tree. Activity lists
  destinations (New thread, Automations, More ▸ Hosts and Extensions), then Needs you, Pinned
  (the threads the user pinned, per Mac) and Recents (every other agent, local and remote, most
  recently active first). The New thread page's workplace
  chip lists each host's spaces, flat. With no agent on screen, the main column shows New thread.
- **Lifetime:** there is no daemon. Sessions live and die with the app. On relaunch the workspace
  (spaces, agents, terminal layouts) restores from `state.json`, every agent resumes its pi session
  over RPC, and every terminal respawns a fresh shell.
- **Remote:** Shepherd can serve its agents to other devices over an authenticated TCP listener
  (off by default). The main use is running projects on one Mac and driving them from another
  Mac running Shepherd. The iPhone and iPad client (`App/iOS`) drives them the same way.

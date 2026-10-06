# Project MCP sign-in

User requirement: reuse Settings > MCP servers' OAuth sign-in flow in Settings > Projects > MCP servers, on both local and remote hosts.

## Checklist

- Keep the existing project header, host identity, filter, server cards, Add/Edit forms and file-save controls.
- Reuse MCPServerRow, MCPServerDetail and MCPSignInSheetHost unchanged, including their glyphs, Night Watch tokens and hit areas.
- HTTP servers without an Authorization header offer "Sign in". Signed-in servers offer the existing "Sign out" control.
- "Add and sign in" saves successfully before starting authentication. Editing or opening a project never starts authentication.
- Use the existing finding, registration, browser-wait, success and error states. "Open browser again", "Copy link", "Try again" and "Cancel" retain their existing actions.
- The host reads the selected server from the project file. The viewer never sends server credentials to another host. Tokens stay in the host's pi home and are available to its agent sessions.
- Remote authentication opens the viewer's browser. Forward only the pending loopback OAuth callback, with state validation, bounded lifetime and cleanup.
- Older or disconnected hosts show why sign-in is unavailable. Switching projects, cancellation, timeout and disconnection stop pending authentication. Restart never resumes it.
- Verify unsigned, signed-in, waiting, success, failure, empty and long-name states in light/dark and large text. Press sign-in, sign-out and sheet controls through accessibility.

Departures: none intended.

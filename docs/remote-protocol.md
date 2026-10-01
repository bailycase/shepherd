# Remote

> Read when you change the remote listener, its protocol, its auth, or a client's connection.

- **Listener:** `SessionServer.startRemoteListener(port:tokenURL:)` binds TCP on **all
  interfaces** (default 7433, or 7434 in Shepherd Nightly so both apps can serve; port 0 picks
  an ephemeral port, and the bound port is returned).
  Settings ▸ Remote ▸ Serve this Mac toggles it, and bind failures show there.
- **Auth:** the first frame must be `hello` with the token from `remote-token` in the support
  directory (32 random bytes as hex, mode 0600, created on first use) and a matching
  `RemoteProtocol.version`, listing what the client understands
  (`RemoteProtocol.clientCapabilities`; older clients list nothing). **There is no TLS.** A VPN
  or trusted network is the transport boundary. Never describe the listener as internet-safe.
- **Protocol** (NDJSON, `RemoteMessage.swift`):
  - state fetch and pushed `stateChanged`
  - native thread requests, with the context and Compact now behind `native.context.v1`, Retry
    in place behind `native.retry.v1`, and Steer now (a message that stops pi and goes at once,
    `interrupt` in `supportedActions`, sent as a steer to a host without it) behind
    `native.interrupt.v1` (Return queues, `followUp`, and no client offers a steer as a choice;
    `NativeThreadDelivery.steer` stays on the wire for older clients and that fallback), and an
    agent's service tier (`setServiceTier`, the snapshot's
    `serviceTier` and `serviceTiers`; no Speed control from a host without it) behind
    `native.serviceTier.v1`
  - conversation goals behind `native.goal.v1`: optional snapshot `goal`, live-only fleet
    `goalState`, and `NativeThreadRequest.goal` for set, edit, pause, resume, clear and confirm.
    Pause/Resume/Confirm require the displayed goal ID, revision and state in addition to the
    session generation. Controller transitions increment that revision; accounting updates do
    not. Optional `checkedBy`, `confirmationRequired`, `confirmedByUser`, `checkCount` and
    `runningSince` decode absent on older hosts. The interval start is epoch milliseconds;
    clients update only the pill clock locally. Typed Edit omits preserved limits and uses
    `clearTimeLimit`/`clearTokenLimit` to lift them; the host emits explicit null in controller JSON. Confirm is user attestation, not independent verification. A host without
    the capability hides these controls but keeps ordinary chat. Stop and Steer now pause the
    goal and cancel Checking before aborting pi, never resuming the goal for the replacement turn
  - attach, detach, input, resize, and acknowledged paste
  - terminal open and close (`openPane`, `closePane`)
  - `listDir`, `listModels`, `addSpace`, and `createAgent` with `creationOptions` (and the
    opening prompt's images behind `agent.create.images.v1`)
  - chunked uploads (32 MiB per file)
  - `agentQuery`/`agentAction`: rename, delete, reorder, review, subagents, search, worktree
    info/setup/finalize/delete, `terminals` (what each terminal runs; answered by the
    server itself, `terminal.activity.v1`), and commit from review (`commitInfo`,
    `commitMessage`, `commit` behind `review.commit.v1`; the commit is an operation polled with
    `worktreeStatus`), and the Changes pane (`changesOverview`, `changesList`, `changesFile`,
    `changesBranches`, `changesPatch`, `changesUndoTurn`, `changesRedoTurn` behind `changes.v1`,
    answered by the server itself; thread snapshots carry `turnChanges`). Older hosts review the
    working tree only (`review`). The terminal panel's own actions on an agent's terminals
    ride `agentAction` behind `terminal.control.v1`: `renameTerminal` (Rename tab) and
    `killTerminalProcess` (Kill process), each refused on the agent's thread. An older
    client's `typeInTerminal` (Run in terminal, since removed) is answered `unsupported`.
  - **Terminal compatibility** (no wire or capability change; docs/agent-coordination.md ›
    Terminals and compatibility): a current client's +, ⌘D and ⌘J send the same `openPane` they
    always did, naming the thread as `relativeTo` (axis horizontal, `TerminalPanel.newTabAnchor`).
    A current host ignores `axis` and `relativeTo` and opens a new tab in the thread's folder (or
    the request's `cwd`), answering `paneOpened`; there is no split request anywhere. So an older
    client's Split right or down opens a tab and it then sees the flattened layout; its
    `resizePaneSplit` is answered `unsupported` ("Terminals are tabs and have no splits to
    resize.") without reaching the GUI handler, and the connection stays; `closePane` of the
    thread still answers `not_closable`. A current client never offers Split: against an older
    host its `openPane` naming the thread splits the thread there, which is a new tab, and it
    draws that host's split tabs as one tab per terminal (`TerminalPanel.tabs`); a host without
    `pane.control.v1` fails the request `unsupported` and the client beeps
  - `automation` (`automations.v1`): switch on or off, run now, stop, the runs the host kept,
    create, edit, delete. There is no schedule or trigger: an automation that is on starts a run
    when Shepherd launches on the host. The Mac shows a host's automations under its sidebar
    section; the iOS client in Automations. A host without the capability shows them read-only
  - `instructions` (`instructions.v1`): Settings ▸ Instructions' files on the host (fetch, save,
    restore a saved version), answered with the files and their history. The Mac's page syncs
    them to every host, or edits one host at a time
  - `suggestions` (`suggestions.v1`): Settings ▸ Experiments ▸ Suggested instructions on the host
    (fetch, configure, add as edited and retargeted, add all, dismiss, undo), answered with the
    experiment's settings and its lines
  - `hostSettings` (`hostSettings.v1`): what the host's Settings ▸ Agents, Worktrees and Pi set,
    the pi packages its pi loads, and its Shepherd and pi versions; one change per request
    (`HostSettingChange`), applied as the Mac's own Settings would. The additive
    `goalCrossProviderEvaluation` consent is false when missing/null; its change applies to
    newly started or restarted agents, not a live process. Both clients disclose that scope
  - `skills` (`skills.v1`): Settings ▸ Skills on the host (fetch, look up a repository, install
    from one or from files, on or off, how it's used, remove and restore, check for updates,
    Update automatically), answered with the host's skills or the repository's, and beside them
    the skills its pi loads from elsewhere (`SkillsSnapshot.pi`, `skills.pi.v1`, read-only). The
    server runs them on its own queue (they fetch with git) and tells the host's page about each
    change (docs/skills.md)
  - `design` (`designs.v1`, offered only while the host's Design tool experiment is on): its
    designs and systems, a design's index with every project file's hash, changed files only
    (inline up to 256 KiB, larger ones and uploads in resumable pieces), comments and the
    canvas's writes through the host's own mutations, Delete with its Undo (`design.delete.v1`), and a pushed `designChanged` for the
    designs a client watches (`capabilitiesChanged` when the experiment turns on or off).
    Answered by the server itself; boards render on the client (docs/designs.md › Remote)
  - `tunnel` (`browser.tunnel.v1`, offered while the host can serve it, and only to a client that
    lists it in `hello`): a thread's Browser page on a viewing Mac reaches the host's dev server.
    `RemoteRequest.tunnel` and `RemoteReply.tunnel` carry `BrowserTunnelFrame`s (open, opened,
    data of at most 48 KiB, credit, finish, close, keepalive), multiplexed by a number the client
    picks, none answered by id. **Loopback only:** the host connects to `127.0.0.1`, then `::1`, on
    the port named and never another address (it is not a proxy), for an agent it has and the client
    is shown; 64 tunnels per client and 256 per host, closed when idle (5 minutes without bytes or
    a keepalive), all closed with the connection. Each direction is credit-paced (256 KiB window),
    and reads stop while a connection's write queue is backed up. The same capability covers
    `RemoteAgentQuery.devServers` (the thread's folder on the host) and `RemoteAgentAction.openTerminal`
    (Start on the host). docs/browser.md › Remote
  - `browserClaim`, `browserRelease`, `browserAnswer`, `browserClaimed` and `browserDrive`
    (`browser.drive.v1`, offered with the tunnel, and only to a client that lists it in `hello`): the
    agent on the host drives the page the viewer shows. A viewer with the thread's Browser tab on
    screen **claims** the agent's browser (`browserClaim`, answered `browserClaimed` with the address
    the host's own page holds, `http`/`https` only); the host keeps one owner per agent (the last to
    claim wins, at most 32 agents per viewer, only for a thread the client sees, never a design's
    agent) and, while one owns it, `SessionServer.routeBrowserRequest` pushes the agent's
    `BrowserRequest` to it (`BrowserDrivePush.request` with a token) instead of asking its own page,
    and completes the extension's request with the owner's `browserAnswer` (cut to the reply caps;
    an answer from anyone else is ignored). A request ends `viewer_gone` when its owner leaves, is
    superseded or releases, and `timeout` (the 120 s deadline, after which the owner loses the
    browser) when it never answers; the next call reaches the host's own page or the next owner. The
    host also pushes `abandoned` (Stop), `ended` (superseded, unresponsive, agent gone), `handBack`
    (the user's next message, from any client) and `opened` (the agent opened a page in the host's
    own browser: the viewer's tab takes the dot). The viewer runs a request with the local driver,
    bound by `BrowserViewerPolicy`: only the host's own loopback ports and public addresses (docs/
    browser.md › Remote › What a host's agent can make this Mac do; SECURITY.md). A claim ends with
    the viewer's tab out of sight for 30 s, its connection, or a newer claim. A client or host without
    the capability keeps PR 3a's two pages.

  Capabilities gate newer features. The client falls back (raw bracketed paste) or refuses (terminal
  control) against older hosts. A host answers an authenticated request it cannot decode (a kind
  or action from another version's client) with `unsupported` and keeps the connection; a frame
  with no `id` closes it. Output frames chunk at 256 KiB to stay under the 1 MiB frame cap.
- **Sizing:** viewports are smallest-viewer-wins. Each attached remote viewer reports its grid,
  and the PTY takes the minimum; with no remote viewers, the local viewport rules. Resize reports
  from unattached clients are ignored.
- **Attach is atomic** on the server queue: viewport registration, snapshot, attachment, and
  replay watermark happen in one turn.
- **Host-side handlers:** remote terminal and agent-creation requests go through
  `onRemotePaneRequest` and `onRemoteCreateAgent` with the same authorization as local requests,
  and host settings through `onRemoteHostSettings` (the GUI owns `AppSettings`). A server without
  those handlers rejects them. Detaching a remote terminal never kills the host session.
- **Client:** `RemoteHostStore` persists host configs, **including tokens**, in UserDefaults
  (`shepherd.remote.hosts`). It keeps one `RemoteHostClient` per host, with exponential backoff
  capped at 30 s. A refused token or another protocol version is not retried: the host shows
  why and waits for Edit or Reconnect. `RemoteHostFailure` (ShepherdRemote) is the one place
  that reads a failed connect as copy and a retry rule, for the Mac and iOS alike. A client
  reports a failed handshake only through what `connect` throws, never `onDisconnected`.
  Remote hosts are not part of `ShepherdState`.
- **Protocol changes** touch the request and reply enums with every Codable arm, `RemoteProtocol`
  capabilities where relevant, server handling, `RemoteHostClient` (Mac and iOS), and the
  round-trip and listener tests.

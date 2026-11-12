# Remote

> Read when you change the remote listener, its protocol, its auth, or a client's connection.

- **Listener:** `SessionServer.startRemoteListener(port:tokenURL:)` binds TCP on **all
  interfaces** (default 7433, or 7434 in Shepherd Nightly so both apps can serve; port 0 picks
  an ephemeral port, and the bound port is returned).
  Settings ▸ Fleet ▸ Serve this Mac (shown while Fleet is off; Fleet opens the listener itself)
  toggles it, and bind failures show there. The host opens it (`ShepherdHost.serveSettings`), so
  under the background service it stays reachable while the app is quit.
- **Local socket:** `SessionServer.startLocalListener(path:tokenURL:)` binds `<support>/host.sock`
  (mode 0600; the path must fit a unix socket's 104 bytes) for the app, always its
  host's client (`RemoteHostClient(localSocket:)`). Only the headless host (`Shepherd --host`,
  launchd's or the app's child) starts it. At accept, before any frame is read, `LocalPeer` checks that the peer is this user's
  (`getpeereid`) and that its code satisfies the host's own designated requirement (its audit
  token through `SecCodeCopyGuestWithAttributes`, then `SecCodeCheckValidity`; an ad-hoc build's
  requirement is its cdhash). pi and its agents run as the same user and can read the token, but
  are signed as something else, so they are closed unanswered. Then `hello` with the same token
  as TCP. Local clients alone are offered `local.v1` (`RemoteProtocol.localCapability`, never in
  `capabilities`), and closing the TCP listener leaves them connected. `helloOk` carries the
  host's build (`hostBuild`, `CFBundleVersion`), absent from older hosts. A host that drains
  offers local clients `host.drain.v1` and takes `drain` (answered `ok`, refused to TCP clients),
  which an app with a higher build number sends once connected (`BackgroundHostClient.asksToDrain`):
  it keeps serving and exits once no agent is working, blocked or starting, or after two hours
  (`HostDrain`). It drains on its own when its bundle's `CFBundleVersion` on disk changes or the
  bundle is gone (`BundleVersionWatch`). Local clients alone may send `spaceAction` (rename,
  base, hide, reorder or remove a space), `projectRequest` (register, edit or add a child space,
  answered `spaceAdded`) and `startThread` (a thread with a fork's session, an
  existing checkout, its own folder, a name or an id); TCP clients are refused. An app that lists
  `local.threads.v1` in hello shows the host's threads as its own and posts their turn and question
  banners, so the host doesn't while it is connected. Agent queries over the local socket judge a
  worktree's loss by the same rule (`GitWorktree.checkedUnreconciledWork(otherBranchesKeep:)`).
  `agent.restart.v1` hosts take `restartPi`, a stopped pi's Retry. A local client may also send
  `focusThread` (the thread it shows, so phone pushes for it stay quiet, and the pane with its
  keyboard, which `terminal_list` marks focused; cleared when it disconnects), and while it lists `local.threads.v1` the notify tool's banners go to it as an
  `agentNotify` push instead of posting on the host, and a `settingsChanged` push names the
  Settings page (instructions, suggestions, skills, hooks, slash commands, remote) whose data changed on the
  host, for the app to read again. `toolFinished` (a thread's finished tool call, for the sidebar's
  activity) and `threadNotice` (a line the host says in a thread, such as an account rotation) go to
  it the same way, as do `automationNotify` (an automation's banner, which the host then doesn't
  post), `automationsChanged` (a run log or trigger changed: read the runs and statuses again) and
  `agentStartProblem` (why an agent's pi stopped and it waits, nil once pi starts again; every
  agent's once when the client connects), and `pullRequestLinks` (every thread's pull request link
  and why a merged one was kept open, the sidebar's badges; as they change and when it connects).
  A local client with `appRelay.v1` also sends `projectExecutors` (the paired Macs it is connected
  to, and their execution hints), and answers the host's `projectPlacement` and
  `projectWorkerThread` relays through its connection to exactly that host and binding: a Project
  the host owns places work on another Mac only while this Mac's app runs, and says to open it
  otherwise. It also answers `browserPageURL` (the address of its page for an agent a viewer
  claims; none with the app quit).
  Only a local client may send the `automation` request `setRunPullRequest` (the pull request a
  run's thread opened, as the app read it through gh). The local link ends only when its socket
  closes: a request the host is slow to answer, or one the client's write queue can't hold, fails
  alone; host frames to a local client may reach `NDJSON.localMaxPayloadBytes` (16 MiB, so a large
  workspace's state still arrives) and queue up to 64 MiB; and a terminal it is attached to stops
  being read while it has 4 MiB unwritten, as a slow terminal emulator slows its program. Both
  sides log every drop with its reason (`ShepherdLog.connection`, category `Connection`). The host
  answers threads and terminals itself (`SessionServer.serveThreads`): new threads, their
  actions (Move as the app's drag), a dormant thread's pi on demand, terminals' shells, and New
  design, Open, Import and Build from a repo (`SessionServer.serveDesigns`). It answers host settings
  (`HostSettingsMapping.serve`) and, when Serve this Mac is on, opens the TCP listener itself
  (`ShepherdHost.serveSettings`; switching it opens or closes it at once), and
  `hostInventory` and `hostConfig` through `HostStores`. It answers
  worktree info and delete, commit from review (`WorktreeQueries`), subagents, transcript search and the working tree's review
  (`SessionServer.serveAgentQueries`); review panes and the inspector are refused.
  With no page of its own, the host hands an agent's browser call that no viewer claimed to the
  app over `host.sock` (a `browserDrive` request to the local client that lists the drive
  capability), which runs it on its own page with no tunnel; with no app connected the call is
  refused as `unavailable`, saying Shepherd's window is closed.
  It has no web view either, so `board_render`, `board_interact`, `design_export` and a reference's
  copy go to the same app as `designRelay` (only to a local client that lists `designRelay.v2`),
  answered `designRelayAnswer` with the token (`SessionServer.relayDesignDrawingToApp`). The
  `DesignRelayJob` travels as a JSON file under `design-relay/` in the support directory, named
  by `jobFile`, since a design's files outgrow a frame; the host removes it once answered. With no
  app connected after a few seconds' wait they fail as `render_unavailable` or `export_unavailable`.
- **Auth:** the first frame must be `hello` with a token and a matching `RemoteProtocol.version`,
  listing what the client understands (`RemoteProtocol.clientCapabilities`; older clients list
  nothing). The host accepts, in this order, and records which one opened the connection:
  the token of a **device** (a phone, iPad or Mac app paired as a client: `devices.json`, below), the
  token of a **peer Mac** (`peers.json`), or the **shared token** (`remote-token` in the support
  directory: 32 random bytes as hex, mode 0600, created on first use). There is no password and no
  pasted token anywhere: devices and Macs pair with a 6 digit code (Fleet, below). The shared token
  is the pre-fleet way in. It stays accepted while Fleet is off and while Fleet is on until Settings ▸
  Fleet ▸ Devices ▸ Stop accepting it, which the host refuses while a client it saw on the shared
  token hasn't been given its own (`devices_waiting`; Forget drops one that will not return). After
  that only device and peer tokens connect (this Mac's own app on `host.sock` keeps its own token), and
  connections that came in on the shared token end. Turning Fleet off ends peer and device
  connections (they connect only while Fleet is on); a retired shared token stays retired, read from `devices.json`. **There is no TLS.** A VPN or trusted
  network is the transport boundary. Never describe the listener as internet-safe.
- **Protocol** (NDJSON, `RemoteMessage.swift`):
  - state fetch and pushed `stateChanged`
  - `native.startup-dialogs.v1` is advertised by both peers. Opted-in clients can answer
    startup questions without replacing history or releasing sends; older clients get an
    update-required error rather than a partial snapshot they would mistake for empty history.
  - `native.preview.v1`, listed by a client: a `snapshot` for an agent whose pi is not running
    is answered from pi's saved session file (`NativeThreadSnapshot.preview == true`, no
    `supportedActions`, a `generation` no request can name) without starting pi; a client that
    reads many threads at once (a Home screen) then starts no pi per idle agent. Any other
    request (send, abort, images…) starts pi as before, whose own snapshot replaces the preview.
    A client that does not list it has every request start pi.
  - `native.revisions.v1`: `nativeThreadSubscribe` replaces a connection's watch set (at most
    64 visible ordinary agents; empty unsubscribes). `nativeThreadChanged(agentID:)` is a
    coalesced invalidation, at most one per watched agent per 250 ms batch, never a snapshot
    or permission to send. It starts no pi. Reconnect starts unsubscribed; clients retain
    fallback polling and fence pulls by their connection/session epochs.
  - `native.fleetDigest.v1`: `fleetDigest` quietly derives the same Home metadata as a snapshot,
    with no conversation messages on the wire. Matching live session/generation and revision
    use the RPC unchanged path without deriving a snapshot. Previews always return a digest:
    their revision zero is not a file-content identity. Four concurrent reads and 64 requests/second per connection;
    replies cap at 32 KiB. Oversized questions are refused (`too_large`), not truncated: use the
    ordinary snapshot fallback. Missing capability likewise uses snapshots. Idle reads use
    previews and never launch pi; private Project coordinators are excluded.
  - native thread requests, with the context and Compact now behind `native.context.v1`, Retry
    in place behind `native.retry.v1`, and Steer now (a message that stops pi and goes at once,
    `interrupt` in `supportedActions`, sent as a steer to a host without it) behind
    `native.interrupt.v1` (Return queues, `followUp`, and no client offers a steer as a choice;
    `NativeThreadDelivery.steer` stays on the wire for older clients and that fallback), and an
    agent's service tier (`setServiceTier`, the snapshot's
    `serviceTier` and `serviceTiers`; no Speed control from a host without it) behind
    `native.serviceTier.v1`, and the images pi saved in a thread (the snapshot names each, bounded
    metadata only; `NativeThreadRequest.image` returns it in 256 KiB pieces, from pi's own history for
    that agent and session) behind `native.images.v1`
  - queued-message subagents behind `native.queueSubagent.v1` and `queueSubagent` in the snapshot
    actions: `NativeQueueAction.subagent(id:)` starts a child without prompting the parent. Both
    clients hide the action on older hosts. Startup requests allow 65 s for the host acknowledgement.
  - conversation goals behind `native.goal.v1`: optional snapshot `goal`, live-only fleet
    `goalState`, and `NativeThreadRequest.goal` for set, edit, pause, resume, clear and confirm.
    Pause/Resume/Confirm require the displayed goal ID, revision and state in addition to the
    session generation. Controller transitions increment that revision; accounting updates do
    not. Optional `checkedBy`, `confirmationRequired`, `confirmedByUser`, `checkCount` and
    `runningSince` decode absent on older hosts. The interval start is epoch milliseconds;
    clients update only the pill clock locally. Set/Edit carry only condition text; goals have no
    time/token caps and legacy budget fields are ignored. Confirm is user attestation, not independent verification. A host without
    the capability hides these controls but keeps ordinary chat. Stop and Steer now pause the
    goal before aborting pi, never resuming the goal for the replacement turn
  - `experiments.goals.v1` supports `HostSettings.goalsEnabled` and its change, default false.
    Settings > Experiments switches each host live; off pauses/cancels goal work and hides its
    controls without restarting agents, clearing saved goals or aborting in-flight tools.
    On leaves preserved goals Paused until explicit Resume. Missing/null settings default off.
  - `experiments.projects.v1` supports `HostSettings.projectsEnabled` and `.projectsEnabled(Bool)`,
    default false for missing/null older payloads. The shared Mac/iOS settings client sends changes
    only to capable hosts. Capabilities describe protocol support, not current opt-in: disabled
    hosts refuse new Project requests with “Enable Projects in Settings > Experiments.” Each owner
    and executor enforces its own switch; OFF retains saved state and uses Pause/stop rather than
    deletion. Executor snapshot/publication proof reads, Pause and Cancel remain served while OFF
    for reconciliation. ON never resumes work. Legacy Space/folder project tools remain available.
  - attach, detach, input, resize, and acknowledged paste
  - terminal open and close (`openPane`, `closePane`)
  - a thread's Files (`files.v1`, offered only to a client that lists it in `hello`; both clients do):
    `RemoteAgentQuery.files(path:showHidden:)` lists a folder and `.fileRead(path:)` reads a file,
    each relative to the thread's own folder on the host (its layout's cwd, else its space), answered
    by the server itself off its queue, only for an agent the client is sent. Paths are
    relative (no leading `/` or `~`, no `.` or `..`); every component must stay inside the folder,
    and a symlinked folder that resolves to one above it is refused; the open descriptor is checked
    again (`ThreadFileSystem`, shared with the Mac's local Files pane). A listing scans at most
    10,000 entries and replies with at most 2,000 (`ThreadFilesLimits`, `truncated` past them),
    folders first, each with its kind and size; hidden entries only when asked. A read is UTF-8 text
    of at most 256 KiB, one reply. Errors: `invalid_path`, `outside_root`, `not_found`,
    `not_directory`, `special_file`, `too_large`, `binary`, `read_failed`, and `unsupported` for a
    client that did not list it. No added/modified marks. A client of an older host says Files needs
    a newer Shepherd there. Behind `files.write.v1` (host capability; served only to a client offered
    `files.v1`), `.fileWrite(path:text:expected:)` saves an existing UTF-8 file in place, both texts
    at most 256 KiB, only while the file still holds `expected` (the text the client edited from):
    answered `.fileWrite(.saved)`, `.changed(text)` with the host's text and nothing written (the
    Mac editor's conflict), or `.failed(message)`. It never creates a file. A client of a host
    without it keeps Files read-only
  - `listDir`, `listModels`, `addSpace`, and `createAgent` with `creationOptions` (and the
    opening prompt's images behind `agent.create.images.v1`)
  - `creationBranches(spaceID:)`, behind `agent.creation.branches.v1`: a space's branches for a
    new worktree's base before any agent exists, answered `agentResult(.changesBranches)`
  - chunked uploads (32 MiB per file)
  - `agentAction.move(spaceID:)`, behind `agent.move.v1`, moves an inactive ordinary thread
    between registered spaces on the owning host. The host applies the same idle/worktree
    checks and conversation-preserving operation as local drag-and-drop and `agent_move`.
    The shared Mac/iOS client checks the capability before sending; older hosts refuse it.
    State broadcasts carry the updated agent space, tab space and thread cwd. This does not
    transfer a thread between hosts. The Mac adds controls; the iOS layout is unchanged.
  - `agentAction.markSeen(upTo:)`, behind `agent.seen.v1`: the host names each completion
    (`Agent.completedAt`, set on every move to done and when a done thread's last child settles,
    always past the one before) and keeps the latest one a person opened (`Agent.seenCompletedAt`,
    persisted, never lowered). Every client's Done lists a finished thread only while the two
    differ, and reports the completion it showed when the person leaves it or presses Mark all
    seen. The Mac sends it to its host over `host.sock`. Clients of an older host (no `completedAt`) keep their own per-device Done.
  - `agentAction.mutePushes(_:)`, behind `push.mute.v1`: the host keeps the thread's mute
    (`Agent.pushMuted`, persisted, written only when true) and sends no push for a muted thread to
    any phone. The Mac's thread options menu and the iPhone's row menu send it; an older host
    offers neither.
  - `agentQuery`/`agentAction`: rename, delete, reorder, review, subagents, search, worktree
    info/delete, `terminals` (what each terminal runs; answered by the
    server itself, `terminal.activity.v1`), and commit from review (`commitInfo`,
    `commitMessage`, `commit` behind `review.commit.v1`; the commit is an operation polled with
    `worktreeStatus`), and the Changes pane (`changesOverview`, `changesList`, `changesFile`,
    `changesBranches`, `changesPatch`, `changesUndoTurn`, `changesRedoTurn` behind `changes.v1`,
    answered by the server itself; thread snapshots carry `turnChanges`; `changesRevertFile`
    behind `changes.revert.v1` reverts one file of an uncommitted list to HEAD, refused when the
    file changed since the list's revision, the working tree only, as Undo; a read's `cwd`, behind
    `changes.cwd.v1`, reviews the repository the agent's `review_diff` asked for, kept in the
    agent's state across a host restart, refused for any other folder than that and the agent's own). Older hosts review the
    working tree only (`review`). The terminal panel's own actions on an agent's terminals
    ride `agentAction` behind `terminal.control.v1`: `renameTerminal` (Rename tab) and
    `killTerminalProcess` (Kill process), each refused on the agent's thread. An older
    client's `typeInTerminal` (Run in terminal, since removed) is answered `unsupported`.
    `startTerminal(paneID:)`, behind `terminal.start.v1`, demands only the selected auxiliary
    terminal, without selecting its host thread or starting siblings. Clients demand on activation
    even with a persisted session ID (it may predate a host restart); repeated demand is idempotent.
    Primary, review, deleted and foreign panes are refused. Hidden views and `terminals` activity
    polls never demand processes; clients of older hosts keep the existing attach-only path.
    `readCheckout`, behind `checkout.read.v1`, has the host read the thread's branch and changed
    files again after a change no state carries (a file saved in the app's Files tab, a branch
    card git action); this Mac's `focusThread` does the same for the thread it shows, as do the
    host's own review loads and commits from review. The `pullRequest` agent query, behind
    `pullrequest.link.v1`, has the host look the thread's branch's pull request up again and
    answers it (the side pane's Pull request tab).
  - **Terminal compatibility** (no wire or capability change): a current client's +, ⌘D and ⌘J send the same `openPane` they
    always did, naming the thread as `relativeTo` (axis horizontal, `TerminalPanel.newTabAnchor`).
    A current host ignores `axis` and `relativeTo` and opens a new tab in the thread's folder (or
    the request's `cwd`), answering `paneOpened`; there is no split request anywhere. So an older
    client's Split right or down opens a tab and it then sees the flattened layout; its
    `resizePaneSplit` is answered `unsupported` ("Terminals are tabs and have no splits to
    resize.") without reaching the pane handler, and the connection stays; `closePane` of the
    thread still answers `not_closable`. A current client never offers Split: against an older
    host its `openPane` naming the thread splits the thread there, which is a new tab, and it
    draws that host's split tabs as one tab per terminal (`TerminalPanel.tabs`); a host without
    `pane.control.v1` fails the request `unsupported` and the client beeps
  - `automation` (`automations.v1`): switch on or off, run now, stop, the runs the host kept,
    create, edit, delete. A manual automation that is on starts a run when Shepherd launches on
    the host. With `automationTriggers.v1` a draft also carries `settings` (trigger, destination,
    workspace, author gate, limits, pins; a nil field keeps the host's value, so an older client's
    edit never clears a trigger), runs carry their trigger, PR link, unread dot and failure, and
    the request adds `status`, `pause`, `resume`, `runEvent`, `dismissEvent`, `markRead`,
    `setAllPaused` and (local clients only) `setRunPullRequest`. The Mac shows a host's
    automations under its sidebar section; the iOS client in Automations. A host without the
    capability shows them read-only
  - `forge` (`issuesAndPRs.v1`, `RemoteForgeRequest`, answered `forgeResult` or an error whose
    code is a `ForgeError.Code`): Issues & PRs through the host's own gh, the same answers the Mac
    gets from its host (`SessionServer.forge`). Reads: the repositories the host knows (its spaces' and
    threads' checkouts with a GitHub `origin`), a repository's pull request or issue sections
    (Needs my team's review and Closed only when asked), a search, a pull request (reviewers,
    checks, activity, blockers, merge methods, the thread whose branch is its head), its diff
    (`DiffFile`, cut to `ChangesLimits`), an issue, a failing job's log tail, and the sidebar
    (pins and the Needs you count). Changes: comment, review, merge, delete a merged branch,
    draft or ready, close or reopen, title, re-run failed jobs, pin. Reads are reused for 60 s and
    nothing polls; every command is bounded to 15 s. Pins are the host's (`forge-pins.json`).
    Everything from GitHub is untrusted text; `ForgeBriefs` fences it for the agent prompts.
    With `issuesAndPRs.browse.v1` a list's repository may be `ForgeList.allRepos` (`""`: GitHub's
    search for what involves the viewer), and the host also serves `browse` (a `ForgeFilter` as
    GitHub search qualifiers, 30 rows a page, `ForgeList.next` the cursor), `people` (a
    repository's labels and assignable logins), `createIssue` (answered `created`), `edit`
    (labels, assignees, reviewers) and `postReview` (a review with line comments). A client
    sends none of them to a host without it
  - `instructions` (`instructions.v1`): Settings ▸ Instructions' files on the host (fetch, save,
    restore a saved version), answered with the files and their history. The Mac's page syncs
    them to every host, or edits one host at a time
  - `suggestions` (`suggestions.v1`): Settings ▸ Experiments ▸ Suggested instructions on the host
    (fetch, configure, add as edited and retargeted, add all, dismiss, undo), answered with the
    experiment's settings and its lines
  - `pushRegistration` / `pushUnregister` (`push.notifications.v1`): an opted-in mobile client
    registers or removes a relay destination over the authenticated connection, answered with `ok`.
    Registration carries only its opaque ID and scoped send credential. The APNs device token
    and revocation credential stay with the phone and relay. Alerts include the current thread title
    and a short final reply, error, or explicit question preview by default, with generic text when
    unavailable. The relay receives optional `title` (100 Unicode scalars) and `preview` (240),
    whitespace-normalized and credential-redacted before truncation; redaction cannot detect every
    secret. Thinking and tool logs are not preview sources. It also receives `group` (the APNs thread-id:
    `mission:<id>` for a mission's planner and stations, else `thread:<agentID>`), `subtitle` (60),
    `level` (`passive` for finished work, else `active`) and `relevance` (the Scheduled Summary
    rank); a relay that answers 400 to them gets the same event without them, and only the old
    fields until the host restarts. A registration may carry `preferences` (Settings ▸ Notifications
    on the phone: which topics, away-only, and a level per mission); the host sends that phone only
    what they allow, and an older phone's registration without them gets everything. Hosts without this capability cannot register destinations.
  - `hostSettings` (`hostSettings.v1`): what the host's Settings ▸ Agents, Worktrees and Pi set,
    the pi packages its pi loads, and its Shepherd and pi versions; one change per request
    (`HostSettingChange`), applied as the Mac's own Settings would. `hostSettings.agentDefaults.v1`
    adds the speed for new threads and Compact at (missing from an older host: Standard, pi's
    default); `HostSettingChange.capability` names what a change needs, and an older host refuses
    the change as unknown. `hostSettings.textGenerationModel.v1` takes the text generation
    model's change, which replaced the session naming model's: a host still applies an older
    client's `namingModel` change to the same setting, and no client offers the picker to a host
    without the capability. `hostSettings.visionModel.v1` likewise takes the image reading
    model's change. A `models` reply may also carry `withoutImages`, the models whose catalog
    input kinds lack images (absent from a host that does not say: every model is then offered
    where an image-capable one is picked).
    `hostSettings.v2` adds Subagent defaults, Deleting a worktree agent, Skills in the / menu, a
    repo's `.mcp.json`, and the slash commands with their switches (missing from an older host:
    the Mac's defaults). `experiments.designTool.v1` switches the Design tool; it is offered while
    the tool is off (it is not one of `designCapabilities`), and turning it on re-offers
    `designs.v1` with `capabilitiesChanged`. `experiments.missions.v1` switches Missions;
    `HostSettings.missionsActive` says a mission is planning, running or publishing, and the host
    refuses Missions off then (`settings_failed`), as the Mac's own card does. The bundled
    extension list gains `designReferences`. `hostSettings.closeOnMerge.v1` adds Close threads
    when their pull request merges (missing from an older host: off).
  - `hostInventory` (`hostInventory.v1`): read-only, what the host's Settings ▸ MCP, Subagents and
    Sign-in show (`RemoteHostInventoryRequest`: `mcp`, `subagents`, `subagent(file:)`,
    `providers`), answered by the host through `HostStores`. A sign-in column in words that name no machine ("Not
    signed in", "Expired"; an older host's "Sign in on the Mac" reads as the state alone),
    a key's variable name but never its mask, account counts (with `hostConfig.v1`, each saved
    account's opaque id and name), never a credential; nothing here changes the host. With
    `hostConfig.v1` it adds each server's exposure, tool names, allowed tools and OAuth state, and
    each profile's fingerprint.
  - `hostConfig` (`hostConfig.v1`, `RemoteHostConfigRequest`): changes what `hostInventory`
    reads, answered by the host through the stores Settings uses (`HostStores`). MCP: read one entry's
    JSON (references such as `${keychain:…}` and `${VAR}` stay as written; any other env or header
    value is masked as `••••••••`, and a save that carries the mask back keeps the host's value),
    save (add, or edit with `replacing`;
    `secrets` go to the host's Keychain and the file gets references), on/off, exposure, tools,
    remove, import, check again, sign in and out. Subagent profiles: save, delete and restore
    defaults, each fenced by the fingerprint the client read. Providers: save an API key (checked
    with the provider first; `$NAME` names a login-shell variable), sign out, an account sign-in,
    and the saved accounts (`providerAccount`: use, rename, remove, rotate, add another account, or `addKey` another
    key beside the saved one, as the host's own Add account does; their
    ids are opaque and `HostProviderStatus.accountList` lists them once there are two). A sign-in (`mcpSignIn`, `providerSignIn`) runs on the host and answers
    `HostSignInProgress`: the page to open on the client, a device code, or that the host waits
    for `signIn(.complete)` with the code the page shows (a provider's pasted-code flow; nothing
    opens on the host) or, for an MCP server, the loopback address the browser ended on, which the
    host relays only when it matches pi's `redirect_uri` and `state`. The host runs pi's own
    login through its `openUrl` option (`Extensions/shepherd-mcp-login.mjs`), so nothing opens
    in the host's browser; the host's own Sign in still opens it. At most four run at once and
    each is gone 330 seconds after it starts. A reply never carries a secret; a client that lacks
    the capability refuses before sending. The additive
    `goalCrossProviderEvaluation` is legacy: false when missing/null, always false from current
    hosts, and its change is ignored. Both clients disclose that scope
  - `projects.mcp.v1`: adds credential status, login/logout, poll, callback completion and
    cancellation to space requests. The host resolves the allowlisted space entry and
    owns the bounded OAuth bridge. A run UUID is scoped to the connection, directory and file;
    only status, signed-in server names and the pending authorization URL reach the viewer.
    The callback URL returns over the existing connection, never access/refresh tokens.
    Disconnect cancels pending requests and runs; reconnect never resumes them. Both clients
    share the codec/capability gate; the Mac Spaces page offers the sign-in sheet.
  - `projects.trust.v1`: no longer offered. Spaces need no approval; current hosts answer an
    older client's `approveProject` and report `projectTrusted: true` in credential status, so an
    older client never draws a space as blocked.
  - `projects.details.v1`: adds host-local metadata/context and editor opening to spaces.
    Clients gate context/open requests separately; older `projects.v1` hosts still edit files.
  - `projects.resources.v1`: adds `resources` (a space's skills, prompt templates, subagents and
    extensions with the host's global ones, by name and description), `delete` (one space
    resource file, only while it holds the text the client read) and `installSkills` (copies
    skills from a repository into the space's `.pi/skills` on the host). `save` also takes those
    resource paths. Both clients refuse these before sending to a host without the capability.
  - `projects.inheritance.resources.v1`: a child space also inherits its parent's slash commands
    (through `shepherd-mcp-parent.ts`) and extensions (`-e` at launch), and `inheritance` records
    `prompts` and `extensions` it turns off. The client refuses those lists to an older host.
  - `projects.parent.v1`: adds `organize`, which sets a registered space's parent space on the
    same host and its name (`editProject`), and answers the listing's first page. Add space and the
    space's Settings use it; with an older host the parent picker is disabled and says why.
  - `logicalProjects` (`logicalProjects.v1`): NEW logical `Project` records on the owner,
    separate from `projects` below. `LogicalProjectsRequest`/`LogicalProjectsResult` serve list,
    get, idempotent create with atomic initial owner-local Space links, revision-checked edit,
    settings, pause/resume, memory add/forget, link/unlink and delete. Both Mac and iOS use
    `RemoteHostClient.logicalProjects(_:)` and shared state decoding; `ShepherdState.projects`
    defaults empty on older hosts. The listener advertises this only while the owner service
    is started and refuses when not offered; the client gates before sending. Success broadcasts
    ordinary `stateChanged`; configuration creation alone starts no coordinator. Runtime
    coordinators remain absent from ordinary fleet snapshots.
    The capability promises persisted configuration, not dispatch, host transfer or remote-host
    Space validation. Delete retains the project directory and all ordinary threads and worktrees.
    Existing `projects.v1` and
    `Project*` directory configuration remain wire-compatible.
  - `logicalProjects.conversationThinking.v1`: the owner keeps `settings.conversationThinking`, the
    coordinator's reasoning level, applies it with the conversation model at launch and before each
    delivered message, and keeps it when a settings edit omits it. Advertised with `logicalProjects.v1`.
    A client offers the Project's own reasoning choice only to an owner with it; an older owner would
    drop the field.
  - `logicalProjectRuntime` (`logicalProjectRuntime.v1`): authenticated Project-capable viewers
    call the OWNER VM/controller, never their own local runtime. `ProjectRuntimeTransport` has
    revision-checked `action`, native `conversation`, original-fence worker `answer`, and `hosts`
    (owner-configured connected host names/bindings). Replies use `ProjectRuntimeResult`.
    Both codec arms and `RemoteHostClient.projectRuntime(_:)` are shared with iOS. The host offers
    it only when an owner launcher and controller callback are installed. Legacy native requests
    cannot discover a private coordinator; capable clients can read it explicitly. Raw native
    sends/retry/queue/compaction still cannot bypass Project admission. This is remote VIEWER
    routing, not worker placement on a different executor.
  - `projects` (`projects.v2`; older hosts use `projects.v1`): host-owned space history,
    inventory, reads and conflict-checked saves. V1 inventories native `.pi` configuration;
    v2 inventories `.shepherd`. Current hosts advertise only v2 and require v2 in the client's
    authenticated hello before any project request reaches file access, migration or approval.
    A legacy client gets `update_required`, including an editor already open; other remote
    features remain available. Current clients advertise v2 and accept either host version,
    preserving the inventoried path and native MCP format. No filesystem aliases are created.
    Only allowlisted space files are writable, never host-global configuration. The Mac
    Spaces page checks the host capability and connected identity before requests. Mac and
    iOS share negotiation/codecs through `ShepherdRemote`; only the Mac exposes a Spaces
    editor. Request/result shapes and protocol version 1 are unchanged.
  - `skills` (`skills.v1`): Settings ▸ Skills on the host (fetch, look up a repository, install
    from one or from files, on or off, how it's used, remove and restore, check for updates,
    Update automatically), answered with the host's skills or the repository's, and beside them
    the skills its pi loads from elsewhere (`SkillsSnapshot.pi`, `skills.pi.v1`, read-only). The
    server runs them on its own queue (they fetch with git) and tells the host's page about each
    change
  - `hooks` (`hooks.v1`): Settings › Hooks on the host (fetch, a hook's off switch by hash, a
    reader, Save, Delete, Test), answered with the host's `HookCatalogSnapshot` (its sources with
    state, entries, off switches, readers and home) or a test's `HookTestResult`. Save and Delete
    name a hook by slot and the hash the client read; a hook changed since is refused
    (`hook_changed`). Save writes only one of the catalog's JSON files (`not_a_hooks_file`), Test
    runs only in the home folder or one of its spaces (`no_such_space`), bounded by the hook's
    time limit, with its stdout, stderr and whether each was cut at 64 KiB (absent fields decode as
    empty and uncut). Files and tests run off the server queue; changes tell the Mac's Hooks page.
    The iPhone and iPad hide the page on older hosts; the Mac's Settings › Hooks shows a remote
    host through the host picker and asks an older host to update
  - `apps` (`apps.v1`, `RemoteAppsRequest`): a space's apps (its `.shepherd/apps.json`, then the
    host's `~/.shepherd/apps.json`), each with its run (`RemoteAppRun`: starting, running with its
    port, exited with its code, or failed with why). `run` starts one as the Mac's Run does (a
    space's app in the named thread's folder, else the space's), `stop` sends SIGTERM to its group
    and SIGKILL after a grace period; each answers the list as it is afterwards. A hidden or missing
    space is `no_such_space`, an unknown app `no_such_app`, a refused start `start_failed`. The
    server answers itself (`AppTools.remote`, `AppProcesses`). The iPhone and iPad thread header's
    Run reads the list while the thread is on screen; older hosts show no Run. `apps.v2` is how
    this Mac's app runs Settings › Apps on its host, the one owner of app processes: `run` and
    `stop` with no space act on This Mac's app, `restart` runs an ended one again (same command and
    folder), `output` answers its last lines, `processes` every run (each `RemoteAppRun` then
    carries its command, folder and output revision); a local client that lists `apps.v2` is
    pushed `appsChanged` with every run when it connects and when one changes
  - `design` (`designs.v1`, offered only while the host's Design tool experiment is on): its
    designs and systems, a design's index with every project file's hash, changed files only
    (inline up to 256 KiB, larger ones and uploads in resumable pieces), comments and the
    canvas's writes through the host's own mutations, Delete with its Undo (`design.delete.v1`),
    a fresh design agent (`design.agent.v1`), Duplicate and Remove from Recents
    (`design.lifecycle.v1`), its systems' files and their Rename, Duplicate, Delete and Re-sync
    (`design.systems.v1`, with a pushed `designSystemsChanged` to a client that lists it, and
    "Build one from a repo" in a host's space), references to the host's own designs in its
    threads (`design.references.v1`), adding or discarding the boards those threads drew
    (`design.boards.v1`), a Claude Design ZIP uploaded to import (`design.import.v1`), the notes
    threads left on a design (`design.threadNotes.v1`), a design's Git sharing and Open from Git
    (`design.git.v1`), and a pushed `designChanged` for the designs a client watches
    (`capabilitiesChanged` when the experiment turns on or off). This Mac's own app alone may
    import from a path on the shared disk (`importPrepare`, `importConfirm`, `importDiscard`) and
    read the whole @ picker catalog (`mentionCatalog`); it alone gets `designNotesChanged`,
    `designGitChanged` and its import's `designImportProgress` pushes.
    Answered by the server itself; boards render on the client
  - `mission` (`missions.v1`, offered only while the host's Missions experiment is on and its app
    drives missions, and only to a client that lists it in `hello`): `RemoteMissionRequest` lists
    summaries (each names the agents the mission owns, so clients keep those threads out of their
    thread lists), reads one record (at most 256 KiB), New mission's options, create, every owner
    action of the Mac's Missions page (`action(missionID:revision:action:)`, refused `stale_mission`
    when the shown revision moved; Pause and Stop of a running mission halt whatever its revision),
    a review's files and fingerprints and one file's `DiffFile`, the Spec Kit reads, and the host's
    templates (`templates`; `create` may name one, and `saveTemplate` saves a finished mission's map;
    the app sends these only to its own host on this Mac). `retryLane(attempts:hint:)`,
    behind `missions.retryLane.v1`, is a blocked push's Retry with hint: the stuck lane
    (`Mission.stuck`, as the push's `detail.stuck` shows it) gets one attempt past its retry limit
    with the hint in its prompts, and the mission resumes; `attempts` is the stuck count the push
    showed, and a lane that moved since is refused `stale_mission`. Answered
    by the host's own `MissionController` (reads by the server), with the same guards as its page:
    Publish carries the run's `reviewFingerprint` and Spec Kit consent the preflight's
    `consentFingerprint` the client showed, and the host checks both again. A host with
    `missions.train.v1` also serves a published mission's merge train (`MissionRun.train` in the
    record, `pauseTrain` and `resumeTrain`); the iPhone and iPad show the train only there. Missions never ride
    `stateChanged` (still `withoutMissions`), except to this Mac's app showing the host's threads as
    its own (`local.threads.v1`), which is sent the whole workspace (missions, Project coordinators
    and executions); a capable client gets a pushed
    `missionChanged(missionID:revision:)` hint (nil: it went) and pulls. What running agents say
    (`RemoteMissionLive`: the planner's or working station's words and each working attempt's, 4 KiB
    each, at most 16) comes with `get` and as a `missionLive` push at most every half second (empty
    once nothing runs). Station threads are read through native-thread snapshots. A mission
    thread's composer is offered (`send` in its actions) while the mission can take words there,
    and its `send`, on this Mac or any client, goes to the owner (`onMissionThreadSend`): while its
    turn works, as the composer chose (`followUp` queued for after the turn in the attempt's own
    session, which settles only after it; `steer` or `interrupt` steered in, accepted once pi
    queued it); while the mission waits on you, the planner's answer (a Spec Kit planning thread's
    to its own repository only); else a failure result saying why; words only. Other requests to it stay
    `mission_control`. A reply past the frame cap is `too_large`. An older client never sees missions
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
    (Start on the host).
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
    bound by `BrowserViewerPolicy`: only the host's own loopback ports and public addresses (SECURITY.md). A claim ends with
    the viewer's tab out of sight for 30 s, its connection, or a newer claim. A client or host without
    the capability keeps PR 3a's two pages.
  - `browser.tabs.v1` extends those browser-drive requests with `tabs`, `newTab`, `selectTab`,
    `closeTab`, and `tab`, a wrapper with a tab ID and one page request. Both hosts and Mac viewers
    advertise it. A host refuses tab-management and targeted requests with `unavailable` when the
    owning viewer does not list it, rather than sending an undecodable push. Legacy untargeted page
    requests still work. The target is thread-local, independent of the user's selected tab, with
    at most eight live tabs and no restart restoration. A remote tab list masks titles and URLs
    of pages outside `BrowserViewerPolicy`.

  - `hostUpdate` (`host.update.v1`, only an installed supported app with its updater bridge):
    `status`, `check`, and `install(offerID:authorized:)`, answered with `HostUpdateStatus`.
    Check is non-destructive; installation requires explicit confirmation of the current offer
    (expires after five minutes), then downloads, verifies with Sparkle's existing signed feed,
    installs and restarts as one operation. There is no remote channel switch or force install.
    A host has no updater: it relays the request to this Mac's app (`appRelay`'s
    `hostUpdate` job; with no app connected, status says to open Shepherd), whose Sparkle asks the
    host before it reserves, restarts or quits (`hostUpdateGate`, local clients only).
    Status exposes version/build/channel/phase/offer/error/canInstall and is explicitly polled,
    including after reconnect; installation is never automatically retried after disconnect.
    The host saves ordinary active turns and native queues using the existing bounded recovery
    checkpoints, before reservation and again before restart. Reservation fences new native sends,
    queue draining and session creation; cancellation releases queued work without pausing it.
    Live Project runs and pending Project deliveries, execution/publication activity, pending
    tool questions, helper work, in-flight delivery and conservatively every live terminal
    session still block installation. Dormant Projects do not block solely because their
    persisted paused flag is false; they remain dormant after restart.
    Status reports the blocking reason. Restart rechecks readiness and checkpoint persistence,
    drains queued remote replies (five-second bound), and bypasses local QuitConfirmation only
    through the same noninteractive readiness and checkpoint recheck.
    Checks time out after 60 seconds; authorized installation after ten minutes. A timeout
    after installer handoff reports an unknown outcome and keeps host admission reserved until
    process exit: Sparkle's consumed choice callback cannot cancel an in-progress installer.
    Pre-handoff cancellation releases admission only when Sparkle finishes abort/cleanup.
    Termination replies and their five-second timeout run in common run-loop modes, not the
    main dispatch queue, which AppKit may not drain during termination. Packages and
    ordinarily privilege-requiring installs are refused by ownership/writability preflight,
    repeated before installation and extraction. External permission changes can still race
    Sparkle's installer and require attention on the host; a timeout reports this, never success.
    Dev/headless/unsupported bundles do not advertise the capability. Ordinary work resumes only
    through its existing bounded, message-free engine recovery; uncertain tool or input delivery
    stays paused for review. Projects, executions, goals, automation runs and design agents do
    not gain automatic restart recovery.

  Capabilities gate newer features. The client falls back (raw bracketed paste) or refuses (terminal
  control) against older hosts. A host answers an authenticated request it cannot decode (a kind
  or action from another version's client) with `unsupported` and keeps the connection; a frame
  with no `id` closes it. Output frames chunk at 256 KiB to stay under the 1 MiB frame cap (16 MiB from the host to a local client).
- **Sizing:** viewports are smallest-viewer-wins. Each attached remote viewer reports its grid,
  and the PTY takes the minimum; with no remote viewers, the local viewport rules. Resize reports
  from unattached clients are ignored.
- **Attach is atomic** on the server queue: viewport registration, snapshot, attachment, and
  replay watermark happen in one turn.
- **Host-side handlers:** remote terminal and agent-creation requests go through
  `onRemotePaneRequest` and `onRemoteCreateAgent` with the same authorization as local requests,
  and host settings through `onRemoteHostSettings` (the host's own `AppSettings`, installed by
  `HostSettingsMapping.serve`). A server without those handlers rejects them. Detaching a remote terminal never kills the host session.
- **Client:** `RemoteHostStore` persists host configs, **including tokens**, in UserDefaults
  (`shepherd.remote.hosts`). It keeps one `RemoteHostClient` per host, with exponential backoff
  capped at 30 s. A refused token or another protocol version is not retried: the host shows
  why and waits for Edit or Reconnect. `RemoteHostFailure` (ShepherdRemote) is the one place
  that reads a failed connect as copy and a retry rule, for the Mac and iOS alike. A client
  reports a failed handshake only through what `connect` throws, never `onDisconnected`.
  Remote hosts are not part of `ShepherdState`. Each Mac host config also persists a `bindingID`
  for durable Project execution references. Changing its address, port or token replaces that
  binding; changing its display name or reconnecting keeps it. Older configs use their existing
  host ID as the initial binding, so loading them needs no migration write. A binding identifies
  a configured destination, not an authenticated machine identity; future dispatch must compare
  the saved binding before using a host connection.
- **Exact Project results:** `logicalProjects.result.v1` gates exact archived-worker snapshot reads (`ProjectRuntimeRequest.worker(taskID:)`, `ProjectExecutionRequest.worker(key:)`) and `ProjectExecutionRequest.result(key:offset:sha256:)` and owner `ProjectRuntimeRequest.result(taskID:operationID:offset:sha256:)`. Result pages use optional compatible fields on the existing reply models, at most 8 KiB of redacted visible final text, total length/digest, next byte offset, availability, stop reason and exact owner/executor identities. Remote reads keep the original host/binding and owner authorization; metadata cache hits cannot bypass revocation. Permission generations are rechecked after asynchronous I/O; disable/re-enable or remove/restore of the exact executor Space/path/binding cannot revive an old grant. Owner-directory and executor-Space tokens track only current eligible routes, scoped by Space ID and path. On the executor, removing, hiding, reserving or replacing the target rotates only its grant; no-op refreshes, renames and unrelated Space additions/updates/removals preserve it. Restoring the target requires a fresh grant, while global Projects-enablement and restart fences still apply. Disabled-executor cancellation, pause and receipt reconciliation keep their existing exemptions, not the new result/worker-content endpoints. Archived worker reads use the exact original task/session and executor binding and are snapshots only. Older peers refuse before transmission, never substitute snapshot text. `history(taskID:beforeSequence:)` is explicit bounded owner-record discovery, not arbitrary native transcript access.
- **Devices need no fleet** (`fleet.devices.v1`, offered whenever the host runs, never to a device): `FleetService` exists for as long as the
  host does and Fleet switches only its **membership** (links, pairing Macs, Join, peer tokens, `fleet.v1`). With Fleet off the host still
  advertises `_shepherd._tcp` while its listener is open, takes devices by `fleetPairDevice`, keeps `devices.json`, and answers the app's
  device actions (Add a device, Revoke, retire the shared token, `enrollApp`); `fleetIdentify` then says `fleetEnabled: false`, and every
  member request (`fleetPair`, `fleetEstablish`, `fleetIntroduce`, `fleetRevoke`, and the Join, pair, remove and adopt actions) is
  refused `fleet_off`. A Mac's own app is a client of another Mac the same way (`RemoteHostStore.pairAsClient`: its own device token,
  `ownToken` in its config), with Fleet on or off. Turning Fleet off ends peer connections only; devices stay connected.
- **Fleet** (`fleet.v1`, offered only while Settings ▸ Experiments ▸ Fleet is on; `experiments.fleet.v1` switches it from a
  client): every host has a `hostID` (`<support>/fleet/identity.json`, made once) that `helloOk` now carries (optional,
  absent from older hosts), and a client that expects an id never sends a token to an address that answers with another.
  Before `hello`, `fleetIdentify` asks who is there and `fleetPair` pairs with a code the other Mac's Join screen shows
  (6 digits, five minutes, five wrong tries close it, kept only as a hash; unauthenticated fleet frames are rate limited).
  Each side hands the other a random token of its own (`FleetPeers`, `peers.json`, kept as a hash on the side that
  checks it), and the listener accepts the shared token or a peer's: the connection records which peer opened it.
  After `hello`, `fleetEstablish` is the same exchange with the shared token standing for the code (a host the app
  already reached becoming a peer), `fleetIntroduce` brings a new Mac to every member, and `fleetRevoke` removes one
  everywhere (a tombstone, so a stale pairing never undoes a newer one). `fleetRead` and `fleetAction` (pair, start and
  stop a join window, remove, hand over legacy hosts) are for this Mac's own app over `host.sock`. The host
  advertises `_shepherd._tcp` (TXT: `v`, a hash of its id, name, build; never the id) while Fleet is on; the app browses
  it for Add a Mac and hands the address to the host. Fleet needs the listener, so it opens it even with Serve this Mac
  off. Shepherd adds no TLS: the fleet runs over the user's own network. A paired Mac the app reached with the shared
  token is marked `fleetManaged` in `RemoteHostStore` (its address and token are the fleet's), keeping its `bindingID`.
  **Devices** (phones, iPads and Macs' apps) are clients: `FleetAccess` is `local`, `member` (a peer Mac), `device` or
  `shared`, and only the first two take part in the fleet's store. A device is offered no capability in
  `RemoteProtocol.fleetMemberCapabilities` (later fleet units add theirs), and every fleet request except the
  pre-hello pairing ones is refused to it with `forbidden`. A device pairs with `fleetPairDevice` (before `hello`, the
  same identify-first rule as `fleetPair`) with the code of Settings ▸ Fleet ▸ Add a device (its own window, not the
  Join one; the QR holds `shepherd-pair://device?code=…&mac=<id hash>`, so a phone aims at the Mac it scanned). The
  device made its token and sends only its hash with its id, name and kind (`FleetDeviceIntroduction`); the host answers
  `fleetDevices` with the other Macs of its fleet, after they have taken the device in (`fleetSyncDevices` over the
  peer links, at most a few seconds) so one pairing works on every Mac. A client already connected on the shared
  token and seeing `fleet.v1` is offered its own the same way (`fleetEnrollDevice`) and stores it before it is used; a
  Mac's app asks its own host (`FleetAction.enrollApp`, local socket) and the host never keeps that token (with Fleet on; a Mac
  that is only a client of another pairs itself, above). `devices.json`
  holds each device's hash and a tombstone for a revoked one, equal on every Mac (a revocation always wins, and a Mac
  that was away hears of it when its link comes up). Revoking (`FleetAction.revokeDevice`, from any Mac) ends the device's
  connections on every Mac and refuses its token; a revoked id can't pair again, so the device makes a new identity
  (`device_revoked`). The iOS client keeps one identity for every Mac in the Keychain and saves each host's token there too;
  `MobileHosts.ownTokenKey` records which hosts are on it.
- **Fleet sync** (`fleet.sync.v1`, offered with `fleet.v1` and so to members only, `FleetSyncWire.swift`): settings and content the Macs hold the
  same, as an append only op log per origin Mac (`<support>/fleet/store/ops-<macID>.ndjson`, mode 0600) plus content
  addressed blobs and per unit history. An op is `{mac, seq, hlc, unit, change, seed?, macName?}`: `seq` counts a Mac's own
  ops from 1 with no gaps, `hlc` is a hybrid logical clock (wall ms, counter), `change` is an inline value (a setting's
  JSON, at most 64 KiB), a blob by SHA-256 (instruction files) or a deletion. A unit is `<kind>:<name>`: slice 2a carries
  `setting:host.<key>` (the host settings in `FleetHostSetting`), `setting:pi.<key>` (an allowlist of pi's `settings.json`
  keys) and `instruction:AGENTS.md` / `instruction:APPEND_SYSTEM.md`; slice 2b-i adds `skill:<name>/<path>` (each file in a skill, a blob; a skill over 2,000 files or 32 MiB stays on its Mac), `skillstate:<name>` (inline JSON `{on, source?, digest?}`: on or off, the repository it came from, a digest of its files), `setting:skills.autoUpdate`, `extension:<path>` (a file under the
  home's `your-extensions/`, a blob; an extension over 10,000 files or 128 MiB stays on its Mac) and `extmeta:<id>`
  (inline JSON `{name, entries?, on, digest?}`: what one extension is, whether it is switched on, a digest of its files).
  A state or meta unit sorts after its files, so its op follows theirs in its origin's log. A skill or extension arrives
  whole: a new skill's files are written where pi does not read (the folder of skills that are off) and the state moves
  the folder in once the files hash to its digest; an extension is listed in `settings.json` only once its files hash to
  the meta's digest, and one that is on is taken out of `settings.json` while a sync rewrites its files and put back when
  they are whole. A unit's mode is not
  carried: a file that starts with `#!` is written runnable. The store holds no machine path: each Mac loads an
  extension from its own `your-extensions/` by its own absolute path in `settings.json`, and an extension someone works on
  in a folder on one Mac (a copy whose source is a folder there) is linked: the folder is watched and each save is
  mirrored into the copy and so becomes ops. Slice 2b-ii adds `mcpServer:<name>` (inline JSON: one server's entry in the
  per Mac `~/.config/mcp/mcp.json`; keys the materializer doesn't own are kept and a hand edit is imported as ops),
  `hook:<id>` (inline JSON, the id derived from what the hook does) with `setting:hooks.readers`, `subagent:<file>` (a
  profile's Markdown) and `space:<id>` (inline JSON `{name, repoKey?, worktreeBase?, …}` with no path: each Mac binds the
  space to a folder of its own with the same `repoKey`, and a space with no folder here stays unbound). None of these is
  multi file, so each applies as it arrives. A kind this build doesn't know is stored, relayed and never applied. The later write wins by (hlc, then the larger Mac id); the loser is kept in `history/<unit>/` (100
  versions or 30 days). An op a person didn't write, copied from what a Mac held when its sync first ran, is a `seed`: any
  other op beats it and among seeds the earliest wins, so the Mac where Fleet was first switched on is the reference.
  Only while Fleet is on (`fleet_off` otherwise, and the sync engine stops with it), and only to a `member` connection (`FleetAccess`: never a client device, never the shared token, never this Mac's own app; refused `forbidden`), after `hello` with a peer's token, one request, `fleetSync`, with
  `FleetSyncRequest`: `hello(vector)` when a link comes up (answered with the receiver's version vector, `{macID: highest
  seq held}`), `ops` and `op` (ops the receiver lacks, in order per origin, batches under 512 KiB; a skipped `seq` is
  stored never and the sender resends from the vector in the answer; every op is validated for shape and size) and
  `blob(hash, offset)` (a blob in 256 KiB chunks, answered `FleetSyncReply.blob`; the fetcher checks the whole against its
  hash). Each Mac pushes what its peers lack over its own outbound link and relays ops verbatim, so a Mac that was asleep
  catches up from any Mac awake. Nothing is applied by the receiver: the materializer writes through the code that owns
  each unit (`InstructionsStore.save`, per key under pi's lock for `settings.json`, the app's own setting setters), keeps
  a hash of what it wrote so its own writes never return as ops, and never writes a blob it doesn't hold. `FleetSnapshot.sync`
  (`FleetSyncStatus`: each peer in sync, catching up or offline, and a one line notice of what the first sync replaced)
  rides `fleetRead` for Settings ▸ Fleet.
  Slice 2c adds sign-ins, units only a Mac of the fleet ever holds (`FleetUnit.isCredential`; the access check above is the whole gate, and a device or the shared token is refused `forbidden` for every request, a credential included): `credential:<provider>` (inline JSON: one provider's entry in pi's `auth.json`, as pi stores it, sorted keys) and `mcpAuth:<key>` (one MCP server's sign-in in `mcp-auth.json`, pi's key `mcp__<name>|<url>`; only an entry with `tokens`, so a sign-in under way is not shared). Each is applied one key at a time under pi's own lock (`PiSettingsFile`), so a provider pi wrote meanwhile is never overwritten, and pi's rewrites (a sign-in, a token refresh, an account switch, a sign-out) are read back by the watcher as ops. There is no sealing, no fleet key and no Keychain: a sign-in that lives only in a Mac's Keychain is not in either file and does not sync, and the op log, blobs and history stay mode 0600 like `auth.json`. Each op of a unit is a new generation of that sign-in, ordered by the clock like any unit. An OAuth refresh token rotates, so before an agent's pi starts the host runs a fence (`FleetSync.catchUpCredentials`): it reads its own sign-ins, sends each connected peer `hello(vector, fresh: true)` (`fresh` is written only when set), the peer reads its own sign-ins before answering and pushes what the asker lacks, and the launch waits until the answer's vector is held and written, at most 3 s (a peer that doesn't catch it up in time is not waited for again for 60 s). With no peer connected, or none ahead, it returns at once. A host keeps a provider (or MCP server) out of the sync with a JSON array of names in `<support>/fleet/credentials-excluded.json` (read at each pass; there is no Settings row for it yet).
- **Fleet pressure and readiness** (`fleet.pressure.v1`, offered with `fleet.v1`): each Mac pushes `fleetPressure` (a
  `FleetPressureSample`: CPU share, core count, total and available memory, thermal state, power, threads working,
  reserved places) every 5 s to the Macs it holds a link to, `fleetReadiness` (a `FleetReadinessReport`: model, chip, the
  programs it lacks, the projects it has folders for) when that changes and daily, and answers `fleetPressureNow` with
  `fleetPressureSample` when a peer needs a fresh reading. Only a connection that authenticated with a peer's token (`FleetAccess.member`; never a device or the shared token) may
  send them, and a sample is filed under that peer, never one it names; the receiver clamps what it keeps and stamps the
  arrival with its own clock, so a sample carries no time and a sender's clock never matters. A host samples (no
  subprocess: `host_statistics`, `host_statistics64`, `ProcessInfo.thermalState`, IOPowerSources) only while Fleet is on and a link to a
  peer is up or its app said `FleetAction.watching(true)` (the Fleet page is on screen; it ends with that connection),
  and pushes `RemoteSettingsPage.fleetPressure` to its app, coalesced, only while one watches. `FleetSnapshot.macs`
  carries this Mac's and each peer's last sample (with its age on the host's clock) and report to the app; a sample older
  than 15 s is stale and counts for nothing. `FleetAction.reconnect(hostID:)` is the Fleet page's Retry. The Send work
  here choice is the host setting `fleet.weight.<hostID>` (`HostSettings.fleetWeights`, `HostSettingChange.fleetWeight`),
  Prefer 1.5, Normal 1, Less often 0.5, Manual only (never picked by Auto). The weights sync like a host setting: one unit `setting:fleet.weight.<hostID>` per Mac (`FleetWeightSetting`, value the weight's name as JSON), applied through the app's own setter, so a choice on one Mac holds on every member.
- **Fleet dispatch** (`fleet.dispatch.v1`, offered with `fleet.v1`, members only like the rest): a thread on one Mac sends work to another. The sending host places it (`FleetPlacement`, pure, over the pressure table and readiness; a named Mac skips scoring, never safety, and a refusal is reported, never rerouted; every decision keeps its `FleetPlacementReason`s), pins the sender's HEAD commit, and sends `fleetDispatchCreate` (`FleetDispatchCreate`: dispatch id, task, repo key, commit, subdirectory, who sent it; idempotent on the id, a second create answers the thread the first started; the sender named in it must be the Mac that authenticated). The receiving host finds the one folder whose `Space.repoKey` matches (`repo_missing`, `repo_ambiguous`), fetches the commit from its own origin (`commit_unreachable`), makes a worktree on `fleet/<slug>` at that commit, and starts a thread there marked `Agent.dispatchedFrom`. A sender with changes origin doesn't have is held `needs_bundle` (slice 4c replaces that). The receiving Mac answers `fleetDispatchAccepted`, then tells the sender about changes with `fleetDispatchChanged` (running, what its thread is doing, how it ended), and when the thread settles sends `fleetDispatchResult` (its last message, at most 32 KB, and the branch's facts: commits ahead, pushed, diffstat). The sender's host hands that to the parent thread as an `AgentMessageDelivery.task` message framed `[from: <title> on <Mac>, an agent, not the user. ...]`, so the result is data, and it works with the app closed; a result for a parent whose pi is away waits (`delivering`) and goes once when it is back. `fleetDispatchControl` (`status`, `cancel`, `message`) acts on a dispatch the receiver runs for the sender; an unknown id answers `unknown_dispatch`. A receiver takes at most 8 running dispatches (`waitingRoom` otherwise, the sender decides again) and reserves a place for 60 s. Everything is enforced by the hosts, never by a prompt: dispatching needs Fleet on and the synced setting `setting:host.fleetThreadsCanSend` (default off, `HostSettings.fleetThreadsCanSend`; `fleet_off`, `send_off`); a dispatched thread, a mission or project worker, a coordinator, a design agent or an automation run is refused (`fleet_scope`), as is every `fleet_*` tool from it; one thread has at most `setting:host.fleetThreadCap` dispatches in flight (default 3, 1 to 10, synced; more are `heldLimit` until one ends). Stop or delete on the parent cancels its dispatches on both ends and nothing is delivered. After a restart the sender's records that hadn't started come back `heldRestart` and are never sent by themselves; running ones are asked about again (`fleetDispatchControl status`), never created again. The agent's side is six deferred tools in `shepherd-panes.ts` (`fleet_hosts`, `fleet_dispatch`, `fleet_read`, `fleet_wait`, `fleet_send`, `fleet_cancel`) over `ExtensionMessage.fleetListHosts`, `fleetDispatch`, `fleetDispatchStatus`, `fleetDispatchMessage`, `fleetDispatchCancel`, answered `ExtensionReply.fleetHosts` and `fleetDispatch` (a refusal is the usual `error` with the code). A tool call's id stands for its dispatch id (stable per thread), so a retried call can't start it twice. `FleetSnapshot.dispatches` carries the sender's records (without task and result text) to the Fleet page's Dispatches log.
- **Fleet manifests and the content index** (`fleet.snapshot.v1`, offered with `fleet.v1`, `FleetSnapshotWire.swift`): while Fleet is on
  and at least one Mac is paired, the host keeps a persisted content index of each space's checkout
  (`<support>/fleet/index/roots/<id>/`: `snapshot.ndjson`, `journal.ndjson`, `meta.json`, mode 0600; never anything inside a
  repository or its `.git`). Each file is held with its SHA-256, git's blob id for the content, size, time, exec bit and git
  class (tracked, untracked, ignored); directories are hashed bottom up (Merkle) so a directory is one hash. Path bound caches
  stay out (Swift `.build`, `DerivedData`, a directory with `pyvenv.cfg` or `CMakeCache.txt`, `target` beside a `Cargo.toml`;
  `FleetExclusions`); `node_modules` and `.env` are indexed. A space's own additions and removals are `FleetExclusions.Overrides` (the
  Settings row and the synced `fleet.snapshotExcludes.<spaceID>` are slice 4c's). The index is kept current by an FSEvents stream
  per checkout, replayed from the saved event id after a restart, and a root is walked again when the stream says events were
  lost, the volume's journal or the exclusion rules changed, or a spot check of a sample of entries (and a rebuilt Merkle tree) finds
  the index wrong. Hashing runs on one serial utility queue per checkout; a file is read again only when its size or time changed,
  and a checkout over 500,000 files is left out (`FleetIndexStatus.Repo.tooLarge`).
  What a Mac holds of a repository is a **manifest**: the 128 bit prefixes of every content hash and directory hash across its
  checkouts of the repository, named by the canonical repo key (`space:<id>` while a space has no origin) and kept with a running
  digest (count and XOR of the prefixes). A Mac pushes `fleetRepoManifest` steps over its own link to each peer, and the peer
  answers `fleetRepoManifestAck`: a `full` set in batches (`part` of `parts`, as of step `seq`), `delta`s (each one `seq` more
  than the last, add and remove batches) and `head`s (where the sender stands, no data, sent as a link comes up). The receiver keeps one copy per peer per
  repository (`<support>/fleet/index/peers/<hostID>/`, so a restarted host knows what its peers hold before any link is up),
  applies a step only if it is the next one of the generation, and checks the digest after each; anything that doesn't line
  up (another generation, a copy that can't reproduce the digest, a malformed or out of order batch) is answered `resend: true`
  and the sender sends the whole set again and checks its own index against the disk. A copy that is behind in the same generation is
  answered with where it stands and the sender sends the deltas between (the last 64 are kept). A 128 bit prefix names a hash; two contents
  sharing one would only make a manifest say "held" for a blob the target lacks, which the target's own hash check repairs (slice 4c).
  Only a `FleetAccess.member` connection sends or is sent them: a client on the shared token or a device with its own token is
  refused `forbidden` (and a device is not offered the capability, see `fleetMemberCapabilities`). `FleetSnapshot.index`
  (`FleetIndexStatus`: per repository its name, files indexed, `ready` once the first scan is done, and `indexing` while any is
  still on it) tells this Mac's app where the first scan stands, and is nil while the index isn't running. Nothing is
  sent, cloned or applied yet: slice 4c carries the blobs.
- **Fleet view for clients** (`fleet.view.v1`, offered to every client while Fleet is on, a device included; not one of
  `fleetMemberCapabilities`): a phone or an iPad reads the Macs, their load and readiness, and chooses where work is sent, and
  does nothing else of the fleet. `fleetRead` from a `device` (or a client on the shared token) is answered with
  `FleetSnapshot.clientView`: this Mac's id and name, each peer's name, link and last seen, and `macs` (samples and readiness
  reports); never an address or port, a code window, the devices, the sync state or the build. `fleetAction(.watching(_))` is
  served to it too (the host samples while the screen is open and stops when the connection closes); every other action, and
  `fleetPressure`, `fleetReadiness`, `fleetPressureNow`, `fleetSync`, pairing, removing and introducing, stay refused with
  `forbidden`. The weight is written with the existing `hostSettings` change `fleetWeight(hostID:weight:)` (capability
  `fleet.view.v1` rather than `fleet.pressure.v1`, so a device can send it); the Mac applies it as its own Settings would and
  the weights sync from there. With Fleet off, `fleetRead` is refused `fleet_off` and the capability isn't offered.
- **Protocol changes** touch the request and reply enums with every Codable arm, `RemoteProtocol`
  capabilities where relevant, server handling, `RemoteHostClient` (Mac and iOS), and the
  round-trip and listener tests.

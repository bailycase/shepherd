# Source map

> Read when you look for where something lives or add a file: every module and source file, in one map.

```text
App/
  ShepherdLauncher.swift   Mac @main shim.   Shepherd.entitlements   iOS/  the iPhone and iPad client
  Engine.entitlements      the pi engine's node (allow-jit)
  Info.plist               names, executable, and feed from build settings
  AppIcon.icon, AppIconNightly.icon   Shepherd's and Shepherd Nightly's icons
Sources/
  ShepherdCore/        Models (Space, Tab, Agent, Automation, Design, ShepherdState), typed IDs, PaneNode
                       (binary layout tree: the thread with its terminals beside it; LeafPane carries
                       sessionID/cwd/agentID), AgentStatus +
                       canTransition, ThinkingLevel, SessionRuntime, AgentMessagePolicy (Settings ▸ Pi ▸ Agent-to-agent
                       messages), StateValidation, Reorder. No deps.
  ShepherdProtocol/    ExtensionMessage/ExtensionReply (+ ChildRun, PaneInfo, …; and
                       ExtensionMessage+Speaker: whose voice each message is), RemoteMessage
                       (RemoteRequest/RemoteReply, RemoteProtocol version + capabilities),
                       NativeThread (requests, results, NativeThreadSnapshot), NativeGoal (goal states,
                       confirmation, evaluator disclosure, interval clock and typed controls), NativeThreadContext
                       (the context and compactions), RPCWire (pi's
                       JSONL, lenient), Framing (NDJSON, LineBuffer, 1 MiB cap), ShepherdPaths,
                       ShepherdEdition (Shepherd or Shepherd Nightly, from the bundle id),
                       BrowserElement (an element picked in the Browser, and the fence it
                       reaches pi in), BrowserRequest/BrowserOutcome (an agent's browser tools on
                       the extension socket; docs/browser.md),
                       Instructions (Settings ▸ Instructions' files, history and requests),
                       Suggestions (Settings ▸ Experiments ▸ Suggested instructions),
                       Skills (Settings ▸ Skills: installed skills, repositories, requests),
                       HostSettings (a host's settings as a client sees and changes them),
                       DiffFile (a diff's files, hunks and lines), Changes (the Changes pane's
                       scopes, lists, turns and base picker on the wire), DiffWords (word diffs),
                       the Design tool's format (docs/designs.md): DesignIndex (canvas.json v3,
                       unknown keys kept), DesignPath (the board path grammar), DesignTemplate
                       and DesignElementID (a board's elements as `File.dc.html#tid:path`),
                       DesignReference (a whole design, board or element handed to a thread: its
                       `shepherd-design-ref://` string, the record and fence pi reads),
                       DesignReferencePayload (the copy a send keeps, its outline, freshness,
                       "Looked at…", the capture the app draws), DesignThreadNote (notes back),
                       and DesignReferenceReading (design_get's words: tokens with sources, changes),
                       DesignBoardCheck (what a board may hold), DesignBoardTree (a board's elements,
                       attributes and tag balance: DesignMarkupScan), DesignBoardSearch (board_search:
                       text, structure and usages over boards), DesignBoardReport (the report after a
                       write, its diff), DesignTokenCheck (the write's tokens modes: warn, snap,
                       strict), DesignImports (what each board's `<dc-import>`s name; DesignUsageIndex:
                       who imports whom, a piece's usage), DesignExtract (board_extract's plan),
                       DesignAgentTools (batch edits, checkpoints, render: requests and results),
                       DesignStyle/DesignTokens/DesignProps
                       (Tweak: inline-style splices at parser offsets, token snapping, data-props
                       and canvas.json's tweaks), DesignCanvasLayout (pages, notes, where a
                       duplicate goes), DesignFiles (snapshots, reads, write results),
                       DesignSystemTokens (a design system's tokens.json in Shepherd's schema or a
                       canvas's own shape, tokens.css, the stylesheet reader, re-sync),
                       DesignSystemFiles (a system's files, record, listing, writes),
                       DesignExport (Export's boards, names, what a ZIP carries, tokens.css),
                       DesignPrint (a board's print mode, a flow document's pages), DesignImport
                       (a Claude Design folder's path rules), DesignImportProject (a project's ZIP
                       read before it is unpacked, links out of it, the import's failures and
                       progress) and DesignLifecycle (a deletion's undo window, the names of copies),
                       BrowserTunnel (the tunnel's frames, credit and chunking arithmetic, and which
                       URLs a tunnel serves), BrowserDrive (an agent on a host driving the page a
                       viewer shows: BrowserDrivePush, BrowserOutcome's coding, the host's
                       BrowserDriveOwners claim rules) and DevServers (a folder's package.json dev
                       servers).
  ShepherdRemote/      RemoteHostClient, NativeThreadStore (@Observable), NativeThreadPresentation,
                       NativeTurnPresentation (a turn's items), NativeGoalRecord (goal lines and
                       display-only diagnostic disclosures), NativeMarkdown (the prose
                       parser: tables, lists, images, details, footnotes), NativeActivity
                       (activity lines, the changes card), NativeQueueRules (the queue's rules,
                       host and client), NativeContextPresentation (the context ring, its
                       details, compaction lines), NativeClipNotice (what a thread says it
                       was shortened: one line per fact the host reported), NativeQuestionDock
                       (a question's kind, what its asker takes, the answer and the dock's keys),
                       TerminalPanel (a layout's terminal tabs, the key row's bytes, the panel's
                       height, RemoteTerminalLink), AutomationPresentation (automation rows, runs
                       and what a client may do), AgentBranchPresentation (the header's branch
                       chip), ChangesPresentation (the send bar, the review message, the "Edited
                       N files" card from a recorded turn), InstructionsText (an instruction
                       file's size, diff, changed lines, highlighting and suggested lines),
                       InstructionsPresentation (its host chips and rows),
                       SuggestionsPresentation (Experiments' words), ClientSettings (the iOS
                       client's Settings models: a host's settings, its instructions and
                       suggestions over the remote protocol), HostSettingsPresentation,
                       ClientSkills (Settings ▸ Skills' model on every platform),
                       DesignSystemPresentation ("synced 4m ago", a token's source), SkillsText
                       (SKILL.md's frontmatter, prompt tokens, repository references),
                       SkillsPresentation (its words), SkillsDirectory (skills.sh),
                       DesignMentions (the composer's @ picker: its rows and search),
                       DesignReferencePresentation (a reference's footer, chip and toast words,
                       and the design_get calls one "Looked at…" line joins), TunnelEndpoint (one end of
                       a Browser tunnel: a socket and both directions' flow control), BrowserTunnelHub
                       (a connection's tunnels, `RemoteHostClient.tunnels`), BrowserPortForwarder (which
                       ports of a remote thread's host are forwarded on this Mac, one owner each),
                       BrowserDriveClaimant (when a viewer claims and lets go of an agent's browser)
                       and BrowserViewerPolicy (where a host's agent may take a viewer's page),
                       ShepherdLog. Shared with the iOS client.
  ShepherdPTYSpawn/    The PTY child side (fork → exec) in C: no Swift runs between the two.
  ShepherdSessions/    SessionServer (state, sessions, extension socket, remote listener),
                       GoalExtension (embedded shepherd-goal.ts; session-persisted bounded continuation
                       and a separate same-model evaluator), RPCSession, RPCThreadState (+Queue: the queue of messages sent while pi
                       works; +Context: what fills the context, compactions; +SnapshotLists: the
                       cards, recorded turns and widgets a snapshot carries, each within its own
                       budget), ThreadOriginStore (where delivered messages came from, kept per pi
                       session), StreamingToolArguments (the fields a tool call being written
                       names, read from pi's argument fragments), BrowserTunnelHost (the host's side
                       of Browser tunnels: loopback connects, caps, idle, one session per remote
                       client; the drive's claims and routing are in SessionServer: a viewer that
                       owns an agent's browser is handed its requests), AutomationRunLog (each automation's runs), PTYSession,
                       SessionScreen (SwiftTerm), StateStore,
                       PaneRequest (terminal/review/automation requests + outcomes), AgentApprovals (the gate's
                       rules, "Allow for this thread"), AgentMessageFraming (the header a recipient reads), RemoteFileUpload,
                       PiEngine (which pi runs; BundledPiEngine, the one the app ships),
                       PiHome (Shepherd's pi home: the launcher, restore-env.sh, its settings),
                       PiCompactionThreshold (Settings ▸ Agents ▸ Compact at, as pi's per-model
                       `compaction.modelOverrides`), ContextToolGroups (what the Context card
                       calls each tool's group; Tests/Extensions/context-tools.json is its audit),
                       YourPi (the user's own pi, read only; YourPiLocator, PiSessionFolder),
                       YourPiFiles (its auth.json, models.json, settings, trust and extensions,
                       parsed as plain files; PiProviders), YourPiImport (the first launch's
                       copy into Shepherd's home, step by step, Re-import, and both sides'
                       survey), PiSignIn (the sign-in bridge: pi's own login over JSON lines;
                       PiSignInScript), PiSignInCatalog (the providers Sign-in offers, a key's
                       mask, how a copy stands against your pi),
                       PiLaunch (every line that starts it), PiSetup
                       (the engine, the home and "your pi", passed in; the startup guards),
                       PiModelCatalog, PiConfig,
                       PiSessionPreview (a thread from pi's session file),
                       InstructionsStore (Settings ▸ Instructions' files and their history),
                       SuggestionsStore (Suggested instructions: settings, waiting, added),
                       SkillsStore (a host's skills in its pi home's skills/; docs/skills.md),
                       SkillsGit (the partial clones skills install from),
                       YourPiImport, YourPiFiles, YourPiResources (the first copy from the
                       user's own pi, Re-import, and their extensions' switches; docs/pi-home.md),
                       Changes/ (ChangesService: the Changes pane's engine — scopes, snapshots,
                       diffs, the base picker, each agent's turns and their Undo; docs/changes.md),
                       DesignStore (each design's files in the support directory's designs/, on
                       its own queue, with a revision per design, each board's last 20
                       versions, its comments.json, its checkpoints, and installed systems under ds/; what an
                       export reads; a Claude Design folder imported; a reference's pinned
                       board copies under pins/ and thread-notes.json; docs/designs.md),
                       DesignReferences (references pinned and resolved, their copies kept,
                       design_get's answers, freshness, the @ picker's catalog),
                       DesignReferencePayloads (the copies, per agent, under design-refs/),
                       DesignSystemStore (design systems in the support directory's
                       design-systems/, their owners and sources, built-ins).
  TerminalSurfaceKit/  Ghostty adapter for terminals; see its NOTES.md.
  DesignSurfaceKit/    The Design tool's board renderer (macOS and iOS; docs/designs.md): DesignSurface
                       (a design's sandbox: a non-persistent data store, the shepherd-design://
                       scheme), DesignBoardView (one board's WKWebView: load, replaceSource,
                       snapshot, events; + DesignBoardExport: a standalone page, @2x image and PDF
                       pages, DesignPDF), DesignSchemeHandler, DesignRoute and DesignSandbox (what
                       is served; the CSP and content rules), DesignRuntime. Resources: Shepherd's
                       board runtime (shepherd-dc-runtime.js), the isolated bridge
                       (shepherd-dc-bridge.js), and React 18.3.1 UMD (MIT, pinned).
  ShepherdApp/         The Mac app:
    ShepherdApp.swift (the Window scene, AppDelegate), RootView (+ WorkspaceHeaderView),
      SidebarView (+ SidebarModel: destinations, Needs you, Pinned, Recents, footer; SidebarPins:
      the pinned threads, ordered, kept and pruned, as plain values, and ShepherdViewModel+SidebarPins:
      Pin, Unpin and where they are offered; SidebarProjectsView and
      SidebarProjectsModel: the tree organized by project), NewThreadPage (+
      NewThreadModel), ThreadHeader, WorkspaceView, WorkspaceSelection (+ MainDestination),
      RightPaneSplit and SidePane (the side pane and its tabs), CheckoutMonitor (each agent's
      branch and changed files, read off the main thread), AppCommands (menus, MenuState),
      AppDialogs (every sheet)
    The side pane's Browser (docs/design/side-pane-browser.md › Side pane: Browser): BrowserHost (the only WebKit
      import: each thread's page, its data store, BrowserPageView), BrowserPane (the tab: toolbar,
      Nothing open, viewport menu, popover, console drawer, BrowserKeys), BrowserModel (pure: the
      address, viewports, dev servers, script messages, the console log), BrowserScripts (the
      page's scripts), ShepherdViewModel+Browser (Start, Add to message, Copy selector, a remote
      viewer's Start on this host), BrowserRemote (a remote thread's page: its host, the ports it
      forwards, the host's dev servers and Start, and its claim on the agent's browser; docs/browser.md
      › Remote).
      The agent's tools on it (docs/browser.md): BrowserAgentRules (pure: the URL policy, take over,
      the card's words, results, keys, the screenshot clamp), BrowserAgentScript (read, click, type
      in Shepherd's content world), BrowserDriver (each tool against the page; no WebKit),
      ShepherdViewModel+BrowserAgent (serves the server's requests, the tab's dot), BrowserExtension
      (the embedded shepherd-browser.ts). A remote thread's agent drives the viewer's page the same
      way: BrowserHostDrive (BrowserOrigin and BrowserHostGuard: what a host's agent may open, read and
      act on, enforced again in BrowserHost's navigation policy) and ShepherdViewModel+BrowserDrive
      (the host's pushes: requests to run, the end of a claim, the hand-back, the dot)
    AppLayout (+Navigation, +Thread, +Agents, +Settings, +Pages, +Designs; ShellLayout's adaptive
      rules live in +Navigation), AgentStateMapping (app lifecycles → AgentState)
    ShepherdViewModel(+Navigation, +Creation, +Workspace, +Spaces, +Palette, +Shell,
      +RightPane, +Review, +ChildInspector, +Automations, +Dialogs, +RemoteActions,
      +RemoteInspection, +RemoteWorktrees, +RemoteAutomations, +Terminal, +HostSettings,
      +Skills, +Pages, +AgentMenu, +Designs (opening, New design's NewDesignState, revisions),
      +DesignSystems (a system's page, "Build one from a repo", Re-sync, specimens),
      +DesignExport (Export, Attach to a thread), +DesignLifecycle (Delete with Undo, Rename…,
      Duplicate, Remove from Recents, Delete design system, Import Claude Design Project…))
    Pages/             the sidebar destinations' pages: AutomationsPage, HostsPage and DesignsPage
                       (views over AutomationsPageModel, HostsPageModel and DesignsPageModel,
                       derived per change), their destinations (PageDestinations: runs read,
                       sheets), AutomationEditorSheet, PageHeader (every page's header, New
                       thread's too)
    The Design tool (Settings ▸ Experiments ▸ Design tool; docs/designs.md): NewDesignPage,
      DesignScreen (a design agent's layout: the canvas beside its chat, and the toolbar),
      DesignScreenModel (a design's canvas state and its pulls; the board actions, moves,
      Present and Play, pages), DesignHost (the only DesignSurfaceKit import: live views, the
      rasterizer, snapshots, thumbnails, tweak previews, the presented board, DesignExporter),
      DesignExportSheet (DZExport's sheet over the window, its model), DesignLifecycle (the menus,
      dialogs and toast of deleting and importing, as values) and DesignLifecycleViews, DesignTweak (the Tweak tab's controls, pure), DesignTweakModel (its writes,
      one per gesture, Reset and Undo), DesignTweakPane, DesignProjectTokens (the
      custom properties a design agent's folder declares), NightWatchSystem (Night Watch as a
      built-in design system, from ShepherdUI's tokens), DesignSystemCatalog (the host's systems
      as last read), DesignSystemPageModel (DZSystem as values; specimen boards), DesignSystemPage
      (the Design systems page, a build's layout beside its chat, the header),
      ShepherdViewModel+DesignReferences (a design piece handed to a thread: pinned, attached,
      "Send vN", sent; the copies it draws) and DesignReferencesExtension;
      +DesignReferencesUI (the thread's chips and picker, Implement in a thread's send, Copy
      reference, "Open in design"), ImplementSheet (the sheet's model and view, the canvas's
      toasts), DesignScreenModel+References (the selection as a reference, the right-click menu,
      notes back), DesignCanvasKeys (the canvas's ⌘↩ and ⇧⌘C), DesignScreenModel+Pieces
      (a shared piece's usage, Go to Source, the Tweak note on a use), DesignRenderImage and
      ShepherdViewModel+DesignRender (board_render: the picture's size caps, the off-screen
      draw served to the agent)
    TerminalPanels (each layout's terminal panel: shown, tab, maximized, activity),
      TerminalPanelLayout (TerminalPanelGeometry, pure), TerminalPanelViews (strip, divider)
    Thread/            ThreadView, ThreadTurns, ThreadTools (activity lines), ThreadMarkdown,
                       Composer, QuestionDock (a question in the composer's place),
                       QueueStack ("Up next", the queue above the composer), GoalCard (goal controls,
                       condition editor, local clock pill and transcript disclosures),
                       ContextMeter (the ring beside Send, its details, compaction lines),
                       ComposerMentions (the @ picker's rules, a pasted reference),
                       ComposerReturnKey (what ↩, ⇧↩, ⌥↩ and ⌘↩ do in the field),
                       DesignReferenceChips (a thread's chips, their preview, "Looked at…"),
                       ThreadTailGuard (a following thread the lazy stack stranded, put back),
                       Subagents, SubagentPresentation, SubagentInspector
    TerminalSessions (TerminalSessionStore), AgentStartQueue (launch order of restored pi),
      TerminalHost (the only TerminalSurfaceKit import),
      NativeThreadStores (+ LegacyTerminalAgents), PaneControl, PaneFocusMemory
    DiffReview (ReviewSession, ChangesEngine, ReviewPaneModel), DiffReviewView (ReviewPane: the
      Changes pane), ChangesRows (split and unified rows, folds), ChangesMenus (scope, commits,
      base and options menus), GitDiff, CodeHighlight (tree-sitter)
    ReviewCommit (ReviewCommitGit, ReviewCommitter), ReviewCommitSheet, +ReviewCommit
    GitWorktree, WorktreeFinalize, ChecklistStatus, NewWorktreeSheet, FinalizeWorktreeSheet,
      NewAgentSheet, RemoteWorktreeSheet, RemoteDirectoryPicker, DialogSheet,
      QuitConfirmation (QuitDialog)
    CommandPalette, CommandPaletteView, PaletteContentSearch, Keybindings (KeybindingsStore)
    SettingsView, SettingsWindow, SettingsComponents, Settings{Appearance, Terminal, Agents,
      Worktrees, Pi, Instructions, Skills, Remote, Keyboard, Advanced, Experiments}, AppSettings,
      InstructionsModel (the Instructions page's files, drafts and sync), InstructionsEditor (its
      NSTextView), SuggestionsModel (the Experiments page's suggestions), SkillsSheets (Browse
      skills.sh, Add from repo), YourPiModel (Settings ▸ Pi ▸ From your pi, and the first launch's
      copy and who waits for it), YourPiText, PiImportSheet (the first launch's Bringing over your
      pi), PiAuthStore (sign-ins: the sign-in sheet's session on the bridge, sign-out, what
      expired), PiSignInSheet, PiAuthRows (Sign-in's rows), SettingsPiSignIn, SettingsPiFromYourPi,
      SettingsPiSlashCommands and SlashCommandsModel (Settings ▸ Pi ▸ Slash commands: the commands pi
      lists, their rows and switches),
      Thread/SlashLogin (/login and /logout), Thread/ThreadAuthNotice (waiting, not signed in)
    Themes (ThemeManager, ShepherdTheme), ShepherdThemeMarker, ShellIntegration, ComponentGallery
    RemoteHostStore, AgentPeers (+ the approval queue), PeerApproval and PeerApprovalDialog (an agent's call
      on another thread, waiting for the user), AgentNotifications, ChildRuns, PiSessionFile (+ adoption from
      your pi), AppUpdater (Sparkle: UpdateChannel, UpdateChannelStore, ChannelDelegate),
      NightlyMovedNotice
    Status/Namer/Panes/Review/Subagents/Children/Inspect/Instructions/Design/MCPExtension.swift
      embedded extensions (DesignExtension also carries the design skill; MCPExtension the client)
    MCP/ (MCPStore, MCPConfigFile, MCPSecretStore, MCPOAuth, MCPProbe, sheets),
      SettingsMCP, ShepherdViewModel+MCP   Settings ▸ MCP servers: the config file, Keychain,
      OAuth, and what agents report; answers the extension's credential requests
  shepherd-cli/        `shepherd --import herdr` (writes state.json while Shepherd is not running).
Packages/
  ShepherdUI/          Night Watch, its own local package (module ShepherdUI; macOS 26, iOS 27;
                       SwiftUI only, imports no Shepherd module):
                       Tokens/       ThemeDefinition, NightWatch, ThemeStore, Colors (NWPalette,
                                     Color.nw), Typography (NWTextStyle, Font.nw, NWFonts,
                                     NWProseSize), Metrics (NW.Space/Radius/Height), Motion,
                                     Elevation (.nwCard/.nwPopover/.nwFocusRing, NWHairline),
                                     AgentState, HexColor, Glyphs (NWGlyph: the SF Symbol and
                                     fill each shared glyph is drawn with)
                       Resources/Fonts  Geist and Geist Mono (SIL OFL)
                       Components/   Controls, Status, Containers, Navigation, Thread, Composer,
                                     Agents, Review, Dialogs, Automations, Skills, Browser
                                     (NWBrowserToolbar, NWBrowserAddressField, NWBrowserEmpty,
                                     NWViewportMenu, NWElementPopover, NWElementChip,
                                     NWConsoleBar, NWConsoleRow, NWAgentRing, NWAgentPointer,
                                     NWAgentCard, NWBrowserAgentOverlay, NWPaneTabTip, NWBrowserNotice), DesignTool
                                     (NWDesignCanvas, NWBoardFrame, NWCanvasToolbar,
                                     NWDesignCard, NWDesignSystemChip, NWDesignHeader,
                                     NWCommentPin, NWCommentThread, NWCommentCard,
                                     NWBoardActions, NWDirectionTile, NWCanvasNote,
                                     NWBoardPresentation, NWSectionRail, NWTokenSwatch,
                                     NWTypeSpecimen, NWComponentSpecimen,
                                     NWDesignSystemBuildTile, NWDesignReferenceChip,
                                     NWDesignReferencePreview, NWThreadNotePin,
                                     NWThreadNoteCard, NWReferenceToast, NWImplementSheet,
                                     NWDesignReferenceSpecimens); Composer's NWMentionPicker and
                                     NWReturnKey (⇧↩ and ⌥↩ add a line in a field whose ↩ submits)
                       Previews/     a #Preview per component, light and dark
                       Diagnostics/  NWRenderProbe (row-body counts for tests; debug only)
                       Its unit tests live in the root package (Tests/ShepherdUIUnitTests).
Extensions/            Canonical pi extensions (TypeScript/ESM, dependency-free):
  shepherd-status.ts      status + active pi session, Retry (/shepherd-retry; docs/native-thread.md › Retry)
  shepherd-goal.ts        /goal and typed controls, bounded continuation and a separate authenticated
                         evaluator; loaded after children; canonical state in pi session entries
  shepherd-namer.ts       agent titles
  shepherd-panes.ts       terminal_* (open/list/run/read/focus/close), agent_*
                          (list/send/spawn/read/steer/interrupt/wait/delete),
                          automation_*, notify; see docs/agent-coordination.md
  shepherd-review.ts      review_diff (readies the side pane's Changes tab)
  shepherd-subagents.ts   setAgentChildren (native + pi-subagents runs)
  shepherd-children.ts (+ -config, -ui, shepherd-workflow, shepherd-missions, shepherd-inspect.mjs)
                          native subagent runtime; see docs/native-subagents.md
  shepherd-instructions.ts  Settings ▸ Instructions' AGENTS.md and APPEND_SYSTEM.md, added to
                          every session Shepherd starts (never ~/.pi/agent); suggest_instruction
                          (Settings ▸ Experiments ▸ Suggested instructions)
  shepherd-design.ts      the design agent's design_read, board_write, board_edit, boards_edit,
                          board_search, board_render, board_extract, checkpoint_create, checkpoint_list,
                          checkpoint_restore, canvas_update, design_check, comment_list, comment_reply,
                          system_read and system_write; hands pi the design skill
                          (design-skill/: SKILL.md, format.md); relays its tools to the agent's
                          native helpers through the children extension; see docs/designs.md
  shepherd-design-refs.ts an ordinary thread's design_get and design_note, registered only once the
                          thread holds a design reference; see docs/designs.md › Design references
  shepherd-mcp.ts         the mcp tool (search, describe, call) and direct <server>_<tool> tools
                          over the servers in Settings ▸ MCP servers; credentials from the app
  shepherd-mcp-client.mjs the dependency-free MCP client (stdio, Streamable HTTP, legacy SSE),
                          also run by the app as `node shepherd-mcp-client.mjs probe`
  shepherd-browser.ts     browser_open, browser_read, browser_click, browser_type, browser_press,
                          browser_scroll, browser_wait, browser_screenshot, browser_console,
                          browser_eval, browser_back, browser_forward and browser_reload, on the
                          thread's own Browser page only; see docs/browser.md
  shepherd-service-tier.ts  adds service_tier to the agent's own provider requests while its thread
                          is on Fast (the Speed control), from the agent's tier file; see
                          docs/service-tier.md
  shepherd-context.ts     keeps the old, bulky parts of a long run (tool output, the contents of
                          written files, reasoning payloads, screenshots) out of what the model is
                          sent, and clips any one huge tool result; the thread keeps everything;
                          see docs/context-budget.md
Tests/
  <Module>UnitTests/, *IntegrationTests/, ShepherdPreviewTests/   the tiers above
  ShepherdTestIsolation/  C, run when a test bundle loads: scratch root, PATH, ZDOTDIR
  ShepherdTestKit/        ScratchDefaults, makeScratchDirectory, Locked, CommandFailure, TestProcess
  ShepherdTestSupport/    ScratchServer, StubPi (+ Resources/stub-pi.py), ExtensionClient,
                          QueueFixture (a host's queue without pi), eventually, recordingErrors,
                          ControlPress (press a control by accessibility label, measure hit
                          areas), LongThreads (every kind of thread row with its longest words,
                          for the layout tests and previews), the time-limit and timing-sensitive traits
  Extensions/             node tests for the bundled extensions (+ native-thread-wire.json);
                          context-harness.mjs (a real pi on a fake provider, launched as the app
                          launches an agent) with context-tools.json (the audit of every tool)
  Designs/                design fixtures: real and synthetic boards, the Shepherd canvas.json,
                          and element-ids.json (WebKit's numbering of each board's elements)
  DesignSurfaceKitIntegrationTests/Fixtures/  a small design (loops, conditionals, an import)
  Release/                Python tests for scripts/release.py and the CI helpers
  ci-suite-times.json     each suite's seconds on a CI runner, which the shards are cut from
  ShepherdIOSChecks/      the iOS client's scripts
scripts/               release.py (the release workflow's rules), sign-app.sh (release
                       signing), sync-embedded-extension.py, context_budget.py (what a thread's
                       first request carries, and its ceilings in context-budget.json),
                       ci_mtimes.py (CI's incremental builds),
                       ci_impact.py (the lane and the fast lane's suites), ci_shards.py (equal
                       shards from Tests/ci-suite-times.json), ci_run_tests.py (a shard under a
                       watchdog, failed tests retried once), ci_testlog.py (test output reader),
                       ci_report.py (the one tracking issue),
                       pi_engine.py + pi-engine-pin.json (stage and verify the pi engine),
                       sign-engine.sh (node, with the engine's entitlements), check_pr_body.py
                       (the pr-body workflow: what a UI or autonomous-feature PR body must say)
Vendor/libghostty-spm/ GhosttyTerminal (prebuilt libghostty)
```

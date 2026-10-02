# Environment variables

> Read when you set, read or debug an environment variable: Shepherd's, pi's, or the test isolation's.

**Environment variables:**

- **`SHEPHERD_SUPPORT_DIR`** moves the support directory: the socket, `state.json`, installed
  extensions, `remote-token`, `automation-runs.json`, Settings ▸ Instructions' files
  (`instructions/`), Settings ▸ Skills' state and git caches (`skills/`), designs (`designs/`;
  docs/designs.md), design systems (`design-systems/`), and subagent artifacts. It wins over the edition's own folder
  (`Shepherd`, or `Shepherd Nightly` in Shepherd Nightly).
- **`SHEPHERD_MCP_CONFIG`** moves the MCP servers file (Settings ▸ MCP servers) away from
  `~/.config/mcp/mcp.json`. Test isolation points it at a scratch file; setting it in the Dev
  scheme keeps Dev's servers apart from the everyday app's.
- **`SHEPHERD_THEME=night-watch-dark|night-watch-light`** forces an appearance at launch (the
  older `shepherd-dark` still means dark), which is handy for screenshots. Resetting settings
  returns to it.
- **Set by the app for pi, never read from the user's environment:**
  - Always: `SHEPHERD_AGENT_ID`, `SHEPHERD_SOCKET`, `SHEPHERD_EXT_STATUS`,
    `SHEPHERD_INSTRUCTIONS_DIR` (where the instructions extension reads Settings ▸ Instructions'
    `AGENTS.md` and `APPEND_SYSTEM.md`).
  - By the launcher (`<support>/pi/bin/pi`), after setting aside every `PI_*`, `JITI_*`, `NODE_*`
    and `OPENSSL_CONF` it was started with under `_SHEPHERD_STASH_<name>` (listed in
    `_SHEPHERD_STASH_NAMES`, and put back for pi's shell commands by `restore-env.sh`):
    `PI_CODING_AGENT_DIR` (Shepherd's home), `PI_PACKAGE_DIR` (the engine's package),
    `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1`, `PI_TELEMETRY=0`, `PI_SUBAGENTS_TEMP_ROOT`, and,
    when the user set no `NODE_EXTRA_CA_CERTS` of their own and the home's keychain export
    (`PiHome.keychainCertificatesFile`, private CAs the Mac's keychain trusts — an internal proxy
    or MCP server's root) isn't empty, `NODE_EXTRA_CA_CERTS` pointing at it (the sign-in bridge,
    which runs the engine's node directly, falls back the same way).
  - With the matching extension on: `SHEPHERD_EXT_PANES`, `SHEPHERD_EXT_BROWSER` (the installed
    `shepherd-browser.ts`, for Settings ▸ Pi ▸ Browser tools; never in a design's agent),
    `SHEPHERD_NATIVE_CHILDREN`,
    `SHEPHERD_EXT_CHILDREN`, and `SHEPHERD_CHILD_*`; `SHEPHERD_EXT_GOAL=1` loads the
    conversation-goal controller after the child controller, even while the experiment is off
    so it can switch live. `SHEPHERD_GOALS_ENABLED` is explicitly `0` by default, `1` only while
    Settings > Experiments > Goals is on. The host's internal configure command updates running
    controllers without restarting pi; off pauses/cancels goal work without aborting tools.
    `SHEPHERD_GOAL_MODELS` is explicitly empty by default, so checks use the thread's exact
    provider/model. Settings > Agents > Allow cross-provider goal checks supplies the
    Haiku/Codex Mini/Gemini Flash preference list only after opt-in. Shepherd overrides an
    inherited value even when consent is off. Policy is captured when an agent starts or
    restarts; changing Settings does not revoke a running process's policy. See [goals](goals.md)
    for evaluator disclosure and redaction. For Settings ▸ Pi ▸ MCP servers, pi's own MCP
    (`-e builtin:mcp`, no variable) and `SHEPHERD_MCP_SECRET_<SERVER>_<NAME>`, one per Keychain
    secret the derived `mcp.json` refers to, with `SHEPHERD_MCP_SECRETS` naming them (docs/mcp.md;
    the launcher keeps them from the model's shell and the servers that don't name them), and `SHEPHERD_EXT_MCP_PROJECT=1` (the installed
    `shepherd-mcp-project.ts`) while Settings ▸ MCP servers ▸ Also use a repo's .mcp.json is on.
  - Per agent: `SHEPHERD_NEEDS_NAME`, `SHEPHERD_AUTOMATION`, `SHEPHERD_MODEL`,
    `SHEPHERD_SUGGEST_FILES` (the files its `suggest_instruction` may draft a line for, while
    Settings ▸ Experiments ▸ Suggested instructions is on for its kind of agent), and, for an
    agent that draws a design, `SHEPHERD_DESIGN_ID` and `SHEPHERD_DESIGN_SKILL_DIR` (the design
    skill the app writes to the support directory's `design-skill/`; docs/designs.md).
    `SHEPHERD_DESIGN_REFS` (`on`, or `granted` for a thread that already holds a design
    reference) loads design_get and design_note in a thread that draws no design, while Settings ▸
    Experiments ▸ Design tool and Settings ▸ Pi ▸ Design references are on (docs/designs.md ›
    Design references).
- **`SHEPHERD_PR_DESCRIPTION_MODEL`** overrides the model that drafts finalize PR bodies.
- **`SHEPHERD_NAMER_MODELS`** (`provider/id,provider/id`; an entry without a slash matches any
  provider) overrides the cheap models the namer tries before the agent's own. The namer reads it
  from the environment pi was started with, so it comes from the user's shell, not from Shepherd.
- **`SHEPHERD_PI_ENGINE`** (Debug builds only: `swift test` and the Dev scheme) names one
  executable that takes pi's arguments, which the launcher then starts instead of the engine the
  app ships (`PiEngine`). The tests point it at a stand-in. Release builds ignore it, and a set
  value is never looked up on PATH.
- **`SHEPHERD_YOUR_PI`** (Debug builds only) names "your pi", the user's own pi folder Shepherd
  reads (adoption, Settings ▸ Skills), instead of the one a login shell finds. The test isolation
  sets it; under `SHEPHERD_PI_ENGINE` without it there is no "your pi" at all.
- **`SHEPHERD_PREVIEW_DIR`**, **`SHEPHERD_LIVE_MODEL`**, and **`SHEPHERD_PERF_REPORT`** switch on
  the preview renders, the live-model run, and the long-list timing report (see Testing).
  **`SHEPHERD_ENGINE_SMOKE`** names a built app (or `.build/pi-engine`) for the engine smoke.
  **`SHEPHERD_BENCHMARK`** switches on the benchmarks that print timings: `ComposerMenuBenchmarkTests`
  (the composer's menus over a full model catalog), `DataPathBenchmarks` (the server's data path),
  and `PiSessionFileTests`' runtime-state check.
- **`SHEPHERD_DESIGN_CANVAS`** points `DesignCanvasFidelityCheck` at a design folder (one holding
  `project/canvas.json`): it renders every board at its canvas size, with Google Fonts, reports
  what each drew, and with `SHEPHERD_PREVIEW_DIR` set writes each snapshot to
  `design-canvas/<board>.png` there, to compare by eye against the canvas's own thumbnails.
  `DesignStyleEditTests` reads it too, to splice every element of every board of that canvas
  (the folder, or its `project/`).
- **`SHEPHERD_TIMING_TESTS=1`** runs the timing-sensitive tests even where `CI=true` skips them
  (see Testing).
- **`PI_CODING_AGENT_DIR`** is pi's own: it moves pi's config and sessions away from
  `~/.pi/agent`. Shepherd never takes its own home from it (a Shepherd started from an agent's
  shell inherits one): its home is always `<support>/pi`. It is how "your pi" is found: a login
  shell with the app's own value removed prints the one the user's startup files set
  (`YourPiLocator`), else `~/.pi/agent`. Terminals blank it, with
  `PI_CODING_AGENT_SESSION_DIR`, `PI_PACKAGE_DIR`, `PI_OFFLINE` and `PI_SUBAGENTS_TEMP_ROOT`, so a
  terminal's pi takes them from the user's startup files only.

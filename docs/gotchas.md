# Gotchas

> Read when something odd happens with sockets, frame sizes, replay, skills, pi's folders, quitting or xcodebuild.

- **Socket paths:** `sun_path` caps Unix socket paths at 104 bytes. Tests build sockets under
  short temporary paths.
- **Frame sizes:** RPC stdout records may be up to 256 MiB (`get_messages` returns a whole
  history in one record), but extension-socket and TCP frames stay capped at 1 MiB.
- **Replay** into a fresh surface is a `SessionScreen.snapshot()`: an ANSI reconstruction (up to
  2000 lines of styled scrollback, the alt screen, cursor, and modes), not raw bytes. Cosmetic
  artifacts are acceptable; lost bytes are not. The watermark protocol prevents duplication and
  loss.
- **Skills live in Shepherd's pi home, `<support>/pi/skills`,** the only folder its pi reads
  skills from: its settings.json filters out pi's own `$HOME/.agents/skills` (`PiHome.install`),
  and the children bridge never lists it. Settings ▸ Skills installs there, and the first copy
  (and Re-import) copies the user's own skills there; everything else Settings ▸ Skills keeps
  (skills that are off, just removed, git caches, records) is in the support directory's
  `skills/`. Nothing of Shepherd's writes `~/.agents/skills` or `~/.pi`.
- **pi's trust prompt:** interactive pi asks to trust project `.pi/` directories, but `-e` loads
  our extensions without one. Never write anything into the user's pi (`~/.pi/agent/`, or
  wherever their `PI_CODING_AGENT_DIR` points), lock folders included: everything Shepherd
  writes for pi is in its own home, `<support>/pi`. `PiSessionFile` writes only session files
  there, which pi treats as data. Settings ▸ Instructions keeps its root files in
  Shepherd's support directory and hands them to the sessions Shepherd starts through
  `shepherd-instructions.ts`; pi run by hand doesn't read them.
- **pi's formats:** `PiConfig` (models.json, settings.json) and `PiModelCatalog`
  (`get_available_models` over one-shot RPC) parse defensively, because pi's formats are not our contract.
- **Binding:** `SessionServer.start()` refuses to bind over a live socket (it probes with a
  connect) and replaces stale socket files. The remote listener reports bind failures rather than
  silently serving nothing.
- **Transcript search** in the palette (and a host's answer to a remote `agentQuery(.search)`)
  reads only the last 512 KB of each agent's pi session, and matches only user and assistant
  text (`PaletteContentSearch`), never the system prompt, tools, or JSON around it.
- **Launching the binary bare** from a terminal starts a background process; the `AppDelegate`
  promotes it to `.regular` and activates it.
- **Quitting** while agents are working or blocked asks first, in `QuitDialog` on the main
  window (reopened if it was closed; its own window if the main one isn't back within a second),
  because it stops them mid-turn. A log out, restart or shut down never waits on it
  (`QuitPolicy`; only loginwindow's quit counts as a power-off).
- **xcodebuild and `Package.resolved`:** a build from a fresh DerivedData resolves packages
  again and rewrites the Xcode project's
  `Shepherd.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` with newer
  versions (Sparkle and SwiftTerm, for example). Pass `-onlyUsePackageVersionsFromResolvedFile`,
  and never commit a bumped `Package.resolved` by accident.

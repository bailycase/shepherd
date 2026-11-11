# Build, run, test

> Read when you build or run the Mac app, change a scheme, or stage the bundled engine.

There is deliberately no Makefile or Taskfile. One Xcode project at the repo root runs the apps,
and plain SwiftPM drives everything else. For package changes, start with
[focused local validation](testing.md#local-validation): `swift test --filter '<suite or test>'`
builds before running. Use `swift build` only for a compile-only check, not before a test run.
Build the app when validating launcher, bundled resources, Xcode configuration or app-only behavior;
a package check and an Xcode build are not both required for every change.

**The Mac app:** open `Shepherd.xcodeproj`, pick a scheme, choose My Mac, and Run. The Mac target
is a shim (`App/ShepherdLauncher.swift` calls `ShepherdMacApp.main()` from the `ShepherdApp`
library, or, given `--host`, the headless session host: Shepherd Nightly's background service
under launchd, else the app's own supervised child). There is no `swift run` path for the GUI.

A stable Shepherd and a development build cannot share state. The socket and `state.json` live
in the support directory, and the server refuses to bind over a live socket. So there are three
Mac schemes:

| Scheme | Config | App | Support directory |
| --- | --- | --- | --- |
| `Shepherd (Dev)` | Debug | Shepherd | `~/Library/Application Support/Shepherd-dev` (the scheme sets `SHEPHERD_SUPPORT_DIR`) |
| `Shepherd (Prod)` | Release | Shepherd | `~/Library/Application Support/Shepherd` |
| `Shepherd (Nightly)` | Nightly | Shepherd Nightly | `~/Library/Application Support/Shepherd Nightly` |

Dev's Run, Profile, and Archive actions all use Debug and its isolated identity. Use the Prod
or Nightly scheme to archive a shipping build. Dev profiling is unoptimized until a separately
isolated optimized configuration is introduced.

⌘R on Dev never disturbs the agents in your everyday copy. The Debug configuration also has its
own bundle id, `com.bailycase.shepherd.dev`, because preferences, delivered notifications and
Sparkle's installer are keyed by bundle id: on a shipped id, every Dev launch would prune the
installed app's collapsed spaces and clear its notifications, and a setting changed in Dev
would change it there. `ShepherdEdition` reads the Dev id as Shepherd, and Debug builds have no
updater. `Tests/Release` holds the Debug id apart from both shipped apps'. `Shepherd iOS` builds
the iPhone and iPad client from `App/iOS`.

**Shepherd Nightly** is the same code built as a second app, so it installs and runs beside
Shepherd. The `Nightly` configuration is Release plus its identity: bundle id
`com.bailycase.shepherd.nightly` (so its own preferences domain), product name
`Shepherd Nightly`, `App/AppIconNightly.icon`, and the `appcast-shepherd-nightly.xml` feed.
Everything else keys off the bundle id through `ShepherdEdition` (`ShepherdProtocol`): the
support directory, the listener's default port (7434 instead of 7433), the window's name, and the
update channel. It starts with an empty support directory; nothing is copied from Shepherd's.
Info.plist takes the executable, the names, and the feed file (`SHEPHERD_APPCAST`) from build
settings, and each configuration compiles only its own icon.

**The background service** (`Shepherd --host` under launchd, [ARCHITECTURE](../ARCHITECTURE.md))
registers only for Shepherd or Shepherd Nightly run from a stable, signed bundle (`BackgroundService.mayRegister`).
Dev and Prod never register it (Dev runs from DerivedData and sets `SHEPHERD_SUPPORT_DIR`), so
they run their agents in the app's own child, `Shepherd --host --supervised` (`HostSupervisor`).
A host you start by hand on Dev's folder (`SHEPHERD_SUPPORT_DIR=… <built app>/Contents/MacOS/Shepherd --host`)
owns the workspace first, and the scheme follows it instead. To debug that process, run the scheme, then Debug ▸ Attach to
Process and pick the second `Shepherd` (or attach by its pid, which `log show --predicate
'subsystem == "com.shepherd.app"'` prints in "host child started"). Its stderr shows in the
app's console. Stopping the app in Xcode closes the child's stdin, so the child stops too.

**The pi engine** (Node plus pi's bundle, pinned in `scripts/pi-engine-pin.json`) ships inside the
Mac app, and every agent runs it, in Shepherd's own pi home ([docs/pi-engine.md](pi-engine.md)). Stage it
once, and again whenever the pin changes, before any Mac build: every configuration's "Embed pi
engine" phase copies it from `.build/pi-engine` and fails, saying so, when it is missing or stale.

```bash
python3 scripts/pi_engine.py stage           # downloads to .build/pi-engine-cache, checks the pin
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile build
```

Keep `-onlyUsePackageVersionsFromResolvedFile` so a fresh Xcode build does not update
`Package.resolved`. Test tiers, focused examples and broader checks live in [testing](testing.md).

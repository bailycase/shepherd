# Build, run, test

> Read when you build, run or test Shepherd: the schemes, the pi engine and the exact commands.

There is deliberately no Makefile or Taskfile. One Xcode project at the repo root runs the apps,
and plain SwiftPM drives everything else.

**The Mac app:** open `Shepherd.xcodeproj`, pick a scheme, choose My Mac, and Run. The Mac target
is a shim (`App/ShepherdLauncher.swift` calls `ShepherdMacApp.main()` from the `ShepherdApp`
library). There is no `swift run` path for the GUI.

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
the iPhone and iPad client ([docs/ios](ios/README.md); who owns which folder, the routes and
the hooks are in [docs/ios/CONTRACTS.md](ios/CONTRACTS.md)).

**Shepherd Nightly** is the same code built as a second app, so it installs and runs beside
Shepherd. The `Nightly` configuration is Release plus its identity: bundle id
`com.bailycase.shepherd.nightly` (so its own preferences domain), product name
`Shepherd Nightly`, `App/AppIconNightly.icon`, and the `appcast-shepherd-nightly.xml` feed.
Everything else keys off the bundle id through `ShepherdEdition` (`ShepherdProtocol`): the
support directory, the listener's default port (7434 instead of 7433), the window's name, and the
update channel. It starts with an empty support directory; nothing is copied from Shepherd's.
Info.plist takes the executable, the names, and the feed file (`SHEPHERD_APPCAST`) from build
settings, and each configuration compiles only its own icon.

**The pi engine** (Node plus pi's bundle, pinned in `scripts/pi-engine-pin.json`) ships inside the
Mac app, and every agent runs it, in Shepherd's own pi home ([docs/pi-engine.md](pi-engine.md),
[docs/pi-home.md](pi-home.md)). Stage it
once, and again whenever the pin changes, before any Mac build: every configuration's "Embed pi
engine" phase copies it from `.build/pi-engine` and fails, saying so, when it is missing or stale.

```bash
python3 scripts/pi_engine.py stage           # downloads to .build/pi-engine-cache, checks the pin
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile build
swift build                                  # every package target
swift test --filter UnitTests                # fast tier: seconds
swift test --filter IntegrationTests         # real server, stub pi, git, off-screen windows
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter PreviewTests
swift test                                   # everything (previews skip without SHEPHERD_PREVIEW_DIR)
CI=true swift test                          # what CI runs: timing-sensitive tests skipped
PI_PACKAGE_DIR="$(npm root -g)/@earendil-works/pi-coding-agent" node --test Tests/Extensions/*.test.mjs
python3 -m unittest discover -s Tests/Release   # release rules, CI planning and workflow checks
```

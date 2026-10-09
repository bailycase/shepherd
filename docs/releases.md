# Branches, commits and releases

> Read when you branch, commit, open a PR, cut a release, or touch the release workflow, signing or the appcasts.

## Git

Use conventional commits (`feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`; `feat!:` for
breaking changes), one logical change per commit, with no AI or attribution lines.

`nightly` is the integration branch. Feature branches (`feat/…`, `fix/…`) come off it and merge
back through a PR with a merge commit (`--no-ff`). Every push to `nightly` ships a Shepherd
Nightly build. Nightly pushes build and publish without running tests, including the release
test preflight. Signing, notarization and artifact verification still run. CI tests pull requests
and pushes to `master`; its daily run also tests `master` (docs/testing.md).

## Releases

The Release workflow (`.github/workflows/release.yml`) ships two Mac apps and the iOS client's TestFlight builds.
Its build-only helper (`.github/workflows/release-build.yml`) shares Mac packaging between Self-hosted and hosted runners. Its rules live in
`scripts/release.py` (tested in `Tests/Release`); the YAML only runs them. A `plan` job decides
from the pushed ref what to build, and the build job is skipped when the answer is nothing.
Releasing Shepherd means tagging `nightly`'s tested tip and pushing the tag.

| App | Channel | Cut by | Feed (on `gh-pages`) | Contains | DMG |
| --- | --- | --- | --- | --- | --- |
| Shepherd | stable (default) | tag `vX.Y.Z` | `appcast.xml` | stable | `Shepherd.dmg` |
| Shepherd | beta | tag `vX.Y.Z-beta.N` | `appcast-beta.xml` | beta + stable | `Shepherd.dmg` |
| Shepherd Nightly | nightly | push to `nightly` | `appcast-shepherd-nightly.xml` | Shepherd Nightly builds | `Shepherd-Nightly.dmg` |
| Shepherd iOS | TestFlight internal | manual run (`gh workflow run release.yml --ref nightly -f testflight=true`) | none (App Store Connect) | Shepherd iOS builds | none |

- **Apple silicon only.** Both Mac apps ship arm64 only. The Mac target's configurations set
  `ARCHS = arm64`, and the release build also passes `ARCHS=arm64`, because SwiftPM package
  targets take no target settings and would otherwise compile x86_64 too (a local Release or
  Nightly build from Xcode still does, so its package frameworks and `shepherd-cli` come out
  universal). `release.py thin-app` then thins what comes prebuilt universal (Sparkle's framework
  and its helpers) to arm64, and `verify-app` refuses any Mach-O in the app with another slice.
  The pi engine pins only Node's `darwin-arm64` archive.
- **No updates for Intel Macs.** `release.py publish` gives every item it writes to gh-pages
  (all three feeds and both legacy aliases, old releases included)
  `<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>`. Sparkle 2.9.0 and later
  skip such an item on an Intel Mac, so an Intel install is offered nothing: its background
  checks stay quiet, and Check for Updates says "Your Mac is too old" (the update "requires a
  new Apple silicon Mac").
  - generate_appcast adds the element itself only for an archive whose executable has no x86_64
    slice, so the universal builds from before the switch need it added. `publish` inserts it
    as text, leaving every other byte as generated, keeps one generate_appcast already wrote,
    and refuses a feed where an item lacks it, names it twice, or names another requirement.
  - The feeds are unsigned (no `SURequireSignedFeed`), so editing them, like `fix-urls`,
    invalidates nothing: the EdDSA signatures cover the archives and deltas, not the XML.
  - Every Shepherd and Shepherd Nightly release shipped Sparkle 2.9.6, so no installed build
    ignores the element (`Tests/Release` holds the pin at 2.9.0 or later). A build with an older
    Sparkle would ignore it: it would still be offered the update, and the arm64-only app would
    not open on an Intel Mac. No Intel users are expected.
- **Release candidates are retired.** A `vX.Y.Z-rc.N` tag builds nothing (the plan job says
  why), and old rc releases land in no feed.
- **Only `nightly` ships Shepherd Nightly.** A manual run (`workflow_dispatch`) plans like a
  push of its ref, so on any other branch it builds nothing rather than shipping that branch to
  every Shepherd Nightly.
- **The iOS client uploads only on a manual run.** Apple caps TestFlight uploads per day, and a
  build per nightly push hit it (ITMS-90382, 2026-09-25). So no push uploads `Shepherd iOS`; a
  manual run on `nightly` with the `testflight` input
  (`gh workflow run release.yml --ref nightly -f testflight=true`) uploads it to TestFlight
  internal testing and builds no Mac app. A plain manual run plans like a push. The `testflight`
  job runs on the `xcode-27` runner, archives unsigned, and cloud-signs at export with the
  `APP_STORE_CONNECT_*` key. The plan refuses it on any other ref, without the key, or on a
  re-run (which keeps the build number; start a new run). Its version is the project's
  `MARKETING_VERSION`, and its build number is the run number. Beta tags (external testing) and
  stable tags (the App Store) upload nothing yet ([docs/ios](ios/README.md#distribution)).
- **Only the newest TestFlight build stays installable.** After the testflight job uploads,
  the Release workflow's `retire-testflight` job (`release.py retire-testflight`) waits up to 45
  minutes for Apple to process that build, then expires every older one. If it fails processing
  or never finishes, nothing expires. The first TestFlight run after it lands also clears the
  builds already there. There is no manual run; a dry run (`--dry-run`) works only locally, with
  the App Store Connect key.
- **One build number, one release.** A re-run keeps `github.run_number`, the build number.
  `generate_appcast` refuses a feed directory holding two archives of one build, and that fails
  every feed's update until one ages out. So a nightly re-run whose commit already carries a
  `nightly-*` tag builds nothing (push again instead), and a tag's re-run stops at
  `gh release create`.
- **Runs queue; they never cancel.** A push waits for the release already running, and a newer push
  replaces only the one still waiting, so every started run finishes (a cancelled run can leave a
  TestFlight upload unretired or the feeds half written) and the newest commit ships next. A
  TestFlight run queues in a group of its own, so it never replaces a waiting push or is replaced
  by one. Distinct tags keep separate build groups. Only the `publish-appcasts` job shares one
  `appcast-publication` concurrency group (`cancel-in-progress: false`): replacing a waiting
  publisher loses no release, because every admitted publisher rereads all completed releases.
  Releases upload as drafts, including `shepherd-appcast.json` eligibility metadata, and become
  public only after their required assets exist. Publication ignores drafts, excludes marked
  ad-hoc releases, and refuses malformed present metadata. Unmarked historical releases retain
  their legacy eligibility. The publisher fetches only Sparkle's manifest at the exact revision
  in `Package.resolved`, then lets SwiftPM resolve and checksum-verify its binary tools in a
  temporary package directory. It never resolves Shepherd's terminal/parser dependency graph.
  It needs the Sparkle key and repository write token, not the Developer ID certificate.
- **Two apps, never each other's updates.** Shepherd Nightly has its own bundle id, name
  (`Shepherd Nightly.app`), DMG and feed, and every feed carries one app only. Sparkle is not
  the boundary: its installer picks the new app in an archive by the host's *file name* first
  and only then by bundle id, and both apps share the EdDSA key. The distinct file name makes a
  stray cross-app item fail to install rather than replace the app, but the feeds are what keep
  it from being offered, and three guards keep them apart:
  - `release.py route` puts a `nightly-*` release in Shepherd Nightly's feed only through
    `Shepherd-Nightly.dmg`. Nightlies from before the split carry only `Shepherd.dmg` and drop
    out, and an old copy of this workflow (which downloads `Shepherd.dmg`) never picks up a
    Shepherd Nightly build.
  - The build job runs `release.py verify-app` before signing: the bundle id, name, executable
    and `SUFeedURL` must be the planned app's.
  - `ChannelDelegate` computes the feed from the edition, so a Shepherd Nightly build reads its
    own feed even if its `SUFeedURL` were wrong.
- **One EdDSA key** (`SPARKLE_PRIVATE_KEY`, `SUPublicEDKey`) signs both apps.
- **Legacy feeds for installed builds.** Shepherd builds from before the split read
  `appcast-rc.xml` (allowing Sparkle channel `rc`) or `appcast-nightly.xml` (allowing
  `nightly`, or no channel at all in the first nightly builds). Every run still writes both, as
  the beta feed with its items untagged: Sparkle shows default-channel items whatever a build
  allows. So those installs update to a Shepherd beta or stable (never Shepherd Nightly), and
  that build's launch migration moves them to Beta. Keep writing them while such installs may
  exist. A Shepherd install that rode nightly sits at a build number above every existing beta
  and stable, so it waits until the first Shepherd beta or stable built after the split: cut one
  soon after the split lands.
  - Tags and nightlies built by this workflow serialize publication, not builds. Before shipping
    a tag from an older commit whose workflow lacks that publication group, wait for other
    releases to finish: old workflows do not participate in the shared ownership.
  - Tag only commits that contain the split. A tag runs the workflow of its own commit: an
    older one rebuilds `appcast-rc.xml` and `appcast-nightly.xml` the old way until the next run
    here rewrites them, and an rc tag there still cuts an rc.
- **Launch migration** (`UpdateChannelStore`, Shepherd only): a stored `rc` becomes Beta, and a
  stored `nightly` (or the pre-picker nightly bool) becomes Beta and arms a one-time notice
  under the toolbar (`NightlyMovedNotice`) linking to Shepherd Nightly. The birth channel reads
  `-beta.`, `-rc.` and `-nightly.` versions as Beta. Shepherd Nightly always rides nightly and
  stores no channel. Debug builds (the Dev scheme, `com.bailycase.shepherd.dev`) have no
  updater, so they never resolve or migrate a channel.
- **Promotion tags the same source commit** (`v0.2.0-beta.1` → `v0.2.0`). The workflow builds
  that commit again with the stable marketing version and a new run-number build. It does not
  promote an unchanged binary artifact.
- **The beta feed is a superset**, so riding beta never strands a user behind a stable hotfix.
  Sparkle picks the newest *build number* (`CURRENT_PROJECT_VERSION`, the workflow run number,
  shared by both apps), so a hotfix built after a beta supersedes it for beta riders.
- **Tags are immutable.** Never delete, move, or reuse one; a botched release gets the next
  number. (Old `nightly-*` releases and their tags are pruned to the latest few; those tags are
  the workflow's own, not release versions.)
- **Default channel:** Shepherd (`AppUpdater.swift`, `UpdateChannel`) defaults to its birth
  channel, parsed from the marketing version. An explicit choice in Settings ▸ Advanced is never
  overwritten, and the picker offers only Stable and Beta.
- **Channel plumbing** changes `scripts/release.py` (and `release.yml` if the steps change),
  `UpdateChannel`/`UpdateChannelStore`/`ChannelDelegate`, the Advanced row, the Xcode
  configurations, and their tests together. Feed names and bundle ids are a contract between CI
  and the apps; `Tests/Release` reads both sides.
- **Signing:** a configured Developer ID requires successful signing and notarization; missing
  notarization credentials fail that release rather than downgrade it. Without a Developer ID,
  the build is ad-hoc and its eligibility asset permanently excludes it from appcasts, even if
  a future signed release regenerates them. Without the Sparkle key, publication is skipped;
  an eligible signed release can enter the feeds on a later successful publisher.
  - `scripts/sign-app.sh` signs inside-out, never with `--deep`: every nested item first, then
    the app with `App/Shepherd.entitlements` (both apps). Only nested apps and XPC services keep
    their own entitlements, and the pi engine's node gets the engine's: `scripts/sign-engine.sh`
    signs it with `App/Engine.entitlements` (allow-jit, which V8 needs under the hardened
    runtime) as `node`, and refuses a node with any slice but arm64. `node` is never stripped.
  - The iOS client is archived unsigned and signed only at export, with the team's
    cloud-managed Apple Distribution certificate through the `APP_STORE_CONNECT_*` API key
    (`-allowProvisioningUpdates`). There is no `.p12` and no keychain.
  - Developer ID items get the hardened runtime and a secure timestamp, and both the app and the
    DMG are notarized and stapled. Ad-hoc builds skip the runtime, because library validation
    rejects ad-hoc frameworks, which have no Team ID.
  - Shipped binaries are stripped (`strip -S -x`). Their dSYMs go on each release as
    `Shepherd-dSYMs.zip` or `Shepherd-Nightly-dSYMs.zip`.
- **Appcasts** are rebuilt by the serialized publication job from all completed eligible
  releases, keeping the four newest completed nightlies: one `generate_appcast` per feed
  directory, written to a fixed name (`-o`; left alone it names the file after the app's
  `SUFeedURL`). Deltas go to the feed's newest release, renamed without spaces
  (`Shepherd Nightly63-61.delta` → `Shepherd-Nightly63-61.delta`), because GitHub rewrites
  spaces in asset names. Only after the feed push succeeds (or nothing changed) does that job
  prune older completed nightlies from its frozen snapshot; drafts and releases completed during
  publication are never pruned. Failed acquisition, metadata validation, generation or pushing
  prunes nothing. A skipped publisher (no Sparkle key) prunes nothing either.
- **Nightly builds on GitHub unless self-hosted is explicitly enabled.** The repository variable
  `SHEPHERD_SELFHOSTED_ENABLED` must equal `true` to opt in. Otherwise the selector immediately
  chooses hosted without dispatching or waiting for a local helper; direct local helper calls
  also skip before scheduling the Mac. Keep the shared Mac's runner disabled in launchd until
  builds have isolated resources. A separate account or reduced CPU priority cannot protect
  Kubernetes and other apps from build memory exhaustion.
  When enabled, Release's Ubuntu orchestrator dispatches the build-only helper on `nightly`,
  targeting the existing `shepherd-selfhosted` runner's sole custom label, `shepherd-release`.
  No PAT or PR execution is involved. The optional
  `SELFHOSTED_HOSTNAME` secret masks the machine name in the runner's built-in setup log;
  public workflow labels and errors use generic self-hosted names. It is a log-masking value,
  not an authentication credential. Existing logs and Git history are not rewritten. Stable/beta and TestFlight remain hosted. Both Mac attempts check out
  the exact Release source SHA and use its run number, plan, signing identities, entitlements
  and notarization policy; the dispatched helper's own run number is never a shipped build number.
  - `scripts/release_runner.py` allows fifteen minutes for dispatch discovery and queueing
    (a queued local build is usually waiting behind a pull request's CI on the same runner),
    sixty minutes for local execution, two minutes for cancellation acknowledgement, and polls
    every fifteen seconds. Each API request has a ten-second timeout; the Ubuntu job has an
    eighty-minute outer bound. The build jobs also have a sixty-minute execution limit.
    Job timeouts alone do not bound a queued offline runner. There is one dispatch and at most
    one hosted fallback, not a retry loop.
  - A completed local build failure/timeout permits fallback. An expired queue/execution bound
    first cancels the isolated helper run and waits for API status `completed`; accepting the
    cancellation request alone is insufficient. If cancellation returns HTTP 409 because the
    worker completed between GET and POST, monitoring and cleanup re-fetch its state: confirmed
    success follows the normal package checks, confirmed build failure follows the fallback
    guards, and an unknown/nonterminal response fails closed. Unknown dispatch identity/state, API errors,
    unacknowledged cancellation, an explicit cancellation or an invalid successful package
    fail closed, without fallback. If success races cancellation, a confirmed successful local
    package is still preferred; neither build can publish.
  - The helper validates its active Release parent/attempt and Nightly-only dispatch before
    scheduling Self-hosted, again on runner entry, and before accessing signing credentials.
    Re-running the helper is refused. Parent cancellation best-effort cancels its helper;
    if the parent disappears before cleanup, a late queued helper refuses the inactive
    parent, and already-running work is bounded and cannot publish. Re-running Release uses
    a new attempt identity and retains the existing published-tag/build-number protection.
  - Each successful attempt uploads a required DMG, eligibility metadata and a manifest
    binding its checksum to the parent run/attempt, source SHA, build number and planned
    tag/version, plus optional dSYMs. The single hosted Release publisher downloads only the
    selected attempt's artifact and verifies that manifest before any tag/release mutation.
    Fallback never reacts to publication/appcast failure or partial success: existing draft-first
    release publication, immutable tags and the serialized appcast job remain the boundary.
    The appcast job requires a successful selected release and checks cancellation explicitly;
    skipping the unused build path must not suppress publication through implicit `success()`.
  - Self-hosted keeps DerivedData and verified pi downloads between jobs. Checkout preserves
    ignored build outputs but no Git credentials. The build marker combines Xcode, Swift, SDK,
    shared library source and package/project/engine inputs. Changing any of those discards
    products but keeps package downloads, preventing reuse across a transitive model/ABI change.
    Changes confined to ShepherdApp can build incrementally. Hosted cache restores use the same
    marker inputs. Both the app and DMG still wait for notarization acceptance and receive
    stapled tickets before package provenance is recorded.
  - Self-hosted uses a temporary signing keychain with a random password, preserves/restores the
    exact existing user keychain search list and removes imported certificate/notary files in
    an `always()` cleanup step, including after failure/cancellation. Forced runner termination
    can prevent cleanup: inspect the runner's job temp directory before reusing a killed worker.
    No installed app, runner registration, permanent keychain or user application data is changed.
  - **Rollout prerequisite:** GitHub requires a dispatch workflow to exist on the repository's
    default branch (`master`) even when dispatch targets `nightly`. Preparing these files does
    not enable Self-hosted routing until `release-build.yml` has been separately authorized and
    landed there. Bootstrap only the shared worker and its orchestrator script on `master`,
    preserving that branch's existing release workflow and signing/feed contracts. The owner
    approves the bootstrap and live rollout separately; merging the Nightly PR alone is not
    enough. Absent dispatch support, selection fails closed rather than bypassing its fence.
    `.github/CODEOWNERS` names `@bailycase` and `@jhartzell` for workflows, release/signing
    scripts and engine staging inputs; the owner must enable required code-owner reviews in
    branch protection to enforce those assignments.
  - **Decisions:** the default bounds above, fail-closed uncertain state, hosted-only publication,
    ephemeral keychain handling are deliberate. Tests use
    fake GitHub states, scratch packages/keychains and the existing fake publication shell;
    local tests cannot establish GitHub's live cancellation or cross-run artifact semantics.
- **Building Shepherd Nightly locally:** the `Shepherd (Nightly)` scheme, or
  `xcodebuild -scheme 'Shepherd (Nightly)' -configuration Nightly …` as the workflow does.
- **Enhanced Security** is set on the Mac target only, because at project level it would push
  arm64e onto the iOS target. Pointer authentication stays off, since libghostty and Sparkle
  ship no arm64e slice. The real protection is the hardened-process entitlements. The
  compile-time half of `ENABLE_ENHANCED_SECURITY` (stack zero-init, typed allocators, libc++
  hardening) reaches only `App/ShepherdLauncher.swift`: SwiftPM package targets do not inherit
  target settings. So ShepherdPTYSpawn's C and the tree-sitter parsers build without it.

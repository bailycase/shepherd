# The pi engine

Shepherd ships its own pi: the official Node binary plus pi's bundle, inside the Mac app. Every
pi Shepherd starts runs it (agents, the model catalog, PR descriptions, children, the sign-in
terminal), through the launcher in Shepherd's own pi home ([pi-home.md](pi-home.md)); the MCP
probe and the Skills reader run on its node. Nothing runs the `pi` on the user's PATH.

## What ships

| Path in `Contents/` | What |
| --- | --- |
| `Helpers/node` | Node, universal (`arm64` and `x86_64`), Node's release binary as published. Never stripped |
| `Resources/pi-engine/package.json` | pi's, with its version and config-dir name |
| `Resources/pi-engine/dist/bundle/` | pi's bundle; `cli.js` is the entry (`node cli.js …`) |
| `Resources/pi-engine/dist/modes/interactive/{theme,assets}/`, `dist/core/export-html/` | the themes, interactive assets and export templates pi finds beside the bundle |
| `Resources/pi-engine/README.md`, `docs/`, `examples/`, `CHANGELOG.md` | what pi's system prompt points the model at |
| `Resources/pi-engine/node_modules/` | only `@earendil-works/chord` (its `context` entry), `jiti` and `@silvia-odwyer/photon-node`: the modules the bundle loads |
| `Resources/pi-engine/LICENSE`, `NODE-LICENSE`, `THIRD-PARTY-NOTICES` | pi's MIT notice, Node's licence verbatim, and the packages the bundle compiles in |

Nothing lives in `Contents/MacOS` (the release strips everything there), and no path matches pi's
install-method detection (`/node_modules/`, `/npm/`, …, above the entry), so pi never offers to
update itself. esbuild and its 26 platform packages never ship: chord declares esbuild, but its
`context` entry imports nothing.

`BundledPiEngine` (ShepherdSessions) finds this layout in an app and gives the command prefix,
the package directory and pi's version.

## The pin and staging

`scripts/pi-engine-pin.json` pins Node (version, and the SHA-256 of each darwin `.tar.xz`) and
pi and its three modules (version, registry tarball, and `sha512` integrity).

`python3 scripts/pi_engine.py stage` (stdlib only):

1. Downloads Node's `SHASUMS256.txt` and checks it lists each pinned archive with the pinned
   hash, then each archive, checked against the pin.
2. Downloads pi's and the modules' tarballs, checked against their integrity. Each module must
   also be the version pi's `npm-shrinkwrap.json` resolves.
3. Unpacks with `tarfile`: no npm, and no package script ever runs. Links, devices and paths
   outside `package/` are refused.
4. Keeps the files above, `lipo -create`s Node's two slices, writes the licences, and swaps the
   tree into `.build/pi-engine` whole.
5. Verifies the result the way `release.py verify-app` does.

Downloads are cached in `.build/pi-engine-cache` and reused only while they still match the pin,
so a second stage is offline (`--offline` insists on it). Nothing is written outside the repo's
`.build`.

**Bumping the pin:** take each Node archive's SHA-256 from
`https://nodejs.org/dist/vX.Y.Z/SHASUMS256.txt` (Node 24 LTS or a later even line; pi's
`engines` is checked at staging), and each package's `dist.integrity` from
`https://registry.npmjs.org/<name>/<version>`. The module versions must match pi's shrinkwrap.
Then stage, build, and run the smoke test.

## The Xcode phase

"Embed pi engine" is the Mac target's last phase, in all three configurations. It checks the
staged `pin.json` equals the pin, copies the tree into `Contents/`, and signs node slice by slice
(`scripts/sign-engine.sh`) when the build signs. It never downloads.

Script sandboxing stays on. The sandbox grants each declared input and output as a literal path,
not a folder's contents, so staging also writes `inputs.xcfilelist` (every staged file) and
`outputs.xcfilelist` (every file and folder the phase writes), and the phase declares them. A
build before staging fails on the missing file list; one after a pin change fails on the stamp.
Either way, stage and build again.

## Signing

Under the hardened runtime V8 needs JIT pages. Tested with Node 24.21.0:

| Slice | Needs | Without it |
| --- | --- | --- |
| arm64 | `com.apple.security.cs.allow-jit` | |
| x86_64 (Intel, or Rosetta) | `allow-jit` and `com.apple.security.cs.allow-unsigned-executable-memory` | `Check failed: 12 == (*__error())` in `CodeRange::InitReservation`, at startup |

One set of entitlements on the fat file would give arm64 the x86_64 exception too, so
`scripts/sign-engine.sh` thins node, signs each slice with its own file (`App/Engine.entitlements`,
`App/Engine-x86_64.entitlements`), and joins them. `scripts/sign-app.sh` calls it for
`Contents/Helpers/node`, and refuses to sign an app that carries node without them. Nothing else
in the app gets these entitlements, and node gets none of the app's hardened-process keys.

Ad-hoc builds (the Dev scheme, releases without the Developer ID) sign without the runtime, as
Xcode does for the app. The smoke test signs a scratch copy with the runtime to check the
entitlements anyway.

`release.py verify-app` checks the engine before signing: node carries both slices at the pinned
version, pi and each module are the pinned versions, `node_modules` holds nothing else, nothing
native or esbuild sits in the engine, and the licences are there.

## Size

About 236 MB for universal Node and 18 MB for pi (with docs and examples). A Debug app grows from
roughly 135 MB to 390 MB.

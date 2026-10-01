# The pi engine

Shepherd ships its own pi: the official Node binary plus pi's bundle, inside the Mac app. Every
pi Shepherd starts runs it (agents, the model catalog, PR descriptions, children), through the
launcher in Shepherd's own pi home ([pi-home.md](pi-home.md)); the MCP probe and the sign-in
bridge (pi's own login, imported from the bundle's `index.js`) run on its node. Nothing runs the `pi` on the user's PATH.

## What ships

| Path in `Contents/` | What |
| --- | --- |
| `Helpers/node` | Node for `arm64` only (Shepherd runs on Apple silicon only), Node's release binary as published. Never stripped |
| `Resources/pi-engine/package.json` | pi's, with its version and config-dir name |
| `Resources/pi-engine/dist/bundle/` | pi's bundle; `cli.js` is the entry (`node cli.js …`) |
| `Resources/pi-engine/dist/modes/interactive/{theme,assets}/`, `dist/core/export-html/` | the themes, interactive assets and export templates pi finds beside the bundle |
| `Resources/pi-engine/README.md`, `docs/`, `examples/`, `CHANGELOG.md` | what pi's system prompt points the model at |
| `Resources/pi-engine/node_modules/` | only `jiti`, `@silvia-odwyer/photon-node` and `quickjs-wasi` (its `package.json` and `quickjs.wasm`): the modules the bundle loads |
| `Resources/pi-engine/LICENSE`, `NODE-LICENSE`, `THIRD-PARTY-NOTICES` | pi's MIT notice, Node's licence verbatim, and the packages the bundle compiles in |

Nothing lives in `Contents/MacOS` (the release strips everything there), and no path matches pi's
install-method detection (`/node_modules/`, `/npm/`, …, above the entry), so pi never offers to
update itself. esbuild and its 26 platform packages never ship: chord declares esbuild, but pi 1.0's
bundle no longer loads chord at all (0.87.1 imported its `context` entry), so it is not a module here.

`BundledPiEngine` (ShepherdSessions) finds this layout in an app and gives the command prefix,
the package directory and pi's version.

## The pin and staging

`scripts/pi-engine-pin.json` pins Node (version, and the SHA-256 of its `darwin-arm64.tar.xz`) and
pi and its three modules (version, registry tarball, and `sha512` integrity).

`python3 scripts/pi_engine.py stage` (stdlib only):

1. Downloads Node's `SHASUMS256.txt` and checks it lists the pinned archive with the pinned
   hash, then the archive, checked against the pin.
2. Downloads pi's and the modules' tarballs, checked against their integrity. Each module must
   also be the version pi's `npm-shrinkwrap.json` resolves.
3. Unpacks with `tarfile`: no npm, and no package script ever runs. Links, devices and paths
   outside `package/` are refused.
4. Keeps the files above (Node's binary as it comes), writes the licences, and swaps the tree
   into `.build/pi-engine` whole.
5. Verifies the result the way `release.py verify-app` does.

Downloads are cached in `.build/pi-engine-cache` and reused only while they still match the pin,
so a second stage is offline (`--offline` insists on it). Nothing is written outside the repo's
`.build`.

**Bumping the pin:** take the `darwin-arm64` archive's SHA-256 from
`https://nodejs.org/dist/vX.Y.Z/SHASUMS256.txt` (Node 24 LTS or a later even line; pi's
`engines` is checked at staging), and each package's `dist.integrity` from
`https://registry.npmjs.org/<name>/<version>`. The module versions must match pi's shrinkwrap.
Then stage, build, and run the smoke test.

## The Xcode phase

"Embed pi engine" is the Mac target's last phase, in all three configurations. It checks the
staged `pin.json` equals the pin, copies the tree into `Contents/`, and signs node
(`scripts/sign-engine.sh`) when the build signs. It never downloads.

Script sandboxing stays on. The sandbox grants each declared input and output as a literal path,
not a folder's contents, so staging also writes `inputs.xcfilelist` (every staged file) and
`outputs.xcfilelist` (every file and folder the phase writes), and the phase declares them. A
build before staging fails on the missing file list; one after a pin change fails on the stamp.
Either way, stage and build again.

## Signing

Under the hardened runtime V8 needs JIT pages: `com.apple.security.cs.allow-jit`
(`App/Engine.entitlements`), tested with Node 24.21.0 on arm64. `scripts/sign-engine.sh` signs node
with it, under the identifier `node`, and refuses a node with any slice but arm64.
`scripts/sign-app.sh` calls it for `Contents/Helpers/node`, and refuses to sign an app that carries
node without the file. Nothing else in the app gets this entitlement, and node gets none of the
app's hardened-process keys.

Ad-hoc builds (the Dev scheme, releases without the Developer ID) sign without the runtime, as
Xcode does for the app. The smoke test signs a scratch copy with the runtime to check the
entitlements anyway.

`release.py verify-app` checks the engine before signing: node is arm64 only at the pinned
version, pi and each module are the pinned versions, `node_modules` holds nothing else, nothing
native or esbuild sits in the engine, and the licences are there.

## Size

About 116 MB for Node and 19 MB for pi (with docs and examples): 135 MB staged with pi 1.0.0
(134 MB with 0.87.1; the growth is the bundle's MCP, codemode and image-model code and their docs).

# The pi engine

Shepherd ships its own pi: the official Node binary plus pi's bundle, inside the Mac app. Every
pi Shepherd starts runs it (agents, the model catalog, PR descriptions, children), through the
launcher in Shepherd's own pi home ([pi-home.md](pi-home.md)); the sign-in bridge (pi's own login,
imported from the bundle's `index.js`) runs on its node. Nothing runs the `pi` on the user's PATH.

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

A new pi can need modules the old one didn't. pi compiles its dependencies into `dist/bundle`, so
only what the bundle resolves from `node_modules` at run time ships (`MODULE_KEEP`, and
`MODULE_REQUIRED` for the files it finds by name): look for bare `import()`/`require` specifiers
and `require.resolve` in the bundle's chunks, then prove each with a control (stage without the
module and run the feature: pi 1.0 without `quickjs-wasi` answers a codemode script "Cannot find
module 'quickjs-wasi/quickjs.wasm'"). Also run the extension tests against the pinned version
(CI installs it from the pin), `EngineSmokeTests` and `EngineThreadTests`
(docs/testing.md › Engine smoke), and compare the real engine's RPC replies and events with the
last pin's.

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

## pi 1.0

What the move from 0.87.1 to 1.0.0 changed for Shepherd, as observed on the staged engine
(`Tests/Extensions` against the pinned modular package, `EngineSmokeTests`, `EngineThreadTests`),
not read off the changelog.

**The bundle.** pi 1.0 ships MCP, codemode (model-written JavaScript in a QuickJS WebAssembly
sandbox) and tool search as built-in extensions, and drops chord from the bundle's imports.
`node_modules` is `jiti`, photon and `quickjs-wasi` (only `package.json` and `quickjs.wasm`; its
`extensions/*.so` are WebAssembly side modules pi never loads, named like native code). The staged
engine is 135 MB, from 134 MB.

**MCP and tool search are Shepherd's MCP; codemode is off.** Agents use pi's own MCP, with Settings ▸
MCP servers on top of it ([mcp.md](mcp.md) has the evidence, measured on this engine, and the layering).
The home's `settings.json` still carries `-builtin:mcp`, `-builtin:codemode` and `-builtin:tool-search`
(`PiHome.install`, under pi's lock, never replacing an entry that already names one in any form), so
anything that starts pi without saying otherwise loads none of them: the model catalog, drafts, native
children (`--no-extensions`) and a `pi` an agent types. **An agent's launch switches MCP on** with `-e
builtin:mcp -e builtin:tool-search`, which pi lets win over the home's switch (checked:
`Tests/Extensions/pi-mcp.test.mjs`, and through the real launcher in `EngineSmokeTests`), while Settings ▸
Pi ▸ Bundled extensions ▸ MCP servers is on. `codemode` stays off: with it off, a server on pi's default
exposure (`codemode`) is unreachable, which is why Shepherd's derived `mcp.json` always names an exposure.

pi 1.0's tool exposure (`deferred`, a namespace) and `tool_search` also carry Shepherd's own rarely used tools: the
extensions register the browser, other-thread, automation and review tools `deferred` while `SHEPHERD_DEFER_TOOLS=1`, and
the launch passes `-e builtin:tool-search` even with MCP off ([context-budget.md](context-budget.md) › Deferred tools has
what pi does with them, measured).

What pi's MCP does with the files and the environment it is given is in [mcp.md](mcp.md); what it adds
to a launch is `/mcp` (over RPC it answers with this thread's servers, `name: connected, 9 tools
(deferred)`), a server section in the system prompt, `tool_search`, and `<home>/mcp-auth.json` for
sign-ins. A trusted project's `.pi/mcp.json` is read too, as pi's trust model says. `llama.cpp`, the
fourth built-in, is a provider pi has always shipped and stays; `/llama` still does nothing over RPC and
the thread's command menu leaves it out. `PiConfig.installedExtensions` (Settings ▸ Pi, a host's
`hostSettings`) and the first copy from "your pi" ignore the `builtin:` entries.
`Tests/Extensions/builtin-extensions.test.mjs` pins pi's side of the home's switch, so a pi that renames
it or loads the built-ins anyway fails before a release, and
`EngineSmokeTests.piRunsTheDerivedMCPFileOnlyWhenAnAgentsLaunchSwitchesItOn` runs the whole thing against
the shipped engine through Shepherd's launcher.

**RPC.** What the thread reads is unchanged (`EngineThreadTests` runs a turn, a tool call, a
reasoning block, Stop with a queued message, an extension's question, a command's notice, a
prompt template, a skill and Compact through the real `SessionServer`, on both 0.87.1 and 1.0.0;
the extension UI requests are identical for every kind). Additions, none read yet: `prompt`,
`steer` and `follow_up` replies carry `data.disposition` (`started`, `queued` or `handled`, the
last for an extension command's prompt), assistant messages carry `thinkingLevel`, a bash result
carries `structuredContent`, and `message_start` no longer carries `responseId` (it arrives at
`message_end`). `get_commands` lists a built-in extension's file as `builtin:<name>` with
`sourceInfo.source` `builtin`; 0.87.1 said `<inline:<name>>` and `inline`
(`RPCThreadState.isBuiltInExtension` takes both). Session files are the same version (3): a
seeded header is reused, and the warning for an unseeded `--session-id` has the same words.

**Sign-in.** The bridge works unchanged against 1.0 for the logins Sign-in offers: Anthropic
(whose login now asks for a method first, "Browser login" or "Copy code login (headless)"; the
bridge answers with the browser, and the sheet's paste still works), OpenAI Codex (the provider
pi now labels "legacy") and key logins. Not offered, on purpose: Sign in with ChatGPT on the
`openai` provider (the bridge passes no `getDeviceId`, so pi answers "requires a device ID"; it
would need `SettingsManager.getOrCreateDeviceId` and a catalog row), Anthropic's copy-code method
(the sheet is on the machine with the browser), and the classifier-only `typesafe` provider.

## Size

About 116 MB for Node and 19 MB for pi (with docs and examples): 135 MB staged with pi 1.0.0
(134 MB with 0.87.1; the growth is the bundle's MCP, codemode and image-model code and their docs).

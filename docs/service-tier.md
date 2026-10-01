# Service tiers ("Fast mode")

A thread can ask its provider to answer faster at a higher price. The composer's **Speed**
control (Standard or Fast) sets it per thread, ⌘K's **Toggle fast mode** flips it, and Settings ▸
Agents ▸ **Speed for new threads** is what a new thread starts on. New thread shares the composer's
model-settings popover (its Speed control, with a bolt on the button while Fast) and can override
that default before its first prompt, locally and on a host with `agent.create.serviceTier.v1`.
Older hosts keep their default and show no creation-speed control.
The UI is in DESIGN.md ›
Composer (ComposerSpeed); this page is how it works and what was verified.

- **Standard** sends nothing: the provider's default tier.
- **Fast** puts `service_tier: "priority"` in the model request. OpenAI renamed "priority
  processing" Fast mode and accepts `"fast"` and `"priority"` alike; Codex's Fast mode sends
  `"priority"`, and so do CLIProxyAPI's translators (they drop every other value), so
  `"priority"` is the one value used everywhere. It is billed at a higher rate (OpenAI: a
  per-token premium; Codex: 2x credits, 2.5x of a subscription's included limits) and the
  provider may fall back to Standard under load, reporting `service_tier: "default"`.

## Which models offer a tier

One table, `ServiceTierSupport.rules` (`Sources/ShepherdCore/ServiceTier.swift`), read by the
composer, the host's snapshot and the new-thread default. `Extensions/shepherd-service-tier.ts`
holds the same table for its request-time check. Both are tested against
`Tests/Extensions/service-tier-support.json` (43 rows: Swift's `ServiceTierTests` and the node
test), so neither can drift.

| Provider (pi's id) | APIs | Offered when |
| --- | --- | --- |
| `openai` | `openai-responses`, `openai-completions` | always (pi's catalog has only Responses models) |
| `openai-codex` (ChatGPT sign-in) | `openai-codex-responses` | always |
| `cliproxyapi` (the managed provider) | `openai-responses` | the model's `owned_by` in the connection file is `openai`, `codex` or `openai-codex`; with no owner, its id reads as OpenAI's (`gpt-…`, `o3…`, `codex-…`, or routed through `openai/`) |

Everything else offers nothing, and its requests are never touched: Anthropic, Gemini, Bedrock,
Azure (`azure-openai-responses`), xAI, Meta, Copilot, OpenRouter and every other provider. Ids
that are not chat models (image, realtime, audio, tts, transcribe, whisper, embedding,
moderation, dall-e) are left out wherever they appear. A model with no tier shows no control, not
a disabled one.

- **CLIProxyAPI's chat-completions route drops the field** for Codex
  (router-for-me/CLIProxyAPI#6138), so a proxied model pi reaches through `openai-completions`
  (an id newer than pi's catalog with no sibling to borrow from) offers nothing. The Responses
  route forwards it.
- **Through the proxy the field is forgiving.** Sent `service_tier: "priority"` to DeepSeek and
  Meta models through a local CLIProxyAPI, both answered 200 and ignored it, so a wrong guess
  would not break a turn; the table is strict anyway, so the control never promises what nothing
  honors.
- **Adding Flex** (or any tier) is a data change: a `ServiceTier` case (`flex`, title, summary),
  a `wire` entry per rule that takes it (`[.flex: "flex"]`), the same in the extension's `RULES`,
  and rows in the JSON table. The snapshot, the Speed control (one segment per offered tier), the
  palette toggle (Standard and the first raised tier) and the file format already carry any tier.
  What it still needs is a decision about the button (a third state's glyph and words) and the
  toggle's meaning.

## How a change reaches pi

The tier is `Agent.serviceTier` (persisted in `state.json`, written only when not Standard, read
as Standard from older files and unknown values). The host keeps a file per agent,
`<pi home>/service-tier/<agent id>.json` (`{"tier":"fast"}`, mode 0600, replaced by rename,
`ServiceTierFile`), and names it to the agent's pi in `SHEPHERD_EXT_SERVICE_TIER`. The extension
reads it **synchronously on every provider request**.

Why a file and not a message on the extension socket:

- a change applies to the agent's **next model call**, even inside a running turn (a turn's
  tool call and its answer are two requests; a change between them reaches the second), with
  nothing to deliver or acknowledge;
- a pi that is restarted (Retry's start, a relaunch, `/reload`) or whose socket is down reads
  the current tier the moment it makes a request, with no handshake;
- an agent whose pi is not running yet needs nothing: the host writes the file before it starts
  the process (`SessionServer.makeSessionOnQueue`), from the agent's persisted tier, and on
  every change;
- a torn read cannot happen (rename), and a missing, unreadable or unknown file is Standard.

`SessionServer.setServiceTier` (and the thread's `setServiceTier` request, which calls the same
code) writes the file first, then persists, and puts the file back if persisting fails.
Deleting the agent removes its file. Every serving thread shows its agent's tier in its
snapshot (`serviceTier`) with the tiers its model offers (`serviceTiers`), worked out from what
pi's `get_state` says the model is (provider, API, id) and, for the managed provider, who owns
the model (`ServiceTierOffers` reads the connection file's `owned_by`, cached by modification
time).

**Subagents** (native children) are other pi processes that the children extension starts
without any `SHEPHERD_` variable, so they run on Standard whatever their parent's tier is. The
extension is loaded only into an agent's own pi (`StatusExtension.command`); drafts, the catalog
and terminals (which blank the variable) never see it.

## pi's `before_provider_request`

The extension hooks pi's `before_provider_request` (not in pi's written docs; behavior captured in
`Tests/Extensions/service-tier.test.mjs` against real pi 0.87.1):

- Handlers run in extension load order; each receives `{ type: "before_provider_request", payload }`
  and a context whose `model` is the session's current model. Whatever a handler returns (when
  not `undefined`) replaces the payload for the handlers after it, and the last result is the
  body that goes on the wire (the OpenAI SDK's parameters, the Codex backend's body for both its
  WebSocket and SSE transports, which pi builds from the same object).
- A handler that throws is caught: pi emits an `extension_error` (`event: "before_provider_request"`)
  and the request goes on with the payload as it was. The extension never throws anyway.
- It runs for the agent loop's requests only (not compaction or summaries), and it composes with
  the managed provider's own `onPayload` rewrite (`strict: null` on function tools): pi's hook
  runs first, then the provider's, so both are applied.
- Payload shapes the extension checks before adding the field: `input` (an array) for
  `openai-responses` and `openai-codex-responses` (whose body has `model`, `store`, `stream`,
  `instructions`, `input`, `tools`…), `messages` for `openai-completions`, and `payload.model`
  equal to the session's model id. A payload that already has `service_tier` is left alone.
- pi-ai's Responses and Codex APIs have a `serviceTier` **stream option** that the coding agent
  never sets. When a provider reports the tier it used in its response, pi prices the turn at
  the priority rate (2x, 2.5x for `gpt-5.5`; Flex 0.5x): with the hook adding the field, a Fast
  turn's cost in the thread already follows the tier the provider reports.

## Verified

| What | How |
| --- | --- |
| The body pi sends, per API | Real pi against a local fake provider: OpenAI Responses, Chat Completions, the Codex backend's API (zstd-compressed SSE to `/backend-api/codex/responses`), the managed CLIProxyAPI provider with its rewrite still applied; Standard, Fast, mid-turn and between-turn changes, restarts, Anthropic and unlisted providers never touched |
| Codex's wire value | pi's Codex provider code (`body.service_tier = options.serviceTier` and its priority multiplier), Codex's documentation (`service_tier = "fast"` in its config) and reports of its client's wire format (Fast serializes as `"priority"`), and CLIProxyAPI's translators (they keep only `"priority"`) |
| OpenAI's | OpenAI's Fast mode docs: `service_tier` `"fast"` or `"priority"` on Responses and Chat Completions; the response's `service_tier` names the tier used |
| Through Shepherd | `ServiceTierEngineTests` (opt-in, the staged engine): the composer's store call, the real server and launcher, real pi, a fake provider's recorded bodies, a relaunch and a pi restarted in place |

**Not verified:** a priority request against Codex or OpenAI themselves. The local CLIProxyAPI's
Codex sign-in was unavailable (every `gpt-*` and `codex-*` model answered 503
`auth_unavailable`), so neither the speedup nor the provider's echoed tier was measured; pi's
real request with `service_tier: "priority"` did reach the proxy's `/v1/responses` and the
proxy accepted the shape. Third-party reports say the ChatGPT backend also keys priority routing
on Codex's own client headers (`originator`, `x-codex-routing-hint: model=<id>;tier=priority`);
pi sends its own `originator` and no routing hint, so Fast through the direct `openai-codex`
provider may be accepted but served at Standard speed. Shepherd does not imitate another client's
identity; the routing hint is a one-line addition (pi's `before_provider_headers` hook) if it
proves necessary.

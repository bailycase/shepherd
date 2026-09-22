# Native desktop preview

Local agents can switch between Native and Terminal using the workspace-header picker or Agent menu. Terminal is the shipped default; Settings ▸ Agents ▸ Default View makes Native the default for every agent on this Mac. A per-agent flip away from the default is saved on this Mac as an override (`shepherd.nativeAgents`, agent ID → Bool); choosing the default again clears it. Neither is shared workspace state.

Only the agent's primary pane changes presentation. Auxiliary shells, reviews, inspectors, and remote-host panes remain terminals or their existing views. The toggle does not restart pi, attach another agent, send a prompt, or replace the mounted Ghostty view. Native and terminal drafts are separate. Normal cold parking still applies when a whole layout stays hidden.

Native mode uses the same `shepherd-native` extension as iOS, through a direct local SessionServer request. It does not require enabling Remote or connecting to a loopback TCP listener. The platform-neutral `NativeThreadStore` lives in ShepherdRemote and is shared with iOS.

## Supported native content

- Current-branch messages, thinking and tool output, with older pages.
- Follow-up and steering messages, cancellation, and generation-bound actions.
- Standard select/confirm/input/editor questions when pi provides the documented dialog registry API.
- Explicit extension-published [text/status widgets](native-ui-widgets.md).

Extensions retain control of their data and question lifecycle; Shepherd chooses the native layout and controls. This is not arbitrary SwiftUI code loading or automatic translation of custom TUI components.

The [prototype pi patch](ios/pi-dialog-bridge/README.md) remains required for native standard-question answers. No global pi install is modified. Stock pi without that API still supports native text/send/abort; use Terminal for its questions, custom controls, image handling, and slash commands. Native sends are literal text. External editors temporarily disable native answers. An accepted action means API dispatch, not completed or persisted work; unknown outcomes are never automatically retried.

## Presentation

The native thread follows the design spec in `docs/design-spec/` (page 9 is the handoff sheet, page 7 the tokens). It reads its own palette (`NativeTokens`, light and dark hex straight from page 7, flipped by the active Basalt variant), type ramp (`NativeFonts`) and sizes (`NativeMetrics`, `Radius`) in `Sources/ShepherdApp/DesignTokens.swift`. Terminal-mode chrome keeps the Basalt `Tokens`. The pure derivations (tool rows, DiffStat, durations, status pill, turns and turn items, group summary, head truncation) live in `Sources/ShepherdRemote/NativeThreadPresentation.swift` and are shared with iOS.

Layout: a 52pt header (project / title, status pill, turn count, Terminal/Native switch, options), a column capped at 1200pt with a 24pt gutter, agent prose capped at 1100pt, user turns as trailing bubbles (max 600, radius 12 with a 4pt bottom-trailing corner, bgBubble), no speaker labels. Consecutive tool calls collapse into one bordered group of 36pt rows (glyph, name, preview, result, duration, chevron only when the row has saved output); prose splits groups. Expanded rows show at most 12 output lines and link to Terminal for the rest; raw arguments stay behind ⌥-click "Show call". Thinking is a collapsed italic disclosure; the turn footer carries copy and the tool count. The composer (`DesktopNativeComposer.swift`) is a raised card with a gradient fade above it: field on top, one stable chip row (attach, model, thinking, delivery-while-running) and a single primary circle (Send / Stop / busy). A 22pt status line above it shows "Waiting for you · elapsed" while a question is pending; running state is the thread's working row, which carries the elapsed time. Standard dialogs replace the field inside the card (confirm → Allow once / Deny, select → stacked options, input/editor → field + Submit; "1/N" when several are queued). `/` at line start opens the inline command menu for RPC agents. Flow: a sent message is echoed immediately (`NativeThreadStore.pending`) and settles against the next snapshot; a persistent working row ("Thinking… / Working… / Running <tool>…") ends the thread while the agent runs, driven by a 400 ms debounced `settledRunning` so tool gaps do not flicker; scrolling follows the tail via the pure `NativeScrollFollower` (bb's rule: detach only on a live scroll gesture, re-stick within 4pt of the bottom; momentum, content replacement, composer resizes, and a short thread growing past the viewport are layout, never intent) and sending re-attaches to the tail; "↓ Jump to latest" returns. The composer's measured height is the scroll view's bottom safe-area inset, so the thread cannot be scrolled into blank space. Real-window coverage: `Tests/ShepherdAppTests/NativeScrollTests.swift` (opens at the bottom with no trailing space, growth keeps the tail pinned until a trackpad gesture, sending re-attaches). Prose renders through `nativeMarkdownBlocks` (headings, lists with one nested level, blockquotes, fences, rules). No key-hint row or working directory under the composer.

### Substitutions and spec items not honoured

- Fonts: the spec names IBM Plex Sans and JetBrains Mono. No fonts are bundled; prose is `.system(design: .default)` and code is `.system(design: .monospaced)` at the spec's sizes, weights and line heights.
- Header counter: the bridge reports no context size, so "Nk ctx" is omitted. The turn count shows only once the full history is loaded.
- Turn footer: the bridge carries no timestamps or turn durations, and the store has no retry, so the footer shows copy + "N tool calls" only. User bubbles have no timestamp for the same reason.
- Thinking: no thinking duration is available, so the caption is "Thought", not "Thought for Ns".
- Tool durations are measured by the view from the moment it first sees a running tool; calls that finished before the view opened show no duration.
- Composer: attachments are not supported by the bridge, so there is no attach icon. The `/commands` chip opens Terminal, where slash commands work. The model chip is read-only.
- Approval card: "Always for this agent" appears only when a select option literally offers it; pi's standard dialogs do not, so it is normally absent. Y/N answer a confirm only while the card itself has keyboard focus, so typing in the composer can never approve a command.
- Needs-approval tool rows: the bridge does not associate a pending dialog with a tool call, so tool rows have only running/done/failed states and the approval card renders after the turns instead of inline as a warning row.
- Key hints: ⌘⇧B and ⌘⇧S from the spec are not wired in the app and are not advertised; ⌘. stop is shown next to the Stop button because that button binds it.
- Sidebar: resizable (190–340pt, default 230) rather than the spec's fixed 256pt; sidebar collapse (⌘⇧S) and ⌥⌘↑/↓ turn jumping are not implemented. Rows are hover/click views with button traits and accessibility actions rather than SwiftUI `Button`s, so hover fills stay theme-exact.
- Inline code: code runs get the code face on `bgHover`; a per-run border is not expressible inside attributed `Text`, so only the fill marks the span.
- Tool-row status pill: "Running · elapsed" counts from when the header first observed the run; `Stopped` is never shown because the bridge reports no stop-vs-finish distinction.
- Unknown tool previews prefer an obvious action field (command/path/query/url/pattern) over the first output line, then cap at the spec's 120 characters.

Screenshots: [dark](screenshots/native-desktop/dark.png), [light](screenshots/native-desktop/light.png). Re-captured after the spec restyle (synthetic fixture data, dark and light).

## Validation

The combined full Swift suite passed with 411 tests, and both canonical Node extension tests passed. The final widget Unicode-ID regression and embedded-source checks also ran separately after review. Phase builds for macOS Dev and iOS Simulator succeeded; shared-store checks passed after extraction and widget integration.

A real Ghostty/PTY leaf test verified repeated presentation switches preserve the same NSView, session, hidden terminal output, native/terminal drafts, focus handoff, and terminal input. Another native-window test verified hidden polling stops and restarts with a fresh snapshot. Native primary eligibility excludes auxiliary/review/inspector/remote panes. Pending local requests settle on timeout, bridge disconnect/replacement, and shutdown, without requiring a TCP listener.

Controlled desktop and iOS views rendered text/status widgets and questions in dark/light mode. These snapshots use synthetic data, not a claimed live model conversation. Full desktop dialog-click, VoiceOver, physical Finder drag, and installed-pi end-to-end acceptance remain unverified in this preview. Ghostty rendering tests require an awake display; asleep displays caused both new and unchanged lifecycle tests to fail before rendering, then pass after waking without assertion changes.

All changes remain uncommitted on `feat/ios-native-mvp`, alongside the existing mobile Settings edits.

## Automated UI checks

Two opt-in tests exercise the native UI without a person at the keyboard. Neither touches the user's pi configuration, sessions, or a running Shepherd.

- **Real session render.** `SHEPHERD_REAL_SESSION=<session.jsonl> SHEPHERD_NATIVE_SCREENSHOT_DIR=/tmp/x swift test --filter realSessionRenders` projects the last page of a real pi session through the RPC transcript reader and captures `real-session.png` at 1500pt. Use it to find problems that fixtures never produce, such as provider errors, pi system entries, and long tool output.
- **Live end to end.** `SHEPHERD_E2E=1 SHEPHERD_NATIVE_SCREENSHOT_DIR=/tmp/e2e swift test --filter LiveEndToEndTests` builds the real view model and `RootView` over a real `SessionServer`. It starts an RPC agent on `pi --mode rpc` with the bundled children extension, backed by the scripted local provider `Tests/Extensions/e2e-provider.mjs`. Scratch `PI_CODING_AGENT_DIR` and `SHEPHERD_SUPPORT_DIR` directories keep it isolated, and it makes no network calls. The test finds controls by visible text with Vision OCR and clicks them with real mouse events, so hidden or clipped buttons fail the run. It spawns three children, inspects the running worker, pauses and continues it, answers the reviewer's question, waits for the ledger, opens a finished child, and sends a follow-up. It captures `e2e-1-live-cards` through `e2e-6-followup`.

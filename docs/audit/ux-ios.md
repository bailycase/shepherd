> Lane report from the 2026-10-27 audit. Static reading only (no build, no run) by a GPT-6 Astra (ui-ux-engineer profile) agent; line numbers are from commit d28f3511c. Live confirmation of overlapping items is in [live-usage-mac-ios.md](live-usage-mac-ios.md); the cross-lane ranking is in [README.md](README.md).

# iPhone / iPad UX audit

Static, read-only audit of `App/iOS` and shared remote presentation/state. No builds, tests, app launches, or repository writes were performed. Findings distinguish code-proven behavior from runtime risk; severity reflects user impact, not measured frame times. No supplied visual spec was changed; departures: none.

## Top 10 to fix first

1. **UI-01** — prevent sending before selected photos finish importing.
2. **UI-02** — preserve unsent drafts across process termination.
3. **UI-03** — stop pulling subagent readers back to the bottom.
4. **UI-04** — distinguish notification opt-in from successful host registration.
5. **UI-05** — surface terminal-start failures with Retry.
6. **UI-06** — distinguish transcript load failure from an empty transcript.
7. **UI-07** — explain offline cold-open thread screens.
8. **UI-08** — bound retained thread/history/attachment memory.
9. **UI-09** — make Home's unbounded thread sections lazy.
10. **UI-10** — remove cross-host head-of-line blocking in Home refresh.

## Findings, ranked by impact

### UI-01 · high — Sending races photo import
- **Evidence:** `App/iOS/Composer/ComposerControls.swift:30–40` starts an asynchronous photo import without publishing an importing state; `App/iOS/Composer/ThreadComposer.swift:278–279` gates Send on existing draft/attachments and store busy state only, and `:308–313` snapshots attachments. The same gap exists at `App/iOS/NewThread/NewThreadAttachments.swift:86–102`, `NewThreadModel.swift:82–92,321–325`.
- **User experience:** Select an iCloud photo, return to a typed message, tap Send: the message can go without the intended image. In an existing thread the image subsequently appears as an attachment to the *next* message.
- **Why bad:** Selection is not completion, but there is neither a pending attachment placeholder nor a send barrier. This is incorrect message content, not merely a missing spinner.
- **Smallest fix:** Track pending imports in the shared composer/new-thread model, show “Adding images…”, and disable Send/Start until imports finish or the user cancels them. Clear/decrement the pending count on every success and failure.

### UI-02 · high — Drafts survive navigation but not an OS-killed background session
- **Evidence:** `Sources/ShepherdRemote/NativeThreadStore.swift:137` initializes draft to an empty string. `App/iOS/Thread/ThreadStores.swift:5–24` retains stores only for the app lifetime. `App/iOS/Windows/MobileWindowSeed.swift:20–33,66–69` restores routes/selection but no drafts; `MobileWindowRoot.swift:25–35` persists only that restoration value. Composer attachments are likewise in-memory (`ComposerState.swift:20–23,205–220`).
- **User experience:** Write a long instruction, leave Shepherd, let iOS reclaim it, return to the same thread with the text gone. Ordinary foreground/background without termination is not the problem.
- **Why bad:** Navigation restoration creates a convincing return-to-work experience while the most valuable unfinished work is missing.
- **Smallest fix:** Persist unsent text keyed by host/agent on a debounce and scene background, restore it on store creation, and remove it on acknowledged send or host forget. Decide explicitly whether to persist attachments or explain their loss; do not silently restore text as if images also survived.

### UI-03 · high — Live subagent transcript overrides the reader's scroll position
- **Evidence:** `App/iOS/Subagents/SubagentRunScreen.swift:123–125` scrolls to `run-bottom` on every change to transcript turn count whenever the run is nonterminal. No user-scroll/tail-follow guard is checked. By contrast the ordinary transcript uses `NativeScrollFollower` (`ThreadScreen.swift:208–210,282,313`).
- **User experience:** Reading an earlier subagent decision is interrupted by every new turn; loading earlier turns can also jump back to the tail.
- **Why bad:** Being live is not the same as the reader choosing to follow live output.
- **Smallest fix:** Reuse the ordinary thread's tail-follow policy: suspend follow on user scroll away and offer Jump to latest.

### UI-04 · high — Push can look enabled before this Mac can send notifications
- **Evidence:** `App/iOS/Push/PushManager.swift:88–95` marks/persists enabled before registering with the host; `:198–201` returns successfully without doing anything if the host disconnected. `App/iOS/Push/NotificationsScreen.swift:79–97` displays that enabled bit with errors only when present.
- **User experience:** A connection drops during opt-in; the switch remains on with no registration error, but the Mac has not received the push registration. Reconnect retries later, so this is a misleading interim state, not necessarily permanent loss.
- **Why bad:** The boolean intentionally stores intent but the UI presents it as delivery readiness.
- **Smallest fix:** Keep opt-in persistence, add a “Waiting for Mac to connect” registration state, and clear it only after host acknowledgement. Show pending separately from an active subscription.

### UI-05 · medium — Failed terminal startup stays “starting session…”
- **Evidence:** `App/iOS/Terminal/TerminalPanes.swift:152–154` displays starting whenever there is no session ID. `:161–167` issues `.startTerminal` with `try?`, discarding any rejection/error; the task key changes only with pane/connection/activity.
- **User experience:** Terminal startup rejected on an otherwise healthy connection looks like indefinite progress. There is no error-specific recovery on this surface.
- **Why bad:** The existing session-link error presentation cannot help before a session exists.
- **Smallest fix:** Capture startup failure in pane state, replace starting with the reason and a Retry button that repeats the idempotent demand.

### UI-06 · medium — Subagent transcript failure becomes “No transcript yet”
- **Evidence:** `App/iOS/Subagents/SubagentTranscript.swift:60–62` sets `loaded = true` when the request returns nil, without an error state. `:156–161` renders the normal empty message; `SubagentRunScreen.swift:110–112` supplies “No transcript yet.” A terminal run gets no ongoing retries (`SubagentTranscript.swift:47–54`).
- **User experience:** A completed run with an unreadable transcript looks like it never produced output; a user cannot distinguish failed fetch from actual emptiness.
- **Why bad:** The transcript model collapses error and success-empty into one state, even if the parent store separately carries a notice.
- **Smallest fix:** Give this model loading/loaded/error states, show a local Retry, and keep genuine empty copy only for successful empty replies. Show initial loading progress rather than a blank transcript.

### UI-07 · medium — Cold-open offline threads have no offline explanation
- **Evidence:** `App/iOS/Thread/ThreadScreen.swift:181–185` returns nil when `agent == nil` and the host is not connected, before evaluating the offline banner. Composer and thread options are gated on agent presence (`:83,128,145`).
- **User experience:** Opening a deep link/restored thread before the host has supplied agent state lacks the helpful offline banner offered to a previously loaded thread. The missing controls make the screen harder to recover from.
- **Why bad:** “Agent not in fetched state” is conflated with “no status worth displaying.”
- **Smallest fix:** Evaluate connecting/offline host state before missing-agent state, and include Retry/Open host settings for an offline cold open. Only say the agent is gone after a successful host state fetch.

### UI-08 · medium — Visited threads and their heavy state are retained without a per-thread eviction path
- **Evidence:** `App/iOS/Thread/ThreadStores.swift:13–24,35–41` caches every visited store until host forget. `App/iOS/Composer/ComposerState.swift:205–231` retains per-agent composer states and prepared images until host forget. `App/iOS/Subagents/SubagentTranscript.swift:79–89` loads all historical pages on Show all.
- **User experience:** A long iPad supervision session that visits many threads and leaves images/drafts around can accumulate memory and eventually be terminated, compounding UI-02.
- **Why bad:** App lifetime is an unbounded retention policy; history and image bytes make the cost greater than a small navigation cache. Exact memory pressure requires profiling.
- **Smallest fix:** Preserve drafts separately, evict inactive clean thread/history caches with a small LRU, and prune deleted agents. Never evict a viewed store or unsaved attachment without preserving the user's work.

### UI-09 · medium — Home eagerly instantiates every Working/Done/Pinned row
- **Evidence:** `App/iOS/Home/HomeScreen.swift:16–23` uses a normal VStack within ScrollView; `:85–98` places unbounded `groups.working`, `groups.done`, and `groups.pinned` in cards. Only Needs you is explicitly limited (`:71`).
- **User experience:** Home becomes heavier to open and refresh for a fleet with hundreds of completed or pinned threads, even when most rows are offscreen.
- **Why slow:** ScrollView does not make its ordinary stack lazy; whole groups instantiate eagerly.
- **Smallest fix:** Use a lazy row container for unbounded sections, or match the existing capped Needs you pattern with See all. A lazy outer stack alone does not make a single giant card's internal rows lazy.

### UI-10 · medium — One slow host delays fresh Needs you data from every later host
- **Evidence:** `App/iOS/Home/HomeFeed.swift:126–143` awaits each agent request sequentially inside each host; `:174` derives/publishes only after all hosts finish. Quiet reads are capped at six per host (`:38–40,136–138`), but hot reads are not.
- **User experience:** Home/pull-to-refresh can keep showing old attention items while an earlier slow host or large active fleet finishes requests. A fast second Mac waits behind the slow first one.
- **Why slow:** Cross-host head-of-line blocking, with a final all-host publication barrier.
- **Smallest fix:** Publish changed results after each host and run host refreshes with small bounded concurrency; retain per-host request limits. Do not launch an unbounded task per thread.

### UI-11 · medium — Photo transfer failures silently discard selected images
- **Evidence:** `App/iOS/Composer/ComposerControls.swift:36` continues on `loadTransferable` failure. `:40` then calls `state.attach`; `ComposerState.swift:65–66` clears the attachment error at attach start. New-thread import already reports failed reads (`NewThreadAttachments.swift:97–100`).
- **User experience:** Pick several images; only some appear and no explanation identifies the missing ones.
- **Why bad:** Errors during transfer happen before the otherwise useful image-preparation error handling.
- **Smallest fix:** Preserve transfer failures and show a concise failed-image count/retry instruction; do not overwrite this with an empty successful attach call.

### UI-12 · medium — Update polling can leave controls stuck or stop with stale transient status
- **Evidence:** `App/iOS/Hosts/HostEditorScreen.swift:287–303`: the polling task returns on a disconnected client at line 293 without resetting `polling`; request failure breaks without recording an error; reaching 12 polls likewise ends with no timeout explanation. Controls are disabled by polling (`:175–180`).
- **User experience:** During connection loss the section can remain spinning/disabled until it is removed; a long update or transient fetch failure can leave a status such as downloading with no explicit verification/retry action.
- **Why bad:** Bounded polling is good, but cleanup and exhaustion are not modeled as user-visible outcomes. Disappearance/reappearance may mask the stuck flag in some connection transitions.
- **Smallest fix:** Use `defer` to reset polling, publish “Still updating—check status” on exhaustion, and expose a status-only Retry after request failure. Keep install non-retrying.

### UI-13 · medium — Explicit Follow on Lock Screen failures are silent
- **Evidence:** `App/iOS/Home/ThreadRowMenu.swift:46–49` offers Follow on Lock Screen; `App/iOS/Glance/GlanceBridge.swift:145–150` uses `try? Activity.request` and returns no result or error. Unlike automatic Watch creation (`:109`), this path does not first check activities authorization.
- **User experience:** Tap Follow with Live Activities disabled or unavailable and nothing happens.
- **Why bad:** An explicit user command needs acknowledgement; silently ignoring an optional automatic feature is not an appropriate interaction pattern here.
- **Smallest fix:** Return a result from follow, show authorization/unavailability errors, and confirm successful following in observable state.

### UI-14 · medium — Follow promises outlast its actual foreground-only freshness
- **Evidence:** `App/iOS/Glance/GlanceBridge.swift:50–55,76–80` stops foreground polling and refuses publishing when backgrounded; `:144` describes following until the thread ends. Activity creation at `:148–150` provides no push token type. The menu calls it “Follow on Lock Screen” (`ThreadRowMenu.swift:49`).
- **User experience:** Follow a running thread, lock the phone, and its activity stops receiving these local updates; eventually it becomes stale rather than tracking completion. Push notifications are a separate opt-in channel, not Live Activity content updates in this code.
- **Why bad:** The named action suggests lock-screen tracking, while its usefulness changes when the device is locked. Stale-date handling is correctly present and should remain.
- **Smallest fix:** State the limitation where Follow is offered (“Updates while Shepherd is open”) and point to Notifications for background alerts. True remote Live Activity updates are a larger product change, not required for the copy fix.

### UI-15 · medium — A single reconnecting host freezes glance updates for healthy hosts
- **Evidence:** `App/iOS/Glance/GlanceBridge.swift:84–85` returns if *any* host is connecting or disconnected, before constructing/writing the snapshot or updating activities (`:86–93`).
- **User experience:** Reconnection to one unavailable Mac delays widget/Live Activity freshness for another Mac that is working normally.
- **Why bad:** Preventing a reconnect from falsely deleting that host's threads is correct; gating the entire fleet is unnecessarily broad.
- **Smallest fix:** Preserve the reconnecting host's last snapshot with explicit stale status, while publishing new data for settled hosts.

### UI-16 · medium — Copy patch gives neither failure nor success feedback
- **Evidence:** `App/iOS/Review/PadReviewScreen.swift:364–365,373–377` offers Copy commands, discards patch-request errors with `try?`, and silently updates UIPasteboard on success.
- **User experience:** Copy can appear to work but leave the previous clipboard contents intact after a network error. Pasting later reveals the failure.
- **Why bad:** A remote asynchronous copy is not an immediate local copy; it needs completion feedback.
- **Smallest fix:** Show loading/disable repeat invocation while fetching, display the error with Retry, and show “Patch copied” or “Command copied” on completion.

### UI-17 · medium — Steer now is hidden behind holding the Send button
- **Evidence:** `App/iOS/Composer/ThreadComposer.swift:278–287` exposes alternate delivery only via a context menu; `:288–295` provides VoiceOver actions, so this is a sighted discoverability problem, not an absent accessibility action. The visible normal button remains Send/queue.
- **User experience:** A user who needs to interrupt a running agent may assume the only route is Stop followed by Send and never find Steer now.
- **Why bad:** A consequential difference in delivery semantics is buried in a gesture with no visible affordance.
- **Smallest fix:** Add a visible menu affordance or a brief contextual “Hold Send to steer now” hint while running; preserve normal tap-to-queue behavior and existing accessibility actions.

### UI-18 · low — Notification permission denial offers prose but no route to repair
- **Evidence:** `App/iOS/Push/PushRelay.swift:183` says to enable permission in Settings; `NotificationsScreen.swift:93–98` only renders the string. Retry is offered only for revocation (`:73–77`), not permission recovery.
- **User experience:** A denied user repeatedly toggles without seeing another permission prompt, then must locate Shepherd in system Settings manually.
- **Why bad:** iOS permission denial needs a Settings handoff, not another in-app authorization attempt.
- **Smallest fix:** Expose a typed permission-denied state and an Open Settings button using the platform settings URL; refresh authorization status on return.

### UI-19 · low — Host field validation is detached from the field needing correction
- **Evidence:** `App/iOS/Hosts/HostEditorScreen.swift:51–66,93–98,114–123` validates on Save and shows one generic-titled alert, with no field-linked validation/focus state.
- **User experience:** Invalid address/port/token interrupts the whole form; after dismissal the user must locate the field themselves, especially awkward with a keyboard and large text.
- **Why bad:** Specific error text helps, but modal-only validation adds a repair step and loses field context.
- **Smallest fix:** Retain the parsed validation result per field, show its message inline, and focus the first invalid field. Keep alerts for actual keychain/persistence failures rather than input errors.

## Already good — preserve these

- **Home refresh exists:** `HomeScreen.swift:30–34` explicitly retries offline hosts and refreshes the feed. Do not report a blanket missing pull-to-refresh bug.
- **Connection recovery is real:** `HostEditorScreen.swift:25–40` shows connection/failure details and Retry; `MobileHosts.swift:225–230` resets reconnect backoff. Token input is secure and a saved token can be retained (`HostEditorScreen.swift:63–65,116`).
- **Draft/navigation lifetime within a running app is intentional:** shared thread/composer state preserves work across navigation and windows (`ThreadStores.swift:5–9`); route restoration is implemented (`MobileWindowRoot.swift:25–41`). UI-02 specifically concerns process death.
- **Main transcript uses a reader-aware follower:** `ThreadScreen.swift:208–210,282,313`, unlike the subagent case.
- **Heavy image preparation is already off-main:** `ComposerState.swift:74–79` and `NewThreadAttachments.swift:97–98`. Do not replace it with main-thread decoding.
- **Accessibility work is present:** message field has a label; Send has semantic labels and alternate accessibility actions (`ThreadComposer.swift:220–227,288–295`); remove-image buttons have names and touch-sized frames (`NewThreadAttachments.swift:122–132`).
- **Adaptive layout is deliberate:** size-class shell selection (`MobileRoot.swift:24–30`), window geometry/fold-aware split layout (`PadShell.swift:29–48`), and composer overflow fallback (`ThreadComposer.swift:196–209`). Do not infer device-idiom rigidity.
- **Background networking is constrained:** visible/active viewer gating (`ThreadScreen.swift:159–169`), foreground-only glance publishing and explicit stale dates (`GlanceBridge.swift:50–55,79–99`).
- **Push revocation errors are not silently discarded:** persisted pending revocation and Retry (`PushManager.swift:52–55,126–135`; `NotificationsScreen.swift:73–77`).

## Needs runtime confirmation (not additional confirmed defects)

- **Keyboard avoidance on iPad/Duo:** `PadShell.swift:105` ignores keyboard safe area around the shell while thread content uses a bottom safe-area inset (`ThreadScreen.swift:81–89`). Verify the composer and question actions stay visible with software/floating keyboards, split view, and fold arrangements; do not declare overlap from this modifier alone.
- **Resize focus/selection stability:** `PadShell.swift:60–99` uses a 600 ms column-settling window and uncancelled refocus-clear tasks. Rapid resize/fold/unfold may race, but geometry/keyboard repro is required.
- **Dynamic Type and minimum touch targets:** verify accessibility sizes on phone, narrow iPad columns, composer chips, question options, terminal keys, and notification toggles. Tokens and shared controls may already provide adequate targets; fixed-looking local frames are not proof of failure.
- **VoiceOver:** check announcement of asynchronous errors, photo importing, push pending states; verify combined accessibility elements retain toggle/button operation and logical reading order.
- **Home scaling / memory:** measure launch, scroll and refresh with 100–1,000 threads, multiple slow hosts, and many visited histories/images. Static findings UI-08–10 identify mechanisms, not measured thresholds.
- **Subagent loading:** confirm where parent-store notices appear in compact inspector versus full run screen; even if visible, transcript-specific empty copy should not contradict failed loading.
- **Live Activities:** lock the device, disable Live Activities in system settings, finish a followed agent, and reconnect one of several hosts; verify stale wording, actions and completion behavior rather than assuming OS presentation.
- **Offline/restored routes:** launch a notification/deep link without a cached host state; verify UI-07 does not get an explanatory loading surface from outer navigation.
- **App termination and attachments:** reproduce process-death draft loss using a development/scratch setup only; test pending photo imports followed by Send, dismissal and rapid host changes.

No speculative visual redesign, TLS redesign, or new dependency is proposed. The highest-value work is truthful progress/error state, preservation of unfinished work, and removing unnecessary interference with reading.

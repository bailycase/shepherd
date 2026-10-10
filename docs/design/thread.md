# Thread

> Read when you change how a thread draws: turns, activity lines, prose, errors, starting, following.

`ThreadView` (`Thread/ThreadView.swift`) lays out the rows `NativeThreadStore` derives once per
change (`NativeTurnPresentation`, `NativeActivity` in ShepherdRemote); the views only draw them.
Dimensions are in `AppLayout+Thread.swift` and ShepherdUI's `NWThreadMetrics`.

The Night Watch Thread boards are the authority for every part below: NWThread in dark, and
NWThreadLight, the same parts on the light roles with nothing else changed. Main (a thread at
rest) and Running (a thread while pi works) show the parts assembled in the window, and ToolRows
the activity line's states. Main and Running draw some parts at other sizes (prose at 15,
bubbles at 14 with 12×16 padding, times and footer meta in mono 11, 28pt footer buttons) and
their meta in a gray that is no Night Watch role (`#767c85`); where they differ, NWThread's
values, below, are the rule. Main (and the Subagents board's inspector) still draw the stretch
summary the component boards dropped in v97 ("Worked for 2m 12s · explored 1 file · …"):
NWThread, ToolRows and LiveText, one line per burst, are the rule.

- **Layout:** a scroll view with the column centered, at most 820pt wide with 32pt gutters (16pt
  in a thread narrower than the column and both gutters, 884pt; `AppLayout.threadGutter`). User
  bubbles are at most 600pt and agent prose keeps a 640pt measure inside it; there are no speaker
  labels. 28pt top margin, 28pt between turns, 14pt between a turn's parts, 10pt between blocks
  inside one part ("From the queue" above its bubbles), 6pt between
  one turn's bubbles, and 6pt between consecutive activity lines (NWThread; ToolRows and Running
  draw 4pt, see Known gaps).
- **Following:** the thread follows the tail only while the reader is within 80pt of the bottom
  (`NativeScrollFollower`). Only a live scroll gesture or a wheel tick detaches it; content
  growth, the composer resizing, and history swaps never do. From macOS 27 the Mac thread
  follows by scrolling alone: while following it sets no `defaultScrollAnchor` (neither the initial
  offset nor size changes), because a bottom anchor over the lazy stack, whose unmeasured rows are
  estimates, left the scroll view's content size at odds with where the rows were placed and the
  viewport drew nothing (a blank thread after a send or a finished turn, in a window of modest
  height; `ThreadTailAnchor`). A detached reader on this scrolling-only path uses a top anchor
  for size changes only. Collapsing a live reply preserves its content offset instead of moving
  that reader to the tail; the initial offset and short-content alignment stay unchanged.
  Before 27 the anchors stay: `scrollTo`, the only way to the tail
  without them, builds every row of a long thread there, so a short window can still draw blank
  on macOS 26 (a known issue, `ThreadBlankScreenTests`). Without an anchor every reading is the
  layout's own: a following view that growth,
  the composer or a settling turn leaves above its tail, or that a shrinking history or the
  composer collapsing leaves past it, returns to it at once. The native top-margin allowance
  and fitting content's normal empty space do not trigger overscroll recovery. (The iOS thread
  and the Mac thread before 27 anchor natively, so they let the anchor settle a view past the
  end first.) The Mac thread also watches which rows SwiftUI says are in view
  (`ThreadTailGuard`). The lazy stack guesses the heights of the rows it has not measured, and
  over rows of very different heights (a long answer, a turn of a hundred tool calls) the
  guesses move by thousands of points under a view that follows its tail: a turn settling into
  its footer, the terminal panel or the composer resizing, a long history opening. That can
  leave the scroll view at an offset its numbers call the tail but that lies past every row the
  stack placed. Nothing is realized there and nothing moves it, so the thread draws nothing, in
  a window of any height, and a view that keeps following lets the reader scroll no way out of
  it. The guard notices that no current content row is in view, even when the invisible bottom
  marker or a cached target from a replaced live reply is still reported visible. Completion can
  replace that reply's ID when its prompt falls outside the saved history page. Neither the marker
  nor a removed row may end recovery. Current-row IDs can be cached too: the Mac thread now
  requires a live, nonhidden native row marker intersecting its own clip view before treating a
  reported row as content. Each lazy row has one passive, accessibility-hidden background probe;
  the registry holds it weakly and drops obsolete IDs. Missing or dead probes prove nothing.
  This is placement evidence, not a paint check: the giant-history/native/900pt hosted failure
  still needs validation; a visible marker cannot prove that its sibling text was drawn.
  After an unsuccessful walk, a cached bottom marker must
  not suppress the final tail landing when no current row is in view. If all eight scrolling
  attempts still leave the thread stranded, the guard recreates only the transcript scroll view once.
  A current row in view is not enough when the bottom marker remains missing more than 80pt above
  the tail: completion can leave the final answer unrealized even after walking and landing exhaust
  their budget (`ThreadTailGuardTests`). A collapsed lazy layout can also report content that fits
  the viewport while placing every row outside it, so there is nowhere to scroll. The composer stays mounted, keeping its draft and controls. Hidden threads
  and detached readers never trigger this fallback. A send or completed turn permits a fresh bounded
  recovery; restarts keep no repair state. It also notices a following thread resting more than 80pt
  above its tail. A cached visible bottom marker cannot override that measured gap. It waits for
  quiet layout, at most 160ms for a
  blank thread, and lands on the tail again; when that is not enough it
  walks the scroll view back toward the rows and then down a page at a time until the marker is
  in view. A repair is not over until the thread has been seen resting on its tail: the follower
  stands aside while the guard walks, so a thread that grew meanwhile (the "Thinking…" line of a
  send) came to rest above its tail with the marker back in view from under the composer, and
  the guard takes it the rest of the way by scrolling to the end of the scroll view itself
  (`ThreadTailGuardTests`; one steer-now send in sixteen ended 38pt short for good). A reader's
  scroll, or one that just ended, is never moved, and a thread that is not
  stranded is never touched (`ThreadTailFlowTests`). A turn finishing renews the bounded
  recovery attempts. An earlier failed repair must not disable them for later turns. While a
  gesture is live, layout changes never move the view either: a drag up measures the rows it
  reveals, and landing on the tail then would pull the thread out from under the finger. "↓ Jump to latest"
  (`NWJumpToLatest`, a `bgRaised` capsule above the composer) appears while detached if the
  agent runs or unseen output arrived: new rows or the last one growing, never the content
  height alone (a scroll or a turn jump measures the rows it reveals). The composer draws it
  over the fade it lays on the thread and under its card and menus, so the fade never washes it
  out and it never covers an open menu. A send that goes in now (pi idle, or a steer)
  re-attaches to the tail. On Mac, a thread already following lands the echo and the
  completed-subagent tray collapsing together as their layout arrives, without duplicate send
  jumps. A late upward offset adjustment is corrected while following, even if layout arrived
  earlier.
  A reader scrolling away or jumping to another turn cancels following; layout recovery never
  moves the view during a live gesture. A follow-up
  that waits in Up next leaves the reader's place alone, then and when it goes: its delivery is
  new output like any other. The composer floats over the scroll view, which is inset by the
  composer's measured height plus 24pt of transcript breathing room (`composerTranscriptGap`),
  in running and idle states alike. The extra space stays outside the composer card and preserves
  the same gap while the reply streams or the composer grows.
- **Turn jumps:** ⌥⌘↑ and ⌥⌘↓ move between user turns (the target lands at the top); stepping
  past the last returns to the tail.
- **History:** on Mac, iPhone and iPad, reaching the top of loaded history automatically fetches
  one older page while the thread is active and ready, without a button or menu item. Native scroll
  visibility triggers the fetch; stable turn identities and native scroll position keep the visible
  turn in place as older rows prepend. On the Mac a boundary-row anchor also preserves its exact
  viewport offset through lazy remeasurement, including a partially clipped row. Pending native
  layout finishes before the anchor offset is measured; a materialized marker alone does not mean
  its frame matches the drawn row. A new scroll,
  turn jump, send, session change or hiding the thread cancels that restoration, so a late page
  never takes back the reader's newer navigation. Each visit to the top fetches at most one page, never an
  unbounded drain of history; another scroll away from the top arms the next visit, not layout
  hiding and revealing the top while a page prepends. An unchanged or failed cursor is not automatically retried by layout
  or polling; a changed cursor or session permits another fetch.
- **Notices** above the thread explain degraded states in caption tertiary: "Last known thread ·
  refreshing before enabling actions", "This host's agent cannot answer questions here · update
  Shepherd on the host", and one line for each thing the host reported shortening
  (`NativeClipNotice`; docs/native-thread.md › RPCThreadState › Clipped): "Some messages couldn't be
  read from pi · they appear after the agent's next reply", "Part of this turn's output is hidden
  while it runs · it shows when the turn ends" (only while the thread runs), "A question from the
  agent is too large to show here" (or "N questions from the agent are too large to show here"),
  and, from a host that names no cause, "Some output is clipped". Each goes with its cause, none
  has an action, and older pages to scroll up to or a long message (its row says "Output
  truncated") draw no notice. They sit above the first turn, like the others.
- **Starting:** while pi boots (a new agent, or one resuming after a relaunch) the thread is
  ready to use and quiet, never an error: it draws what it knows at once (a new agent's empty
  state, or its opening prompt as a message pi has not read yet, at 70%; a resuming agent's
  history), and a message sent meanwhile waits for pi. The opening prompt is the row pi's first
  snapshot carries, so it stays put when pi answers and when pi starts the turn; the device that
  created the agent draws it, and every other viewer sees it in that first snapshot. Nothing says
  pi is starting unless pi is slow: past two seconds (`AppLayout.startingIndicatorDelay`), well
  beyond a normal start (pi answers about 0.8 s after ⌘N, about 1 s after a relaunch), or past
  half a second (`AppLayout.blankStartingIndicatorDelay`) while the thread has nothing to show
  (a remote agent's, or one whose session file cannot be read). Then the composer's control row
  says so (see Composer › States). There is no spinner in the thread and no starting row at its
  tail. A pi that has not started after a minute gets the error banner.
- **Resuming:** an agent resuming after a relaunch shows its history at once, read from pi's
  session file (`PiSessionPreview`): the newest page, the model, and the thinking level, drawn
  exactly as pi's history is. Nothing in it acts yet (retry, load older, subagent actions)
  until pi answers, and pi's first snapshot then lands on the same rows, so nothing moves or
  flashes. Only what pi alone knows arrives with that snapshot: the "/ commands" chip (and the
  placeholder's "or / for commands"). An agent whose file
  cannot be read stays blank until pi sends its history.
- **Can't start:** a pi that stops before it serves the thread keeps its agent. Nothing is
  deleted, and the thread keeps what it drew while pi started: a resuming agent's history from its
  session file, a new agent's empty state and opening prompt. The composer says why and offers
  Retry (Composer › States › Can't start); the thread adds no row, no notice and no spinner. The
  host names the cause from pi's exit and its last lines on stderr (`NativeStartProblem`): pi can't
  reach a model (not signed in), an extension failed to load, Shepherd can't find its pi, its pi
  home overlaps the user's own pi (so Shepherd starts none), pi didn't find the conversation it was resuming and would start a new one (Shepherd stops it first, so
  nothing is written), or pi exited with its own words. Retry starts pi again and the thread is
  Starting once more; a new agent's opening prompt, which pi never read, goes with it. A pi that
  exits after it has served is the lost connection (Composer › States › Error), and its agent
  retires as before. Remote viewers read it from the host's snapshot
  (`NativeThreadSnapshot.startProblem`), without Retry, since starting pi belongs to the host: a
  Mac draws the same banner, and iPhone and iPad say it in the thread's notice line.
- **Waiting to continue** (`NWAgentWaitingLine`; PiImportProgress, PiAuthStates): while the first
  launch's copy holds a restored agent, its thread ends with one static line, `NW.Space.l` under
  the last turn in the thread's column: a card (`bgSunken`, radius 10, `lineSubtle`, 10×14) with
  a `clock` 14pt in `textSecondary`, "Waiting to continue" in 13/500 over "It picks up once your
  pi is brought over." in 12.5 `textSecondary`, and "restored 9:41 AM" in mono 11 `textTertiary`
  trailing. It goes, with no motion, when the agent picks up.
- **Not signed in** (`NWAgentNotSignedInCard`; AgentNotSignedIn, PiAuthStates): a pi that can't
  start because no sign-in covers its model shows a card at the end of the thread instead of the
  composer's Can't start banner: `lantern` at 28% for its line and 5% for its fill, radius 10,
  14×16, 12 between its parts. A 30pt `lanternTint` tile at radius 10 with `key` 18pt
  `lanternText`; "Not signed in to Anthropic" in 14/600 over, 3pt under it, "This agent uses
  `claude-opus`. Anthropic’s sign-in was skipped when your pi came over, so the agent is waiting
  for you. Your message is kept." in 13/1.5 `textSecondary` (the model in mono 12.5
  `textPrimary`; "Shepherd’s pi isn’t signed in to Anthropic, so …" when no copy skipped it; "a
  provider" when pi names none); the time it stopped in mono 11 `textTertiary` trailing. Under
  it, 42pt in: Sign in to Anthropic (primary, small, `key`), which opens Settings ▸ Pi ▸ Sign-in
  scrolled to Anthropic and starts its sign-in, and Use another model (ghost, small,
  `arrow.triangle.swap`), a menu of the models Shepherd's pi can use now (its catalog, without
  the missing provider's): the model picked starts pi again on it (`--model`, even for a
  conversation that resumes). The
  message (a new agent's opening prompt pi never read) is kept either way. When the sign-in
  lands the agent starts again by itself; the card goes when pi does.
- **Empty thread:** a framed `NWEmptyState` (a dashed `lineStrong` border, no crook): "New
  agent in `~/path`" (the path in Geist Mono 15 medium within the 17pt title), with "Describe
  the task. Drop or paste images to attach them, or type / for commands." A new agent is known
  to be empty, so it shows from the first frame, with the composer ready, while pi boots behind
  it. While a thread's history is not known yet (a resuming agent without a readable session
  file) the thread stays blank until pi sends it; an empty history then fades the state in.

**User turn** (`UserTurn` in `Thread/ThreadTurns.swift`, on `NWUserBubble`):

- Right-aligned, at most 600pt, `bgBubble` with a 1px `lineStrong` line, radius 8, 10×14
  padding, body text (13.5) at a 1.5 line height, selectable. No avatar and no name.
- The time ("2:41 PM") sits 5pt beneath in mono 10.5 tertiary, only while the turn is hovered
  (see **Details on hover** below): at rest it keeps its line and draws nothing.
- **Attachments** (`NWAttachmentChip`, NWThread) sit above the text inside the bubble, 6pt apart
  and 8pt above it. A chip is 26pt with a 1px `lineStrong` line and radius 6, its name in 12pt
  `textPrimary` truncating in the middle, 6pt gaps. An image chip leads with its 20pt thumbnail
  (radius 4, 3pt from the chip's edges); a file chip leads with the `doc` glyph in
  `textSecondary`, 8pt from each edge. In the composer a chip ends with a remove × in
  `textTertiary`; in a sent bubble it has none. Images travel as image payloads; local file
  attachments currently travel as paths in the message (see Composer › Images and files).
  Design references show as chips after them; an element picked in the Browser rides with the
  send but draws no chip on the sent bubble (no board draws one there, the user's decision,
  2026-09-29): only the composer's chip and the queue row's stand for it (Side pane: Browser).
  - **Not built yet.** A sent bubble's chips show each image's thumbnail and file name, as the
    board draws `screenshot.png`. Today they read "Image" behind the file glyph, because the
    thread keeps only how many images a message carried.
  - **Partially built.** Local files dropped on a thread attach as removable file chips in the
    composer and ride with the message as paths. Sent file chips and remote file uploads are
    not built; the paperclip still picks images only.
- A message sent while pi is idle shows at once, at 70% opacity until pi reads it. One sent
  while pi works never enters the thread early: it waits in the composer's **Up next** (see
  Composer) and joins the thread only when pi reads it, where pi read it.
- **From the queue:** messages the queue delivered together (one turn for pi) open with
  `NWQueueDivider`, "From the queue · 2" (just "From the queue" for one) in caption tertiary
  with the queue glyph between two hairlines, then one bubble per message, 6pt apart, each with
  the time it was sent (on hover, like any bubble's).
- **Steered:** a message steered into a running turn stands inside that turn where pi read it
  (after the tool calls it waited on, at the turn's 14pt item spacing), so the turn keeps one
  footer and one changes card. Its bubble wears "Steered" above it (`arrow.turn.down.right` 11
  and caption medium, both `running`) and a `running` line instead of `lineStrong`; its time
  shows on hover. After a relaunch a steer pi read after its final message reads as an ordinary
  new turn.

**Agent turn** (`AgentTurn`): consecutive assistant messages render as one turn. Its parts are
thinking, prose, activity lines, subagent cards where their spawn calls were, notes, and errors,
in the order they happened (each stretch of work between prose opens with its thinking). Once
the turn has finished, the changes card and the footer end it. A running turn has no footer.

- **Prose** (`Prose` in `Thread/ThreadMarkdown.swift`, on `NWAgentProse`): body 13.5/1.6 in
  `textPrimary` at the 640pt measure, blocks 12pt apart, selectable, with no speaker label.
  Markdown is parsed once per turn:
  - headings at `headline`, with 4pt more above them
  - lists indented 20pt per level to any depth (the marker right-aligned 6pt before the text),
    items 4pt apart
  - bold and italic as Markdown gives them
  - quotes in italic `textSecondary`, 12pt past a 2pt `lineStrong` rule
  - inline code in mono 12 on `lineSubtle` (the board's `bgSunken` with a 1px line cannot ride a
    text run; see Where Shepherd departs from the boards), links in `running`, not underlined
  - rules as hairlines, 4pt above and below
  - tables, task lists, images, disclosures, footnotes and inline HTML as in **Rich content in
    prose** below
- **Code blocks** (`HighlightedCodeBlock` on `NWCodeBlock`): `bgSunken`, a 1px `lineSubtle` line,
  radius 8, as wide as the prose measure. A 28pt header (12pt leading, 6pt trailing, a hairline
  beneath) holds the language (or "code") in mono 10.5 tertiary and a 22pt copy button (`doc.on.doc`
  in `textSecondary`) that appears on hover or
  keyboard focus and turns into a check with a pop for 1.5s after a copy. Code in mono 12 at 1.6
  with 10×12 padding, in the Syntax roles (`synKeyword`, `synType`, `synString`, `synComment`, …),
  scrolling sideways only when its longest line does not fit, never wrapped. On the Mac, one
  selectable AppKit text field draws the code and its syntax attributes, avoiding SwiftUI's
  per-run text resolution while a reply grows. Text scale, appearance and Copy stay the same.
  Tree-sitter colors it off the main actor in the block's task (Swift, Python, Go, Rust, JavaScript, TypeScript/TSX, C,
  C++, shell, Ruby, JSON); the first frame is plain, results are cached, and a block that grows
  while streaming keeps its last colors until the new ones are ready.
- **Thinking** (`NWThinking`): the thinking in one stretch of work (between prose blocks) folds
  into one block at the start of that stretch, so per-call reasoning never splits the activity
  lines.
  - Collapsed: a 10pt chevron (pointing right, turning down as it opens) and "Thought for 4s" in
    italic 12 `textSecondary`, 6pt apart ("Thought for 1m 04s" past a minute; "Thought" when
    shorter than half a second or untimed). The whole label is the button.
  - Expanded: 8pt beneath, the text in italic 12.5 at 1.55 in `textSecondary`, 12pt past a 2pt
    `lineStrong` rule, at the prose measure. It opens and closes with `disclosure`. The text is
    Markdown (reasoning summaries are: GPT's open with a bold title, "**Inspecting SSH
    config**", then a paragraph), drawn by the prose parts in thinking's voice: bold, italic,
    code spans and links inline (as in prose); paragraphs, lists and quotes as blocks, 8pt
    apart; headings semibold at the same size; fenced code as a code block. It is parsed once per
    change of the turn (`NativeTurnPresentation`, memoised by the store, so a reply streaming
    under it never parses it again), and live thinking, which shows no text, is never parsed.
    The host normalizes the text first (docs/native-thread.md › Thinking text), so a summary
    part pi left empty leaves no gap.
  - Live (LiveText): "Thinking…" in italic `ui` (12.5) shimmering on a 26pt row, with no clock
    and no chevron (nothing opens yet; see the departures), its words where the finished row's
    are. It is the thread's live line between tools (see Live text), and when thinking ends it
    cross-fades in place into what the finished row is (below), or leaves.
  - Finished, by what the stretch carries. Providers often keep their reasoning back
    (Anthropic's redacted or omitted thinking, OpenAI's encrypted reasoning, a proxy that
    streams none), and pi keeps that as a thinking block with no text; readable text is
    anything but whitespace, a summary pi left only in the block's signature included, and a
    folded row shows only the blocks that have it.
    1. Readable text: the disclosure above.
    2. No readable text, timed at half a second or more: "Thought for 10s" as a plain line, the
       collapsed label's words, type and color with no chevron, where a disclosure's label
       sits (the chevron's place stays). It is not a control (no hover, no press, no focus);
       its tooltip and VoiceOver say "Thought for 10 seconds. The model didn't share its
       reasoning."
    3. No readable text and no such time: no row.

    The NWThread board draws only the first; the other two are app states it does not draw.
- **Notes** ("Image attached", "Output truncated", extension messages) render as caption
  tertiary text on a 2pt rule (three lines, full text on hover).
- **Errors** (TurnErrors, ThreadError, ThreadErrorDetails; `NWTurnError`, `Thread/TurnErrors.swift`,
  read by `NativeTurnError` in ShepherdRemote once per change): a request to the model that failed
  (pi's assistant message with `stopReason` `error` and its `errorMessage`), the error itself,
  readable. Tool failures stay in their activity lines.
  - **The card** spans the column (not the prose measure): `bgRaised`, a 1px `lineStrong` line,
    radius 10 (`NWTurnErrorMetrics`), 14×16 inset. A 28pt tile at radius 8 on `failedTint` holds
    the kind's 14pt glyph in `failed` (`exclamationmark.triangle`; `hourglass` for a timeout,
    `wifi.slash` for the network, `arrow.down.right.and.arrow.up.left` for a thread too long);
    12pt right of it, 5pt apart: the **title** (Geist 14/600, and the time in mono 11 tertiary at
    the trailing edge), the **message** (13 `textSecondary`), the **facts** (2pt more above: the
    status and type as mono 10.5 chips, `NWTag`, then "gpt-5 · OpenAI" and "· Tried 3 times over
    31m" in 12 tertiary), and the **actions** (6pt more above): Retry (secondary `s`, when it
    ended the latest turn; tooltip "Retry this turn"), Copy (a 26pt icon circle), and "Details ›" (12.5 `textSecondary`) at the
    trailing edge. It rises in like a row (`list`).
  - **Title,** from the status and type: "OpenAI rejected the API key" (401, an authentication
    type), "OpenAI didn’t respond in time" (a timeout, 408, 504), "OpenAI is overloaded" (529,
    `overloaded_error`), "OpenAI had a server error" (500, `server_error`), "Rate limited by
    OpenAI" (429, `rate_limit_*`, `RESOURCE_EXHAUSTED`), "Couldn’t reach OpenAI" (a network error
    with no status), "The thread is too long for gpt-5" (`context_length_exceeded`), else "The
    request to OpenAI failed". Without a provider: "The provider …", "The model request failed".
    Providers are named as people write them (pi's `openai` is OpenAI).
  - **Message:** the provider's own words out of pi's text ("401: {…}", "429 Rate limit…",
    "OpenAI API error (401): …", an OpenRouter wrapper's upstream message), cleaned: keys cut to
    their first eight and last four ("sk-svcac…fvMA", in mono `textPrimary`), links clickable
    ("platform.openai.com/account/api-keys" in `running` 12.5 with `arrow.up.right.square`), names
    the provider quoted in backticks in mono, no JSON, no escaped quotes. A network error says
    where from: "`api.openai.com` didn’t answer from build-01: connection reset.", with the errno
    and the host as chips.
  - **Details** opens in place under a `lineSubtle` hairline (14pt above, 16 below, 52 leading):
    the facts (a 250pt column, 70pt labels in 12 tertiary, values in 12 `textSecondary`, mono but
    the provider): Provider, Model, Host (the machine the agent runs on: this Mac's name, or a
    remote host's), Status, Type, Code, Request, At (with seconds); 24pt right, everything the
    provider sent back pretty-printed in the provider's key order (mono 11.5 on `bgSunken`, radius
    8, a `lineSubtle` line, 10×12 inset): keys in `synFunction`, strings in `synString`, a cut key
    on `bgSelected`, addresses underlined in `running`. Keys stay cut here too. What isn't JSON
    shows as it came. Details and a folded error's opening are kept by the thread's store
    (`NativeTurnErrorExpansion`), so a row the list rebuilds keeps them.
  - **Copy** puts the whole error on the pasteboard as text, redacted the same way: the title,
    the message, the facts line, each fact, and the body.
  - **Folded** (`NWTurnError(folded:)`): when the next reply fails the same way (the same kind,
    title and chips), the earlier card folds to one 26pt line: the 13pt glyph in `failed`, the
    title in 12.5 `textPrimary`, "401 · 5:52 PM" in mono 11 tertiary, and a 10pt `chevron.right`.
    A click opens the card. An error pi retried past, the turn going on, folds the same way.
  - **While pi retries** (`NWRetryLine`; the snapshot's `retry`, from pi's `auto_retry_start`
    until `auto_retry_end` or it settles): the live turn ends in one 26pt line, the only thing
    moving: `arrow.clockwise` (an `hourglass` for a timeout) in `textSecondary`, "OpenAI is
    overloaded · retrying in 8s" shimmering (counting down each second, then "· retrying"), and
    "2 of 3" in mono 11 tertiary. The failed tries merge into one error, so the card that shows once
    the retries are used up says "Tried 3 times over 1m 40s" (from the first try to the last).
  - **Touch sizes** (TurnErrors › Touch sizes; iPhone and iPad alike): radius 12, a 14pt inset,
    the title at 15/600 and the message at 14; the time joins the facts line ("gpt-5 · OpenAI ·
    5:54 PM"); Retry is secondary `l` (32pt) and Copy a 32pt circle; the folded line is 36pt at
    13.5. Details stacks the facts above the body, 12pt apart, in a 12×14 inset, the body in mono 11.
  - A turn that ends in an error has no footer: the card carries its Retry and Copy. An earlier
    turn's card has no Retry (see Footer).
  - **Not built yet:** a timeout's own sentence and length ("No response after 10 minutes, so the
    request was cancelled. Nothing in the thread was lost.", the "600s" chip): pi's text says only
    "Request timed out.", so the card shows that and the "timeout" chip.
- **Stopped:** a turn the user stopped is not an error. It ends in the note "Stopped", and the
  call Stop interrupted keeps its line's usual colors with "stopped" in its meta ("Ran a
  command · sleep 40 · stopped · 7.5s"), standing alone like a failure, so the word stays
  visible.
- **Live text** (LiveText; `NativeTurnPresentation.betweenTools`, `NativeThreadStore.showsThinking`):
  while pi works, one thing moves at a time, and it is text; nothing in the thread spins, and
  there is no "Working…" row anywhere.
  - A tool is running: its own activity line is the indicator (Activity lines › Live), with
    nothing under it but its output.
  - A call being written: the line is live from the moment the model names the call, while its
    arguments stream (a big write takes long), and goes on as the running call when pi starts it
    (docs/native-thread.md › Events). The words the reply wrote before it are finished, not
    "being written", so the turn never ends in a static paragraph with nothing moving.
  - Between tools (no call running or being written, no thinking or reply streaming; also before
    pi's reply has a row): the turn ends in live thinking, "Thinking…" shimmering. When pi's
    thinking streams it is the same line, and it settles into "Thought for Ns".
  - Replying: the text being written is the indicator; no line joins it.
  - Async children keep moving in the tray after their parent ends its turn. A running row's
    words shimmer beside its still dot (Subagents › A row); no standalone wait tool keeps the
    parent turn open. Legacy wait calls in saved sessions remain hidden.
  - A pending question replaces all of it with the composer's question panel. Waiting isn't
    working: a steering message in Up next waits still (Up next).
  - A counting timer is motion enough: the running call's clock ticks beside its shimmer in
    `textTertiary`. Under Reduce Motion the shimmer is plain `textSecondary` text.
- **Footer** (`NWTurnFooter`), after a finished turn that didn't end in an error: copy (the turn's prose; tooltip "Copy the
  reply", VoiceOver "Copy response", then a check for 1.5s) and retry (the turn again in its
  place, only on the latest turn and only while the agent is idle; tooltip "Retry this turn",
  VoiceOver "Retry turn"; Main's labels) as 24pt icon buttons 4pt apart, then, 4pt further, "2:44 PM · 3m 12s · 23 tool
  calls" in mono 10.5 tertiary (when the prompt was sent, how long the turn took when that was a
  second or more, and the tool calls a reader can count), and "· 3 subagents" as a `running` link to
  the first run. The whole row, link included, shows only while the turn is hovered.
- **Retry** (the footer's and the error card's) retries the turn in place
  (docs/native-thread.md › Retry): the prompt and the reply leave the thread, and the prompt goes
  again as it was, text and images, streaming in their place, so the thread and the model see it
  once. Only the latest turn offers it, since retrying an earlier one would drop every turn after
  it. A host from before in-place retry sends the prompt again as a new message instead.

**A turn while pi works** (Running): the turn builds in place as its parts arrive, in the order
above, each fading in (a failed request rising like a row): "Thought for 2s", prose saying what
it will do, the finished lines ("Committed · 3 files changed"), and the one live line with its
output ("Pushing · git push origin main · 3s") last, nothing under it. It has no changes
card and no footer until it finishes; then both rise into place under it (`list`). The finished
turn above it keeps its footer hidden at rest, like any other.

**Details on hover.** A message's time and a finished turn's footer are hidden at rest, so a
thread reads as the conversation alone; the pointer over the message (anywhere in the turn's
row) shows them.

- **Nothing moves.** Hidden, they keep their place and draw nothing; they only fade (`.hover`,
  unchanged under Reduce Motion). A turn measures the same hovered or not.
- **Also shown** while one of the footer's controls has keyboard focus, for the moment a copy
  confirms, and whenever VoiceOver runs, so Copy response, Retry turn, the subagents link, and
  the time are always reachable (`NWMessageDetails`).
  - **Not built yet.** A user bubble with keyboard focus shows its time too, as NWThread says
    ("hovered or focused"). Today a bubble takes no focus, so its time shows only on hover or
    with VoiceOver.
- **Per message.** Each turn owns its pointer state (`MessageHover` in `ThreadTurns.swift`), and
  its whole row counts, gaps and the hidden details' place included. Only what shows the
  details reads it (an agent turn's footer; a user turn, which is just its bubbles), so the
  pointer crossing a thread never re-renders an agent turn's parts, other turns, or the thread.
- The subagent inspector's transcript follows the same rule; there "from parent" always shows
  under a message from the parent (never under your own steers and answers), and its time fades
  in beside it.

**Activity lines** (`ActivityLinesView` and `ActivityLineView` in `Thread/ThreadTools.swift`, on
`NWActivityLine` and `NWActivityCalls`; NWThread, ToolRows). One quiet line per burst of work
instead of a card per call: consecutive calls of one kind merge into one line
(`nativeActivityBursts`), the lines sit inline with the prose in the order the work took, and
nothing folds them into a summary. A failed call and the running call each stand alone; other
tools merge only with the same tool. Consecutive lines form one part of the turn
(`NativeTurnPresentation.Item.activity`), split by prose, notes, errors, steers and cards.

- **The line:** 26pt, a 13pt glyph in `textTertiary`, the label in `ui` regular (12.5)
  `textSecondary`, the meta in mono 11 tertiary, and a 10pt tertiary chevron (pointing right,
  turning down) when it expands, 8pt apart, with 4pt leading and 8pt trailing padding. It hugs
  its content and sits 4pt left of the column, so its glyph lines up with the prose. The label
  takes the room it needs, and the meta takes what is left and truncates at its tail (it leaves
  when under four characters would show). A label wider than the line alone (the boards a design
  agent updated by name, a page the Browser opened) truncates at its tail, so a row never
  widens the thread: one that cannot shrink to its column widens the stack every row shares, and
  the whole thread runs off its pane (`ThreadFitTests`). It is a real button with a radius-6 `bgHover`
  fill on hover; a line with nothing behind it draws no chevron (its place stays) and is not a
  button: no hover, no press, no focus, and VoiceOver hears only its words.

  | Kind | Glyph | Done | Running |
  | --- | --- | --- | --- |
  | Explore (read, grep, find, glob, ls) | `magnifyingglass` | "Explored 7 files" · "read 5 · search 2 · 0.9s" | "Reading", "Searching", "Listing" |
  | Edit (edit, write) | `pencil` | "Edited 4 files" · "+149 −63" | "Editing", "Writing" |
  | Run (bash) | `terminal` | "Ran tests and a build" · "17 passed · build ok · 1m 02s"; "Committed" · "3 files changed" (Running); "Committed and pushed"; "Ran 2 commands" | "Running tests", "Building", "Committing", "Pushing", "Running" |
  | Subagents (spawns without a card) | `arrow.triangle.branch` | "Started 2 subagents" · "reviewer · tests" | "Starting a subagent" |
  | Other | `wrench.adjustable` | "Used <tool>" or "Used <tool> n times" | "Running <tool>" |
  | MCP (a server's tool, `mcp__<server>__<tool>`, `NativeMCPActivity`) | `wrench.adjustable` | "Called search_issues" · "github · label:bug"; "Called search_issues 3 times" · "github" | "Calling search_issues" · "github · label:bug" |
  | Tool search (`tool_search`, which loads deferred MCP tools) | `wrench.adjustable` | "Searched tools" · "“issues” · “pull requests”" | "Searching tools" |

  An MCP call names pi's own tool and server (characters outside letters, digits and `_` are already
  `_`); the meta adds what it was asked, the first of `query`, `q`, `url`, `path`, `pattern`, `name`,
  `title`, `text` or `command`, cut to its first line. Failed it reads "<tool> failed" (a tool pi
  never loaded: "Tool mcp__x__y not found"), "Tool search failed", and stopped "<tool> stopped",
  "Tool search stopped". Expanded, a search's rows say "search", its query and "8 loaded", and its output
  lists the tools it loaded. A call nested in another, such as a script's call to a tool,
  has its own ordinary activity row. Live `parentToolCallId` events show its output and state;
  saved `nestedCalls` metadata restores its arguments, status and invocation order. Shepherd's
  codemode retains text excerpts in the parent's display-only details, up to 8,192 characters per call and
  32,768 per script. An excerpt names its limit; older native sessions say when output was not
  saved. A failed call stays failed even if the script handles the error and succeeds.

  Shell commands are classified by what they run (`nativeCommandClasses`: tests, build, commit,
  push), with setup and pipes (`cd`, `| tail`) ignored and test counts parsed from the output
  (Swift Testing, XCTest, and "N passed" in general).
- **Failed and stopped words.** A failed call reads as what it was doing: "Read failed", "Search
  failed", "List failed", "Edit failed", "Write failed", "Ran tests", "Ran a build", "Commit
  failed", "Push failed", "Ran a command", "Subagent failed to start", "<tool> failed". A call
  Stop interrupted reads the same way with "stopped" ("Edit stopped", "Commit stopped",
  "Subagent stopped", "<tool> stopped"; runs keep "Ran tests", "Ran a build", "Ran a command").
  The meta is the command or the file's name, then the reason ("exit 1", "3 failed", the error,
  or "stopped"), then the time.
- **Failed:** the line turns `failed` (the `exclamationmark.triangle` glyph and the label; the
  meta stays tertiary) and stays visible, never merging with its neighbours: "Ran tests" ·
  "swift test · exit 1 · 8.4s" (ToolRows), or "swift test · 3 failed · 8.4s" when the test
  counts parse; "Edit failed" · the file · the error. A piped test run that exits 0 with
  failures still fails.
- **Live** (LiveText): only the current call is live, on a 26pt line with no hover fill and no
  chevron: the tool's own 13pt glyph, still, in `textSecondary` (nothing spins); the progressive
  verb (`ui`) and the command or path (mono 11) shimmering (`.nwShimmer(active:)`); and its
  elapsed time in mono 11 `textTertiary` ("3s", "1m 20s"), 8pt apart. Its last three output lines
  sit 4pt beneath, 21pt in (under the label), in mono 11 at 1.6: the older ones `textTertiary`,
  the newest `textSecondary`. When the call ends the live line cross-fades into its finished
  line in place, and the output lines go at once.
  - **While the model writes the call** the same line is live, unchanged: the verb ("Writing",
    "Running", "Reading") shimmers beside what the model has named so far, and the clock runs
    from the call's first word. It is the verb alone until the model has said which file or
    command, and no output lines sit under it yet. The path or command grows as it streams; the
    rest of the arguments (a write's whole body) is never drawn or held by the thread. The line
    goes on as the running call, one clock, in place; if the request is stopped or fails before
    the call runs, the line leaves and nothing stays behind.
- **Calls** (expanded, `NWActivityCalls`): an indented list on the rail, 24pt rows in mono 11
  with no gap between them and 10pt between a row's columns: the kind in `textTertiary` in a
  32pt column that widens for a longer name ("read", "edit", "bash", "spawn"; at most 22
  characters wide, a longer name truncates), the path
  (truncated at the head) or command (at the tail) in `textSecondary`, and a stat in
  `textTertiary` ("+58 −41", "160 lines", "3 matches", "17 passed", "exit 1"; in `failed` on
  a failed call). A row has a radius-4 hover fill and the full path or command as its tooltip.
  - Clicking an edit or write opens the review pane at its file. Clicking any other call with
    output expands its first 12 lines in mono 11 `textSecondary` on `bgSunken` (radius 6, 8×10
    padding, aligned under the path); then "… n more lines" (or "Output truncated · open" for
    output the host clipped), a link, opens the whole output in a sheet.
  - The output sheet (`ToolOutputSheet`): the call's name and command in mono medium with Copy
    (secondary) and Done (primary) in its header, the output in mono 12 scrolling both ways, and
    "The host clipped this output; the full text is in the agent's session file." beneath it when the
    host clipped it.
  - Expanded lines include an input row before each call with saved arguments. For codemode,
    the row reads "script" · "JavaScript" and immediately shows the first 12 lines of the saved
    `code` argument as source text. Other tools read "input" · the tool name and open their saved
    JSON arguments when clicked. Input rows toggle independently of output; "… n more lines"
    opens the full saved input in the existing Copy/Done sheet. Missing arguments or empty source
    add no input row. Live lines keep their existing
    non-expanding presentation. User requirement: [Tool call details](boards/ToolCallDetails.md).
  - ⌥-click or the context menu's Show Call still opens the raw arguments; the menu also has
    Review <file>, Open Output, and Copy Output.

**Changes card** (`NWChangesCard`, ChangesCard(turn.changes); Main, NWThread): every finished turn
that edited files ends with one. It comes from the turn the host recorded (`ChangesTurn`, carried
by the thread's rows as `recordedTurn`): the files as the repository saw them, however they were
written. A host without Changes (or a directory that is no repository) gets the card from the
turn's edit and write calls, without Undo.

- A card on `bgWindow`, radius 10, 1px `lineSubtle`. Its head (10pt padding, 12pt leading, 10pt
  gaps): a 30pt tile (`bgSunken`, radius 8, a `lineSubtle` line) with `plus.forwardslash.minus`,
  "Edited 5 files" (Geist 13 semibold) over the turn's diff stat in mono 11 (`NWDiffStat`, a true
  minus), then **Undo** (ghost `s`, the undo glyph after it) and **Review** (secondary `s`).
- The first three files as 30pt rows between hairlines, 12pt sides: the folder in `textTertiary`
  and the file name in `textPrimary` (`ui`, truncated at the head), "new" (or "deleted") in 11
  `textTertiary`, the file's stat in mono 11. Then "2 more" (12 `textSecondary`) when there are
  more. Review, a row and "N more" open the Changes pane on this turn (at that file).
- **Undo** puts back the turn's edits in the worktree and nothing else (docs/changes.md): no
  dialog, since Redo reverses it, and the agent isn't told (both the user's call, 2026-09-25). It is offered on the last turn only, once it ended having changed
  something. While it runs its buttons hold; a refusal says why under the card in `caption`
  `failed` ("Didn’t undo: outbox.go changed after the turn. Nothing was touched.").
  A filesystem failure after some writes explicitly reports a partially applied operation, not
  “nothing was touched.” The same Undo (or Redo) retries the remaining work, including after a
  relaunch; changes made since the partial operation cause a refusal instead of being overwritten.
  Undo must finish before Redo is offered. Recovery is journaled per file, not an atomic rollback.
- **After Undo** (ChangesCard · after Undo) the card is one line on a dashed `lineStrong` border,
  radius 10, padding 10×12: the undo glyph, "Undid the agent’s edits to 5 files" in `ui`
  `textSecondary`, and **Redo** (ghost `s`) until the next turn starts.

**Compactions** (ContextIdeas › In the thread, ContextCompacted; `CompactionItem` in
`Thread/ContextMeter.swift`, on ShepherdUI's `NWCompactionDivider` and `NWCompactionSummary`;
`NativeCompactionRow` in ShepherdRemote). A compaction leaves one line where it happened, like
other thread events, inside the reply it happened in: a `lineSubtle` rule on each side, 12pt
from the words, which are 7pt apart — an arrows-in glyph in `textTertiary`, what happened in 12
`textSecondary`, the context before and after in mono 11 `textTertiary` ("184k → 23k"), a
`lineStrong` "·", and **Show summary** (12 `textPrimary`, a 9pt chevron). The words follow pi's
reason: "Compacted automatically" (threshold), "You compacted" (manual), "Context overflowed ·
compacted and retried" (overflow, in `lanternText` with a warning glyph), "Compacting context…"
with the size while it runs (shimmering, no glyph), "Compaction stopped · nothing changed" when it
was stopped, and "Compaction failed · nothing changed" (the reason in its tooltip). A compaction
from before this host saw it (another run, or a relaunch) reads "Compacted" with its size before.
Everything above it stays readable for as long as the agent's pi runs, though pi now sees only
the summary; after a relaunch the thread starts at the latest compaction, as pi keeps it.

Show summary opens **What the agent kept** in place (Hide summary closes it): a `bgSunken` card
with a `lineSubtle` line, radius 8, 14pt above and below and 16pt at the sides; a text glyph,
"What the agent kept" (12 semibold), its size and "written by the agent" in mono 10.5
`textTertiary`, and Copy trailing; then the agent's own sections, 12pt apart, each its heading
(12 semibold `textPrimary`) over its text (12.5 `textSecondary`, 1.5 line height), and the files it
changed as "Files changed" with their names in mono 11, 12pt apart. The files pi read are left out.
The ring's Show summary opens the same card.

## Goal card

The supplied **Goal card** board, with **MobileGoal** and **iPadGoal**, is the authority for this card.
The [second safety review](goal-safety-review.md) amends its controls and model disclosure; its
[revision-301 image](boards/GoalStates.png) is saved here. `NWGoalCard` has five states:
Working, Checking, Met, Paused, and Needs you. All headers use the reference's two-ring goal
glyph. Working has a pulsing blue dot, Checking a blue spinner, Met a green checkmark,
Paused a gray pause mark, and Needs you an amber dot. Reduced motion disables animation.
Text, glyphs and fills use AgentState's matching roles. Paused uses idle text and the neutral
`bgSelected` fill because idle has no tint.

The card stays above the composer, including when a question replaces the field. Goal,
Subagents, and Up next share one frame and hairline separators in that order. A single card
still has its own frame. Desktop height is 70pt, header 32pt, radius 10pt. Touch height is 92pt,
header 40pt, radius 12pt, with 44pt action hit targets. The condition stays visible and can be
edited without changing its goal state or reason. The thread-header goal pill appears only in
Working and Checking. On iPhone it sits beside the ordinary status dot and word, never replacing
them. Sidebar rows keep their question/reason chip or elapsed time and add the card's two-ring
glyph. Queue copy says "after the goal check" while a goal is active.

The per-state meta is one line of mono text from the runtime, not preview-only copy:

- Working shows the token count, such as "71k tokens".
- Checking names the commands of the tool results being read, such as "checking go test, go vet".
- Met shows tokens and the evaluator's short human summary, such as "104k tokens · 41 tests passed".
- Paused always says "paused by you · the clock stops", including after an edit.
- Needs you gives a short lowercase reason, such as "the same test failed 3 times in a row", "waiting
  for your answer", or "hit the 25-check limit". It never cuts a word in half.

Phone cards omit header meta and put it in the long-press menu. The header shows Pause or Resume
and Clear; Edit stays in that menu. iPad's wide layout draws the full desktop card. All iOS targets
are 44pt, including the wide iPad's desktop-style controls. Phone chrome is 34pt; wide iPad chrome
keeps desktop sizing and leaves body clearance for its larger targets. A target stays inside the shared dock, using body padding below
the 40pt header when needed. Text scale grows vertical space along with the text; the default
70/92pt anatomy stays unchanged when no attribution is present. `Checked by <model>` appears
below the condition after an actual check, with `Confirmed by you` after explicit attestation;
these lines grow the card. Touch confirmation candidates also show the incomplete-evidence
reason before the action is used. Working and Checking reserve the same pill width. When larger
text and actions cannot fit side by side, the header grows a second row instead of clipping targets.

Pause stops automatic continuation without killing the current tool. Resume is disabled while
the question that stopped the goal remains open. Edit preserves the current state and reason;
Save is disabled for unchanged text or a stale displayed revision/state. The existing
inline/sheet editor changes the condition only. Goals have no time/token budgets or limit
fields. Incomplete-evidence Met candidates offer Confirm instead of Resume, with an explicit
attestation explanation; no open question permits either action. Clear removes the goal, not its recorded checks. Met stays
visible until cleared. Checking reflects a real separate model call, never a decorative delay.

Settings > Experiments > Goals is off by default. While on, the slash menu has a
`/goal <condition>` row. Off pauses active goals, hides their chrome and rejects their controls;
on shows preserved Paused goals and never resumes automatically. A recorded "Goal set" line names the condition,
a centered not-yet divider separates checks from the next stretch of work, and a one- or two-line
"Goal met" closing line gives the short summary. Raw entry IDs, quotes and tabs appear only inside
a transcript disclosure, never in the card's meta or closing line. Current checks use Details,
with full redacted evaluator feedback and tool evidence projected from display-only message
details; failed checks retain their diagnostic there even without tool evidence. `Checked by
<model>` stays visible before the disclosure. Raw feedback never becomes another worker prompt. Older Evidence disclosures remain readable.

Long conditions still truncate to one desktop line or two touch lines. The desktop inline editor
and the iOS edit sheet are additional surfaces absent from the board. These remain pending user
decisions under **Departures** in PR #189, not approved design changes.
See [goals](../goals.md) for runtime semantics and the limits of transcript-based evaluation.

## Rich content in prose

Agents write more than paragraphs and lists; everything they commonly write draws as a native part,
the same on the Mac, iPhone and iPad. One parser in ShepherdRemote (`nativeMarkdownParse` in
`NativeMarkdown.swift`) splits a reply into blocks once per change, in the store
(`NativeTurnPresentation`), never in a view's `body`. The app maps them onto ShepherdUI's
`NWProseBlock` (`Prose` on the Mac, `ProseView` on iOS), and ShepherdUI draws them (`Prose.swift`,
`ProseTable.swift`, `ProseParts.swift`). Inline runs are styled once per text and text scale by
`NWProseInline`. Nothing the parser does not understand is dropped or shown as markup: it reads as
text.

- **Tables** (`NWProseTableView`): GitHub pipe tables with their delimiter row. A card with
  radius 8 (`NW.Radius.m`) and a 1px `lineSubtle` border, no fill of its own. The header row
  sits on `bgSunken` in `ui` semibold `textSecondary`. Cells are in the prose size (`body`, at
  `headline`'s 1.35 line height) in `textPrimary`, with 8×12 padding (`NW.Space.m` ×
  `NW.Space.l`). Rows are split by 1px `lineSubtle` hairlines; there are no column lines.
  - Columns follow the delimiter row's alignment (`:--`, `:-:`, `--:`).
  - Cells keep their inline Markdown: code spans as the thread styles them, bold, italic,
    links, strikethrough. An escaped pipe (`\|`) stays in its cell, and a pipe inside a code
    span never splits one. Rows of uneven length are padded, and no cell is ever dropped.
  - **Sizing** (`NWTableLayout`): a column takes its widest cell's width up to
    `NWThreadMetrics.tableColumnMax` (360pt, 260pt on iOS), then wraps. A table narrower than
    the prose measure hugs its content; given room, wrapped columns grow toward their content.
    When the columns do not fit, each gives up its share down to its floor: the larger of
    `tableColumnMin` (88pt) and its widest word, so a wrapped cell breaks between words and
    never inside an identifier. A table whose floors do not fit scrolls sideways inside its
    card (it never widens the thread and never squeezes a column into an unreadable one), so on
    iPhone the first column stays legible.
  - Text is selectable. **Copy** (the code block's 22pt icon button on a `bgSunken` backing,
    at the header's trailing end) copies the table as Markdown. On the Mac it shows while the
    table is hovered or the button has focus; on iOS it always shows, and the last column
    leaves room for it.
- **Task lists:** `- [ ]` and `- [x]` draw a read-only box in the marker's place:
  `checkmark.square.fill` in `textSecondary` when done, `square` in `textTertiary` when not.
- **Nesting:** lists nest to any depth, ordered and unordered mixed, with paragraphs, code
  blocks, tables and quotes inside items; two spaces of indent nest, as agents write them.
  Bullets change by depth (•, ◦, ▪). Quotes hold blocks too, in italic `textSecondary`.
- **Images:** an image on its own line (`![alt](src)` or `<img>`). A local file that this
  device can read (the agent's working directory, `nwProseFileRoot`, is here) draws as a
  thumbnail within 360×240 (`proseImageMaxWidth`, `proseImageMaxHeight`), radius 8 with a 1px
  `lineSubtle` border, decoded off the main actor at the size drawn. Clicking it opens the file.
  Absolute paths and paths relative to the agent's folder both work. A web image is **never
  fetched** (privacy): it is a chip with the attachment chip's anatomy (26pt, 1px
  `lineStrong`, radius 6), the `photo` glyph in `textSecondary`, its alt text in 12pt
  `textPrimary` and its host in mono 10.5 tertiary. The chip opens the image in the browser.
  A remote host's agent (and every agent on iOS) shows local images as chips too, because
  its files are not on this device. An image inside a sentence reads as its alt text.
- **Footnotes:** `[^label]` references become superscript numbers in `running` (mono 10.5),
  numbered in the order they are first cited. The notes gather after the message's last block,
  below a hairline: each number in caption tertiary where a list marker sits, its text in
  caption `textSecondary`. A reference with no note reads as written.
- **HTML is never rendered raw.** `<details><summary>` becomes a disclosure
  (`NWProseDetails`), collapsed: a 10pt chevron and the summary in body medium, the whole line
  a button. Open, its blocks sit 12pt past a 2pt `lineStrong` rule, as expanded thinking does.
  One with nothing inside is its summary alone, where the chevron's row puts it: no chevron,
  not a button.
  `<br>` breaks the line, `<kbd>` is a keycap (`ui` on `bgSelected`), and `<b>`, `<i>`, `<s>`,
  `<code>`, `<sup>`, `<sub>` and `<a href>` style their text. `<img>`, `<hr>` and `<h1>`–`<h6>`
  become their blocks, other known tags are stripped to their text, and comments are dropped.
  Anything that only looks like a tag (`Array<Int>`) stays text.
- **Strikethrough and links:** `~~text~~` is struck through; links, `<autolinks>` and bare
  URLs are `running` and open in the browser.
- **Diagrams and math** stay code: Shepherd renders neither. A fence labelled `mermaid` (or
  `plantuml`, `dot`, `graphviz`, `d2`) says "mermaid · diagram source" after a
  `point.3.connected.trianglepath.dotted` glyph, and a `math`, `latex`, `tex` or `katex` fence
  (and a `$$` block) says "math · math source" after `function`, both 10pt tertiary in the header.
- **Streaming** (`nativeMarkdownParse(_:streaming:)`): only the text a reply is still writing
  holds anything back. Its unterminated last line waits while it is only the start of a block
  (a `|` row, a delimiter row, a bare `-`, `1.` or `#`, a fence's first line, a tag still
  open, a task box still arriving such as `- [x`, a note's `[^label]` before its colon), so it
  never draws as something else for a moment. Footnote references are numbered while the reply
  streams, before their notes (which come last) arrive, so none shows its raw label. A table header waits for its
  delimiter row instead of drawing as a paragraph. The table appears as a table as soon as
  that row lands, and grows a whole row at a time. A finished reply draws every line.
- **Performance:** the table and its cells compare equal between chunks, so a reply streaming
  under a table redraws none of it (`ListPerformanceTests`: a 200-row table).

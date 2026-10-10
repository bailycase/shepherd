# Composer, questions, and menus

> Read when you change the composer, its model-settings popover, slash menu, context meter, a question, or the send path.

`Composer` (`Thread/Composer.swift`) on `NWComposer`, `NWSlashMenu`, `NWModelPicker`,
`NWModelSettings`, and `NWSendMenu`, with Up next above the card (below). Sizes are
`NWComposerMetrics`; the app's own are in `AppLayout+Thread.swift`. The boards: Composer & menus
(NWComposer, NWComposerLight: one anatomy in both appearances, every color a role), SlashMenu,
ModelPicker, and the Question boards (QuestionAsk, QuestionPick, QuestionAnswered,
QuestionStates).

The full-window boards (Main, Running, SlashMenu, ModelPicker, CommandPalette, SettingsKeyboard)
were drawn before Night Watch's component boards and draw the same parts larger: a radius-12
composer with 32pt controls and a 14pt field, a 640pt palette with a 56pt search row, 38pt rows,
and a lantern scope pill over a 54% scrim, and 22pt keycaps, under a 52pt breadcrumb toolbar
(Toolbar). Where they disagree, the component boards (Composer & menus, Controls, Navigation) win,
with two exceptions: **the slash menu is SlashMenu's and the model picker is ModelPicker's**
(below), since a menu too narrow for pi's command and model names hid what they were. A row or
string that only a full-window board shows still holds where the component anatomy has room for
it (the palette's New agent with options…, New space on <host>…, and "PR #24").

**The card:**

- It is pinned under the thread in the same column, 16pt above the bottom
  (`AppLayout.composerBottom`), with a 48pt fade from transparent to `bgWindow` above it
  (`AppLayout.composerFade`).
- It is `bgRaised`, with a 1px `lineStrong` line and radius 8 (`NW.Radius.m`). While the field
  has focus, a menu is open, or a drop hovers, the line turns `textTertiary` inside a 3pt
  `bgSelected` ring (`NWComposerMetrics.focusRing`); both fade (`hover`). (NWComposer: "focused,
  with text".)
- Top to bottom: attachments (a row 10pt from the top and 12pt from the sides, chips 6pt apart),
  the field, and one row of controls. The field is `body` text in `textPrimary` with a `lantern`
  caret, its placeholder `textTertiary`, padded 12pt above, 14pt at the sides and 4pt below. Its
  content is at least 40pt tall, or 56pt including padding (`fieldMinHeight`); it grows to 8 lines (`fieldMaxLines`), then scrolls.
  VoiceOver names it "Message the agent". The controls sit under it with 4pt above, 6pt at the
  sides and below, 2pt apart. Nothing else lives under the field: no hints, no status text.

**The control row:**

- attach: a 14pt `paperclip` in `textSecondary`, in a 26pt circular icon button (`.nwIcon`),
  only when the agent accepts images, and disabled at four attachments. Tooltip "Attach images
  (drop or paste also works), up to 4"; VoiceOver "Attach file".
- One model-settings button (`NWModelSettingsLabel`; "claude-opus · Medium ⌄"): the model's
  short name in mono 12, a tertiary dot separator, the thinking level in sans 12, then the
  chevron, all in `textSecondary`. While speed is Fast the button adds a **filled** bolt in
  `lantern` after the level (`NWFastBolt`, `bolt.fill` at 11pt medium, the one definition every
  place that shows Fast draws through); Standard draws nothing, and a model with no Fast tier
  never shows the bolt, even while the agent's own tier is still Fast. Unsupported thinking and
  speed are absent. The full model id remains in the tooltip and VoiceOver label ("Model
  settings: <id>", with the level and Fast as its value). ModelSettingsSummary decides what the
  button says, for the thread's composer and the New thread page's alike.
- Typing `/` opens commands. There is no commands button. Typing `@` (at the start or after a
  space, in a thread that takes design references) opens the design picker at once: "Loading
  designs…" until this Mac's designs are read, then their rows, "No designs yet" or "Nothing
  matches", and "Couldn't load designs." with Retry when the read takes too long. ↩ over it
  chooses its highlighted row and never sends the message. Design tool › Design references ›
  The @ picker has the rest.
- After the spacer, the checkout menu sits in the composer instead of the Mac thread header.
  `NWComposerBranchLabel` is a 26pt ghost chip with a 13pt worktree or house glyph, the branch
  in mono 11.5 (`textSecondary`, as the model's name), and a nonzero changed-file count in mono
  10.5 `lanternText` ("●3"), then the chevron.
  Its existing Show Changes, Copy Branch Name, Copy Path and Show in Finder actions remain.
  While the agent's question replaces the card, the checkout menu remains accessible in the header.
- `NWModelSettings` (the board's "One button opens one popover") floats above the card,
  leading-aligned, 328pt wide, radius 12, with 6pt padding. Its sections have mono caps
  headers (`NWMenuHeader`: MODEL, THINKING, SPEED) over hairline separators.
  - **MODEL:** 28pt rows in mono 12: the current model (a check in `running` on its trailing
    side), one available recent model, and All models… (Geist `ui`, `textSecondary`, a trailing
    chevron) opening the full picker. A model with a Fast tier wears a filled `NWFastBolt`
    before its check (the picker's "fast" tag, as a glyph); a model without one wears none.
  - **THINKING:** a segmented control of the levels the model takes (Low · Medium · High ·
    Extra high; Off to Max where it has them), in equal 24pt segments on a `bgSunken` track
    (a `lineSubtle` line, radius 6); the chosen segment is lifted on `bgSelected` with a
    `lineStrong` line (radius 4), semibold in `textPrimary`, the others medium in
    `textSecondary`. Up to four levels share one row; more wrap onto balanced rows of the same
    track (5 levels 3 + 2, 7 levels 4 + 3), so no title is cut. A level's note ("quick",
    "default") is its tooltip.
  - **SPEED:** the same control, Standard | Fast, the Fast segment wearing the bolt before its
    word. It exists only for a model that offers a raised tier, so a model without one has no
    Speed row.
  - Model selection closes the popover; a level or a speed can change while it stays open. The
    whole of a segment answers a click (not just its word: its content shape is the
    segment), and a segment is no `Button`, as no row is. ↑↓ walk every choice top to bottom (the
    models, All models…, each level, each speed) and the highlight (`runningTint`) follows the
    pointer too, ↩ chooses, Esc closes. Tall content scrolls inside the room above the composer.
- a spacer, then "Starting…" only while a slow pi keeps the thread waiting (see States),
  then the context ring (Context meter, below) 6pt before the action, a 28pt circle: **Send** (a
  14pt `arrow.up` in `textOnLantern` on `lantern`, at 35% until there is something to send) or
  **Stop** (a small rounded `stop.fill` square in
  `textOnFailed` on `failed`). While pi works with a draft, Stop steps aside **outlined** (a
  `lineStrong` hairline, no fill, `bgHover` under the pointer, the square in `failed`) and Send
  takes the corner, 6pt apart; filled Stop ⇄ outlined Stop + Send cross-fades (`content`).
  Tooltips: "Send (↩)", or while pi works "Queue (↩) · Steer now (⌘↩)"; "Stop the agent's turn"
  ("Stop the agent and its subagents" while subagents are live). While a question waits, the
  question dock takes the whole card's place (below).

Chips (`.nwComposerChip(active:)`) are 26pt ghost buttons with 8pt side padding and radius 6, in
Geist 12 `textSecondary`, their parts 6pt apart, filled with `bgHover` on hover, on press, or
while their menu is open. A new model or level cross-fades in its chip (`content`); typing and
width changes stay instant. In a narrow thread, Starting… drops its words first, then the
model-settings button drops the thinking level and shortens dated model ids. The branch name
truncates in the middle. There is never a second row of controls.

**Sizes** (NWDesignTool › Chat composer): the composer is the same component everywhere, at one
of two sizes, `.nwComposerSize(_:)` (`NWComposerSize`). `.regular` is the thread's and New
design's. `.compact` is for a pane under 520pt, a design's 420pt chat (the canvas's, a system
build's, a remote design's): the model-settings button drops the thinking level but keeps the Fast bolt. Attach,
the model, the context ring and Send are the same at both sizes, and so are the chips' 26pt
metrics (the boards draw the Design tool's composers at their own scale).

**States:**

- **Idle:** Send. The placeholder is "Follow up, or / for commands…" ("Follow up…" when pi
  reports no commands), or "Describe the task, or / for commands…" on a fresh agent.
- **Running:** Stop (⌘.) while the composer has no input at all (no words, and no attached image,
  file, design reference or page element); with any of them, Stop outlined and Send. The
  field keeps the idle placeholder (the Running board's "Queue a follow-up — sent when the turn ends"
  is a departure; see the table). Send's tooltip names both ways, queueing first:
  "Queue (↩) · Steer now (⌘↩)".
- **Accepting:** a spinner ("Waiting for the agent") takes the button's place.
- **Starting:** Send is offered from the first frame, before pi has answered anything. A
  message sent while pi boots waits behind the spinner, still in the field, and goes once pi
  answers, as the field has it then (edited, or not at all once cleared). Once pi has kept the
  thread waiting for two seconds (`AppLayout.startingIndicatorDelay`; half a second over a thread
  with nothing to show, `AppLayout.blankStartingIndicatorDelay`), "Starting…" in
  caption `textTertiary` with a 10pt `textTertiary` spinner sits in the control row just before
  the action (its spinner gives way to the action's own while a message waits). It lives in a
  row that is always there, so it never changes the composer's height or moves the thread; it
  drops its words before the chips drop theirs, and fades out the moment pi answers. A normal
  start is over before it would show.
- **Error:** Send, plus a `failed` banner above the card, "Lost connection to the agent
  process.", with the error and Reconnect: only for a pi that was serving and went away, one
  that failed, or one that never started.
- **Model blocked:** a `failed` `NWBanner` above the card, "Message wasn't sent.", names the
  saved CLIProxyAPI model and says the message was not sent. "Choose model" opens the existing
  picker. The draft and attachments stay; Send retries only on the user's press. The host tries
  the exact saved provider/model once before rejecting it, never a similarly named model or a
  different provider. See [RestoredModelSend](boards/RestoredModelSend.md).
- **Can't start:** a `failed` `NWBanner` in the Error banner's place above the card, for a pi
  that stopped before it served (Thread › Can't start), except one not signed in on this Mac,
  whose card in the thread says so instead (Thread › Not signed in; the composer stays as it is). Its title names the cause and its message
  says what to do, then pi's own last lines (at most six, colour codes removed), all selectable:
  - not signed in: "pi can't reach a model." / "Sign in to a provider for Shepherd's pi (Settings
    ▸ Pi), then Retry."
  - an extension failed: "An extension stopped pi from starting." / "Fix or remove it, then
    Retry." (pi's line names the file)
  - pi missing: "Shepherd can't find its pi." / "Its copy of pi is missing from the app.
    Reinstall Shepherd, then Retry."
  - home unsafe: "Shepherd won't start pi here." / "Its pi home and your own pi overlap. Move one
    of them, then Retry." (Shepherd's line names both folders)
  - resumed as new: "pi couldn't find this conversation." / "It would have started a new, empty
    one, so Shepherd stopped it. The conversation's file is untouched."
  - exited: "pi exited while starting (code 1)." ("(signal)" for a signal) / "Retry to start it
    again."

  Retry trails the text (secondary, small). A resumed-as-new banner adds **Start new
  conversation** (ghost, before Retry), which starts pi without the check, as today. A
  not-signed-in agent on this Mac shows no banner: its thread ends in the Not signed in card
  (Thread › Not signed in); a design's banner keeps Retry alone, and a remote viewer's has no
  actions. Send is
  disabled and the draft stays in the field; "Starting…" never shows beside it. A remote viewer's
  banner has no actions and ends "Retry on <host>." Retry takes the banner away at once (`list`
  transition) and the composer is Starting again.

With more than one live subagent, Stop asks first (`StopAllDialog`): Stop only the agent, or
Stop all. Stop (the button, ⌘., or Esc in the composer) takes back what pi was about to read
before it aborts, so a steering message returns to the queue. The host pauses the queue as
soon as Stop arrives, so a turn finishing during the stop cannot start the next message.
It waits until a new message, Send now, or a steer. Stop during a Steer now under way wins: the
message stays queued and the queue waits. Steer now stops the parent the same way Stop does but
never pauses the queue. Stop all stops the parent first, then
cancels its live subagents in the same session, without depending on a refresh between actions.
A failure stays visible even if a later cancellation succeeds. There is no status text, key
hint, or working directory in or under the composer.

**Sending while pi works.** There are two ways (`NativeSendChoice`, for every platform), and no
setting chooses between them:

- **Queue (↩), "Wait for the turn to end":** the message waits in Up next and goes when pi
  settles. Nothing in Up next has reached pi.
- **Steer now (⌘↩):** pi stops what it is doing, as Stop does (a half-written tool call is dropped, a
  running command is killed), and the message goes at once as the next turn in the same
  conversation. The stopped turn ends in its quiet "Stopped" note; the message is an ordinary
  user message that starts the next turn. The rest of the queue carries on after that turn, and
  the steers pi held come back to it behind the message. While pi is idle it is a plain send.

↩ always queues. ⌘↩ (`alternateSend`, rebindable) is Steer now, ahead of any key equivalent in the
window (the review pane's ⌘⏎), and only while the composer or one of its queued messages has
focus; so are the Send menu's second row, a queued row's Steer now and the ••• menu's Steer all
now. There is no way to steer at pi's next step: the choice was removed (the user's call,
2026-09-30), and a value an earlier version stored for it is ignored. Where the host cannot stop
pi (an older Shepherd without `native.interrupt.v1`, a compaction in progress, a prompt of its own
still on its way, or pi refusing the abort) Steer now is a plain steer, which is the only place a
Steering row appears (Up next), and a steer pi would refuse (during a compaction) waits first in
Up next instead; a message that begins with "/" never steers that way (pi runs a command only at
the start of a message it starts), so it waits for the turn to end. ⇧↩ and ⌥↩ insert a newline at
the caret, replacing selected text and leaving the caret after it, and never send or save; the
same holds in New thread, New design, subagent replies, queued-message editing, inline review
comments and a design comment's reply. The key handler inserts the line itself
(`NWReturnKey`, through the field editor's own `insertNewlineIgnoringFieldEditor:`, so the draft,
the caret and undo follow): on macOS 27 a SwiftUI multi-line field's editor answers `insertNewline:`,
the command ↩ and ⇧↩ both resolve to, by ending the edit with no line added, and only ⌥↩'s command
adds one, so returning `.ignored` for ⇧↩ left the system nothing to insert. An input
method that is composing (marked text) keeps ↩, and a ⇧ or ⌥ chord that also holds ⌘ or ⌃ is the
system's. With a menu open ⇧↩ still adds the line, which closes the menu; ↩ chooses its row.
`ComposerReturnKey` decides it, apart from the field. While pi is idle ↩ and ⌘↩ both send.
Attachments ride along with a queued message.

**Send menu** (`NWSendMenu`): right-clicking Send, or holding it for
`AppLayout.sendHoldDelay` (500ms), while pi works with a draft, opens the choice at send time
(`.overlay`): beside the card, 8pt after its trailing edge and bottom-aligned with it, where
the thread has room for it and its margin (`Composer.sendMenuBeside`), so it covers none of Up
next; otherwise 8pt above the card with its trailing edge on the card's. It grows from the
corner nearest Send. Nothing about the choice is written under the composer.

- 268pt on the menus' popover, 6pt padding, rows 2pt apart; each row top-aligned with 8×10
  padding and the `runningTint` highlight: a 14pt glyph in `textSecondary`, the title in Geist
  13 medium with its description in caption tertiary beneath, and its keys as `NWKeycap`s.
- Two rows, the gentlest first. **Wait for the turn to end** (the queue glyph): "Goes when the agent
  finishes this turn." **Steer now** (`arrow.turn.down.right`): "Stops what the agent is doing and
  sends this at once."
- ↩'s cap sits on the first row, which is highlighted when the menu opens, and ⌘↩'s on Steer now.
  ↑↓ move, ↩ chooses, Esc closes, and a click outside closes it. While it is open Send wears a 3pt
  `lanternTint` ring (`hover`). The Send tooltip reads "Queue (↩) · Steer now (⌘↩)".

**Images and files.** Images attach by dropping anywhere in the thread (history, blank space,
or composer), pasting, or the paperclip (an image importer). Readable regular files dropped
on a local thread attach as removable chips and send their absolute paths under the message.
Remote threads accept image bytes, but reject ordinary files with an inline explanation:
client-local paths are never sent to the host. A question occupying the composer disables
thread drops until the normal composer returns. Existing attachments remain.

Clicking the thread's blank background focuses the composer, without taking clicks from
selectable transcript text, links, buttons, menus, queue editors, or questions. This adds no
window-wide Tab handler; terminal and editing focus keep their normal keyboard behavior.

Image drafts belong to the thread, so switching remote threads or parking a terminal-bearing
layout does not discard them. A successful send removes only its submitted image IDs; images
added while it waits remain for the next message. Images are resized on the
way in (longest edge 2000px), at most four per message and 2 MiB each, and shown as
`NWAttachmentChip`s in the row above the field (NWComposer, "with attachment"): 26pt, a
`lineStrong` line at radius 6, a 20pt thumbnail (radius 4) 3pt from the leading edge, 6pt, the
file name in Geist 12 `textPrimary` (truncating in the middle), and a small `textTertiary` ✕
that removes it ("Remove <name>" to VoiceOver). Problems show as a `failed` banner above the card:
"At most 4 images per message.", "<name> is not an image Shepherd can attach.", or "<name> is
over 2 MiB after resizing."

**The element chip** (`NWElementChip`; PaneBrowser's composer): an element picked in the Browser
(Side pane: Browser) waits in the same row, after any design references: 26pt, padding 0×8,
radius 6, a `lineStrong` line, a 12pt element glyph (a dashed square with a pointer) in
`textSecondary`, the label in Geist Mono 12 `textPrimary` ("button.pay"), the source's file and
line in Geist Mono 10.5 `textTertiary` ("Checkout.tsx:88", only when the page provided one), and a
9pt remove × in `textTertiary`; its tooltip is the full selector. At most five wait at once, and
they go with the next message, on a host that takes them (`browserElements`).

**Questions** from pi or an extension (select, confirm, input, editor) take the composer's place,
never a row in the scrolling thread, so a blocked agent is always answerable (QuestionAsk,
QuestionPick, QuestionAnswered, QuestionStates). A subagent's question never does: a subagent
asks its parent, which asks here, as pi's own question, only when it cannot answer it
(Subagents). pi stops and asks once; the thread above keeps what pi found, and the question holds only the question, its
answers, and yours.

**The question dock** (`Thread/QuestionDock.swift` on ShepherdUI's `NWQuestionDock`; the shared
presentation is `NativeQuestionPrompt` in ShepherdRemote, for the touch clients too). It replaces
the whole composer card, not just its field, for pi's own question. Its
rules (QuestionStates › Rules):

1. **It takes the composer's place.** While pi waits, the bottom of the thread is the question:
   no attach, model, or thinking controls, no Send or Stop, nothing to confuse with a normal
   message. Widgets, a banner, the subagents and Up next stay above it.
2. **Context stays in the thread.** What pi found is in its message just above; the dock holds
   the question, the options, and your answer, nothing else.
3. **Label:** a question mark in lantern and a lantern outline. The thread and the sidebar show
   Needs you (the sidebar's Needs you row, its glowing dot and the question as its reason).
4. **Options** are numbered, and the number is the key. Each says what happens and what it
   costs. The asker's recommendation is marked **Recommended**, never preselected.
5. **Answer** is the only button. It lights up once an option is picked or an open question has
   text. There is no Dismiss: pi is waiting on an answer. The dock has no note field and no
   Something else…: pi's dialogs take neither (What each asker takes), and the subagent variant
   that did is gone.
6. **After:** the composer comes back (the field takes the keyboard again), and the thread
   keeps the record where pi asked (below).

- **The dock** (`NWQuestionDock`, `NWQuestionDockMetrics`): `bgRaised`, radius 12, a 1px
  `lantern` line inside a 3pt `lanternTint` ring (`.nwQuestionCard()`), 12pt above and below
  and 14pt at the sides, 12pt between its parts, as wide as the composer card:
  - the 26pt head (`NWQuestionHead`): a 13pt `questionmark.circle` and "Agent is asking" in
    Geist 12 semibold (`.nwSans(12, .semibold)`), both `lanternText`, 7pt apart; "1 / N" in
    micro tertiary when several wait; trailing, Hide the question, a 26pt round `.nwIcon`
    (transparent, a 14pt `chevron.down` in `textSecondary`; tooltip "Hide the question (Esc)").
    VoiceOver reads the head as one header, "Agent is asking", and the button as "Hide the
    question"
  - the question in Geist 16 semibold at 1.35, tracked -0.5% (`Font.nwSans(16, .semibold)`;
    15 for a yes or a no and an open question, as the Kinds cards draw it), inline code and
    emphasis as in prose (`NWProseInline`)
  - the asker's longer message, when it has one (a confirm's), in mono on `bgSunken` (radius 8, a
    `lineSubtle` line, scrolling past 140pt): an app addition no board draws
  - the options, 6pt apart. An option is a card on `bgWindow` with a 1px `lineSubtle` line,
    radius 8, 10pt above and below and 12pt at the sides, its parts 11pt apart: its number in a
    20pt rounded square (a `lineStrong` line, mono 11 `textSecondary`; radius 4, `NW.Radius.xs`,
    for the board's 5); the title in `headline` (13.5 semibold) over its description in `ui`
    regular `textSecondary` at 1.45, 3pt apart; and, trailing at the top, a 20pt
    **Recommended** tag (`lanternTint` fill, `lanternText` 11 semibold, radius 4, 7pt side
    padding). `NativeQuestionOption` splits an option into number, title, description (the
    lines after the first), and a trailing "(Recommended)". A click picks it (tooltip: its title
    and number). More than six options scroll inside a 360pt lazy stack.
  - a footer over a `lineSubtle` hairline, 12pt below the options: trailing, **Answer**
    (`.nw(.primary, size: .m)`, 28pt; tooltip "Answer (↩)"), disabled (40%) until there is an
    answer. Leading, in micro tertiary, "The agent may stop waiting for this answer" when the
    question has a timeout, or why it cannot be answered here ("An external editor is open ·
    finish it before answering here", "This question is too large to show here"), which also
    disables its options.
- **Picked** (QuestionPick): the option takes a `lantern` line on `lanternTint` and its number
  fills (`lantern`, `textOnLantern` semibold). The Recommended tag stays where it was. Picking
  another option moves the pick; nothing is answered until Answer or ↩.
- **Kinds** (QuestionStates › Kinds of question), one dock shaped by the answer the asker needs
  (`NativeQuestionKind`):
  - **Yes or no:** a confirm, or two options of at most 24 characters with nothing under them:
    side by side, 6pt apart, each 44pt (its number, the title in semibold, Recommended; its parts
    10pt apart), answering on click. It has no Answer button, so the dock has no footer (a
    confirm's is only its timeout line).
  - **Open question:** no options (pi's input and editor): a field at least 64pt tall (`bgWindow`, radius 8, a `lineStrong` line, 10pt above
    and below and 12pt at the sides, 13.5 at 1.5; up to 6 lines, 12 for an editor, then it
    scrolls) holding the asker's prefill, and Answer. It takes the keyboard when it arrives in
    the focused thread.
  - **No subagent variant.** A subagent asks its parent, never the user (see Subagents), so the
    dock never draws "<name> is asking", the branch glyph, 14.5 question or a note and
    Something else… for one: that variant was pruned from the components, on the Mac and iOS.
- **Hidden** (QuestionStates): Esc or Hide the question shrinks the dock to one 46pt line
  (`NWQuestionDockHidden`), so you can read the thread; it still holds the composer's place,
  because pi is still waiting. The line is the same lantern card (radius 12, 14pt leading and 8pt
  trailing padding, 10pt between its parts): a 14pt glyph in `lanternText`, the question in 13.5
  semibold (truncating; inline code as in the dock), a small secondary **Answer** (24pt), and a 26pt Show the question
  (`chevron.up`; tooltip "Show the question (Esc)"). Esc, Answer or Show the question brings the
  dock back, with what was picked and typed. Only that question stays hidden: the next one pi
  asks arrives open (`NativeQuestionHiding`, the iPad's rule too).
- **Keys** (QuestionStates › Keyboard; shown in tooltips): 1–9 pick an option (a yes or a no
  answers at once), ↩ answers, Esc hides or shows the question. They are the dock's while its thread has the keyboard
  (`QuestionKeyMonitor`), from its own fields too (where numbers type and ⇧↩ breaks a line),
  never with ⌘, ⌃ or ⌥ held (⌘1–9 still select agents), and never from another text field (the
  palette's search, a terminal). Settings, the component gallery, and the command palette
  suspend workspace keyboard ownership, including hidden question shortcuts; closing them
  restores the previously focused thread or terminal.
- **Stopping** (⌘., Agent ▸ Stop) is how a question is refused: it cancels the questions pi is
  waiting on (their asker gets pi's cancelled answer), then stops the turn. The thread records
  each as not answered.
- **The record** (QuestionAnswered; `QuestionRecord` on the board; `NWQuestionRecord`, from
  `NativeQuestionRecordRow`): where pi asked, the thread keeps one line in Geist 12.5
  `textTertiary` (a 12pt `questionmark.circle`, "Agent asked:", and the question in
  `textSecondary` medium, 7pt apart; one line, truncating, the whole question in its tooltip; on
  iPhone and iPad the question wraps to three lines, "not answered" riding its last)
  and, 8pt below, your answer as a user bubble (`NWUserBubble` with a title): the option's
  title in semibold (its description and "(Recommended)" left out), or Yes or No for a confirm,
  or the text you typed for an input or editor in the bubble's regular weight; and "2:51 PM ·
  answered" in mono 10.5 tertiary beneath, on hover like every bubble's time. pi's turn carries
  on under it; the record is part of the agent's turn, but its time is the answer's, so it moves
  neither the turn's duration nor its Copy. A question nobody answered (refused by Stop,
  cancelled by an older touch client, or its timeout passed) keeps its line alone, ending "· not
  answered" in `textTertiary`, with no bubble. VoiceOver reads it as one element ("Agent asked: …, you answered: …"). The host keeps
  it (docs/native-thread.md › Questions): a thread row every client draws, remote and iOS
  included, placed after the call that asked and before pi's next reply, and kept per pi
  session beside the queue's origins, so it survives a relaunch. A question still open when pi
  moves to another session (`/new`, `/resume`) is not recorded. When a tool asked, its own
  activity line stays too. A subagent's question is not recorded here: it is not the user's, and
  a Steer the user sends the child joins its transcript as the user's message.
- **Not built with it:** your note under the option's title, 4pt apart (QuestionAnswered), since
  none of pi's dialogs takes a note (What each asker takes).

**What each asker takes** (Honest affordances: the dock offers only what the asker can take, so
it has no note and no Something else…):

| Asker | Kind | Takes back |
| --- | --- | --- |
| pi's select (`ctx.ui.select`) | choice, or yes or no | one of its options, exactly as offered |
| pi's confirm (`ctx.ui.confirm`) | yes or no | true or false |
| pi's input (`ctx.ui.input`) | open | a string |
| pi's editor (`ctx.ui.editor`) | open, 12 lines | a string, as typed |
| A subagent | none | it is no asker of the user: it asks its parent (`shepherd_parent_message`, `needsReply`), which asks here, as an ordinary question, when it must |

An asking tool (any tool named `ask` or `question`, such as `ask_user`) asks through the dialogs
above, so its question is the row of the dialog it opens. Its `short` reason is for the sidebar's
Needs you (Sidebar); the dock never shows it.

**Not built yet: Pick several** (QuestionStates › Kinds: rows at least 40pt with a 14pt
`.nwCheckbox`, the label in mono 13 semibold for a host or a path and a note in 12
`textTertiary`, a ticked row in the picked style, and "Answer with 2 hosts"). No asker takes
several answers: pi's select returns one option. It waits for an asker that says it takes several. Any of pi's dialogs can also be cancelled (pi returns undefined or
false to its asker), which only Stop does. pi's `custom` UI is not supported in RPC mode, so a
tool built on it never reaches Shepherd.

**Extension widgets** (an extension's `setWidget` text, ANSI stripped) appear above the card as a
micro caps title and its text. Machine payloads, `setStatus`, and `notify` are not shown.
Widgets are display-only, and the app chooses every font and color.

**Menus** float over the thread above the card, one at a time: left-aligned with it (the Send
menu beside the card, or at its trailing corner), 8pt above it (`AppLayout.menuGap`), and growing
from that corner (`.overlay`: from 96%, fading). They take no room in the composer, so opening one
never changes the composer's height, the thread's inset or scroll position, or any of the thread
outside the menu (`ComposerMenuTests`). A menu is never taller than the room above the card (it
keeps 8pt from the thread's top, `AppLayout.menuMargin`, and its list scrolls inside), and beside
a docked pane it narrows to the card. They share one anatomy (NWComposer › Menus):

- `.nwPopover()` at radius 12 (a 1px `lineStrong` line, `bgRaised`, the popover shadow), with 6pt
  padding (the model picker's parts carry their own)
- section headers (`NWMenuHeader`, 24pt; NWComposer › Menus: COMMANDS, RECENT, MODEL, THINKING,
  SPEED): mono 10 medium, uppercase, tracked 6%, `textTertiary`, with an optional trailing count
  in mono 11 `textTertiary` ("4 of 23"), 8pt from the sides (10pt in the model picker)
- rows (`NWMenuRow`, 28pt unless a menu says otherwise), radius 6 (the boards' 7 on the radius
  scale), 8pt side padding, their parts 10pt apart, with a `runningTint` highlight that the pointer
  moves too; the current choice wears a `running` check. Rows are not `Button`s (the field or the
  menu keeps keyboard focus), but they read as buttons to VoiceOver. A row never wraps: what does
  not fit truncates.
- ↑↓ move, ⏎ chooses, Esc closes and returns focus to the field, and a click anywhere outside
  the menu closes it (the click still lands where it was aimed). Only the control that opens a menu (the
  model chip, the context ring, Send) is inside it, and it toggles the menu itself. A click in the
  field, on Attach or on blank space in the control row closes it. The slash and @ menus are the
  field's own, so the field keeps them. No footers; the
  only key hints are the slash menu's ⏎ and the model picker's chord.

- **Slash menu** (`NWSlashMenu`; SlashMenu): opens when the draft is "/…" with no space yet (or
  from the chip). It spans the composer card, from its leading edge to its trailing one, 8pt above
  it. "Commands" with "n of m" (matches of all); then one-line 36pt rows
  (`NWComposerMetrics.slashRowHeight`) with 12pt sides, their parts 12pt apart: the command in
  mono 12.5 with the typed prefix in semibold `textPrimary`, the rest in `textSecondary` and its
  argument hint in `textTertiary`, in a column at least 150pt wide that grows to the whole name
  rather than wrap (`/shepherd-subagents-fleet` stays one line); the description in Geist 13
  `textSecondary`, truncating at its end; its source as an `NWTag` for prompt templates and skills
  ("prompt", "skill"; none for extension commands); and on the highlighted row a trailing ⏎ in
  mono 11 `running`. The whole command is its tooltip. Commands whose name starts with the query come first, then those whose
  name or description contains it. At most 8 rows show, fewer when the room above the card is
  shorter; with none, "No command matches “/re”" in caption tertiary. ⏎ or a click puts "/name" in
  the field and sends it when it can; ⇥ completes "/name " to keep typing. Esc closes it for the
  draft as typed; typing more reopens it. The list is pi's command registry, never hard-coded, so
  pi's interactive built-ins, which the boards draw (/resume, /reload), appear only if pi's
  `get_commands` starts returning them. A command no thread can run is not in it: the host leaves
  out Retry's own `/shepherd-retry` and pi's terminal-only `/llama`, and Shepherd's bundled
  extensions register nothing the thread cannot show (no `/subagents-fleet` overlay or
  `/subagents-stop`: the tray, the inspector and Stop do that). What a command the user ran says
  back is a note in the thread where they are looking, in the Thread's note style: a plain note,
  or "warning · …" and "error · …" when the command said so, never a toast; a toast nobody asked
  for is still not drawn. Settings ▸ Skills ▸ Skills in the / menu, off, leaves the
  skills out (on the Mac), and Settings ▸ Pi ▸ Slash commands leaves out any command the user
  switched off, in every client, since the host filters the list it serves. Its rows are lazy, a highlight moving redraws only the two
  rows it moves between, and only ↑↓ scroll the highlight into view (the pointer's is already under
  the pointer).
- **/login and /logout** (SlashLogin, SlashLoginArgs; this Mac's agents only): two commands of
  Shepherd's own, listed with pi's ("2 of 24"), that never run in the thread. Their hint is
  "[provider]", their description "Sign in to a model provider in Settings ▸ Pi ▸ Sign-in" and
  "Sign out of a provider in Settings ▸ Pi ▸ Sign-in", and their tag "opens Settings" in place of
  a source. With "/login " typed (a space), the menu turns to the providers, headed "Sign in to ·
  opens Settings" with "n of m": each row "/login" in `textSecondary` and the provider's id in
  mono 12.5 `textPrimary` (the typed part semibold), its plan in 13 `textSecondary`, and its
  state as a word in caption trailing ("Not signed in" `textTertiary`, "Expired" `lanternText`,
  "Signed in" `done`, "API key" `textSecondary`); providers not signed in first, then by name.
  ⏎ (or a click) on either, or sending "/login", "/login anthropic" or "/logout …" as typed,
  clears the composer and opens Settings ▸ Pi ▸ Sign-in (anything typed after the provider, on
  any line, is dropped: a key pasted after "/login deepseek" never reaches pi); with a provider
  it scrolls there and starts its sign-in (/logout only scrolls there: signing out stays a
  click). A name Shepherd
  doesn't know opens Sign-in with the list as it is. Nothing reaches pi. A remote agent's composer
  doesn't list them.
- **Argument hints** after the name in `textTertiary` ("/release-notes [tag]"; NWComposer,
  SlashMenu) come from a prompt template's `argument-hint` frontmatter, which the host reads from
  the file pi names (pi's `get_commands` sends no hints; `NativeCommand.arguments`). Extension
  commands and skills declare none, and pi's interactive built-ins (/resume, /reload) are not in
  its registry, so those rows have no hint.
- **Model picker** (`ModelPicker` on `NWModelPicker`, 380pt, its list at most 360pt tall;
  ModelPicker): from the model chip or ⇧⌘M, either of which also closes it (without `setModel` it
  beeps). A 30pt search row takes focus: a 12pt `magnifyingglass` in `textTertiary`, "Search
  models" in Geist 13, the picker's chord trailing in mono 11 `textTertiary` ("⇧⌘M", from
  `KeybindingsStore`), and a hairline under it. The list sits 4pt in from the top and bottom and 6pt
  from the sides: **Recent** (the last four models picked in any thread, newest first;
  `RecentModels`), then one section per provider in catalog order, headed with the provider's name
  4pt below what precedes it, leaving out what Recent shows. Rows are 40pt
  (`NWComposerMetrics.modelRowHeight`) with 10pt sides, their parts 10pt apart: a 12pt column
  holding a `running` check on the current model; the model's short name in mono 12.5
  `textPrimary`, truncating in the middle, so a long id keeps its provider prefix and its tail
  ("~anthropic/claude-o…pus-4-8"), over a second line in caption `textSecondary` listing the
  thinking levels the model takes and nothing else, in pi's order and the thinking menu's titles
  ("Off · Minimal · Low · Medium · High", with "Extra high" and "Max" where the model has them),
  truncating at its end, or "No thinking" for a model without reasoning (the check already marks
  the current model). The levels follow the New Agent sheet's rule: pi's composed capabilities,
  including built-in, configured and extension-supplied thinking maps. A configuration-only
  fallback keeps its declared maps, and a host without `thinking.levels.v1` takes Off to High.
  The thread's current model lists what pi reports for it, which
  is live (`NativeModelChoices.thinkingLines`). The iOS picker's rows carry the same line under the
  name. Trailing, a "fast" tag in mono 11 `textTertiary` on a model that offers a Fast tier (the
  host's service-tier table, `ModelListing.serviceTiers`), then the row's context size in mono 11
  `textTertiary` ("200K", "1M"). The whole id
  is the row's tooltip and what VoiceOver reads, with the levels. A query keeps the models whose
  id contains it and moves the highlight to the top. While the catalog loads, the list opens with a 12pt spinner and "Loading
  models…" in caption tertiary. Choosing sets the model, records it in Recent, and returns focus to
  the field; it picks the model only. A catalog runs to hundreds of models, so the list is lazy
  (only the rows on screen exist), derived once per catalog and query rather than while drawing
  (`ModelCatalog`, `ModelPickerState`; this Mac's catalog is asked once per process, off the main
  actor), and a hover moves the highlight without redrawing the list or scrolling it
  (`ComposerMenuPerformanceTests`).
- **Model settings** (`NWModelSettings`, 328pt; NWComposer › Menus; the control row above): from the
  model-settings button, which also closes it, over the card as the other composer menus are
  (left-aligned, 8pt above it, never moving the thread). It takes focus with the first row
  highlighted. The levels are the ones pi offers the thread's model
  (`get_available_thinking_levels`, carried as the snapshot's `thinkingLevels`), in pi's order:
  Off, Minimal ("fastest"), Low ("quick"), Medium ("default"), High ("slower, deeper"), Extra
  high ("deeper still"), Max ("slowest, deepest"). A reasoning model usually has Off to High with
  Minimal; Extra high and Max only where pi maps them; a host that does not say offers Off, Low,
  Medium and High; a model without reasoning has no Thinking row. The tiers are Standard
  ("Default speed and price") and Fast ("Faster responses, billed at a higher rate"), the
  tooltips of their segments. A change applies to the next model call of the running agent (the
  request already in flight is not changed) and persists with the thread. Fast asks the provider
  for priority processing, which is billed at a higher rate and which the provider may decline
  under load: the thread's cost figures follow the tier the provider reports.
  `ThreadCommandCenter.Command.thinkingMenu` and `.speedMenu` open this popover (no chord), and
  ⌘K's Toggle fast mode switches the tier without opening it.
- **Agent context menu** (NWComposer › Menus: "Native NSMenu in Swift; shown for spec"): a
  native menu (`.contextMenu`), never a custom popover: Rename… with its keys (⌘R), Fork from here
  and Copy transcript (each with its glyph), a separator, Open in Finder, a separator, and Delete
  agent… as the destructive item (`role: .destructive`). The sidebar's agent menu
  (Sidebar › Context menus) is this menu, with Review Changes, Finalize Worktree… and Delete
  Worktree Agent… where it has them, and menu-bar title case.

**Context meter** (ContextIdeas: placement A, "its own circle, beside Send"; ContextDetails,
ContextFull, ContextCompacted; `ContextMeterButton` and `ContextDetailsPopover` in
`Thread/ContextMeter.swift`, on ShepherdUI's `NWContextMeterButton`, `NWContextRing` and
`NWContextDetails`; sizes are `NWContextMetrics`). What fills the model's context window is a
small ring in the control row, just before Send (and before Stop while pi works); the composer
never shows text for it, and the header has no counters (Toolbar). The ring comes from
the host (`NativeThreadSnapshot.context`, docs/native-thread.md); a host from before it reports
none, and the row has no ring.

- **The ring:** an 18pt trimmed circle, 2.2pt stroke with round caps, starting at 12 o'clock,
  over a `lineStrong` track, in a 32pt circle button that fills `bgHover` under the pointer and
  `bgSelected` while its details are open. The button is the board's 32pt in the row of 28pt
  controls; it overhangs the row by 2pt above and below, so the composer keeps its height. States
  (`NativeContextMeter`, ShepherdRemote): **empty** (the track alone: the agent has not replied, so
  there is no number); **under 60%** `textSecondary`; **60–85%** `lantern`; **over 85%** `failed`;
  **compacting** a `running` arc of 28% that turns, from `compaction_start` to `compaction_end`;
  **after compaction** a dashed `textSecondary` circle at 80% (dashes 1.55pt), until the agent's
  next reply gives a real number. It redraws only when the usage changes, never with a streamed
  chunk or a keystroke (`ListPerformanceTests`).
- **Hover** (`.help`): "42k of 200k · 21%", or "about 23k of 200k · exact after the next reply"
  after a compaction ("exact after this reply" while the agent replies); "Compacting 184k…";
  before any reply, "Nothing yet of 200k · the agent hasn't replied". VoiceOver: "Context 21%
  full", "Context: compacting", "Context: updating after compaction", "Context: nothing yet".
  Sizes round to the nearest thousand ("184k" is a 200k window less pi's 16,384 reserve).
- **Click for details:** a popover above the ring, 8pt over the card with its trailing edge on the
  ring's (`.overlay`, like the composer's menus: it never moves the card or the thread); Esc or a
  click outside closes it, and so does a click on an item it finds. `bgRaised`, radius 12, the
  popover shadow and a `lineStrong` line; 340pt with the split, 300pt otherwise; 14pt sides.
  - A header: "Context" (12.5 semibold) and, trailing, the model and window in mono 10.5
    `textTertiary` ("claude-opus · 200k"). Then the total in Geist 22 semibold (−0.44 tracking)
    with "of 200k" (12.5 `textSecondary`) and the percentage trailing in mono 12.
  - An 8pt bar of the window on `lineSubtle`: each part's share, 1.5pt apart — the system prompt
    and tools in `textTertiary`, instructions in the syntax keyword color, messages in the
    function color, tool results in the type color, the agent's written files in the string
    color, reasoning in the terminal's cyan, images in the variable color, and Other in
    `lineStrong` (`contextSystem`, `contextInstructions`, `contextMessages`, `contextToolResults`,
    `contextToolCalls`, `contextReasoning`, `contextImages`, `contextOther`: swatches only, never
    text) — and the auto-compact mark, a 1.5×14pt `textSecondary` tick where pi compacts on its own,
    labeled under the bar in mono 10 `textTertiary` ("auto-compact · 184k ↑"; no mark while
    auto-compaction is off). The mark is where the thread compacts: pi's default, or the Compact at
    percentage the user chose in Settings ▸ Agents ▸ Context.
  - **The split** (`ContextDetails(.split)`; the user's call, 2026-10-01): 26pt rows of an 8pt
    swatch, the part and its size in mono 11.5 ("6.8k"), then "Free" in `textTertiary`. The first
    four rows are always there: "System prompt and tools", "Instructions", "Messages", "Tool
    results". Under the first two, quietly, what each is made of, largest first and four at most
    (18pt lines in mono 10.5 `textTertiary`, indented to the label): the system prompt's groups
    ("browser tools 3.4k", "skills 850", "pi · system prompt 1.4k"; the tools by the group the
    audit in docs/context-budget.md gives them) and the instruction files by where they are
    ("Shepherd/AGENTS.md 4.8k", "APPEND_SYSTEM.md 225"). Nothing in those lines is pressed. A
    host from before them names the first instruction file in the row's label ("Instructions ·
    AGENTS.md +1") and draws no lines. Then, only when each is at least 500 tokens, a row of its
    own: "Tool call contents" (the files the agent wrote or edited, carried in its calls),
    "Reasoning" (the provider re-sends it with every call), "Images", and "Other". **Other is what
    the provider's total holds that Shepherd cannot itemize** (the provider's own tokenization
    against Shepherd's four characters a token, cache bookkeeping): it is never added to another
    row, so nothing but the system prompt and the tools is ever called "System prompt and tools".
    The fixed part, the system prompt, the tools and the instruction files, is anchored to the
    provider's count of the thread's first call after it started or compacted. **Largest** (a mono
    10 uppercase label, "click to find in thread" trailing): the three largest tool results, each
    a file or terminal glyph, the file's name or the command's first line in mono 11.5
    `textSecondary`, and its size; `bgHover` under the pointer, and a click scrolls the thread to
    the turn holding it (loading older pages as needed). The footnote in 11 `textTertiary`: "The
    total is the agent’s. The split is Shepherd’s estimate from the messages." and, with an Other
    row, "…; Other is what it cannot itemize." Then a `lineSubtle` rule and **Compact now…**, a 30pt full-width
    button on `bgWindow` with a `lineStrong` line; it opens the field for what to keep (below) and
    **Compact now** in `lantern`. With no split to show (`.simple`), the total, the bar in
    `textTertiary`, the mark, and Compact now….
  - **Almost full** (ContextFull, past 85%): the title "Context almost full" and the total and
    percentage in `failed`; the bar; then the problem in 12.5 `textSecondary`: the biggest part
    ("Tool results are 138k of it.", or "Reasoning is 100k of it.", "Tool call contents are 90k of
    it.", "Images are…"), what pi will do ("The agent will compact on its own at 184k,
    before its next reply.", or "The agent will not compact on its own." when auto-compaction is
    off), and "Compact now to say what the summary should keep."; a field for what to keep (at
    least 52pt, `bgWindow`, a `lineStrong` line that turns `textTertiary` while focused, radius 8,
    a `lantern` caret); and **Compact now** in `lantern` (↩ in the field sends it too). What the
    field holds goes to pi as the compaction's instructions.
  - **Compacting:** "Compacting", "started 0:08 ago" ticking in the header, "Summarizing **184k**
    into a short brief. The last 20k stay as they are." (the size in mono `textPrimary`, the line
    shimmering), and a `running` bar that runs most of the way in the first seconds and never fills
    (pi says nothing of how far along it is). Nothing to press; it closes itself when the agent is
    done.
  - **Just compacted:** "Context" with "just compacted", "~23k of 200k" in `textSecondary` with
    "estimate", the bar dashed 4/3 in `textTertiary`, "The agent reports the exact number after
    its next reply. Was 184k." in 11 `textTertiary`, and **Show summary**, which opens what the agent
    kept in the thread and scrolls to it.
  - Compact now is pi's `compact`, which stops a run to compact: it is offered while the agent is
    idle, and its tooltip says why not while it works.
  - **No Compact automatically switch** (the user's call, 2026-09-25). pi offers it only as
    `set_auto_compaction`, which pi 0.87.1 writes to the user's own `settings.json`
    (`SettingsManager.setCompactionEnabled`), and Shepherd never writes pi's settings. The details
    read pi's `autoCompactionEnabled` for the mark and the almost-full text. The context boards
    no longer draw the switch.
- **iPad and iPhone** (ContextIdeas › A: "same spot on iPad and iPhone, tap opens the details as a
  sheet"; `App/iOS/Composer/ContextMeter.swift`): the same ring and button just before Send — in
  the iPad card's control row, and inside the phone's capsule — with a 44pt touch target around
  its 32pt circle, so it sits 14pt from Send's circle rather than 6pt (the targets never overlap).
  The ring stays while the agent runs (Stop lives in the header on iOS). Touch has no hover: the
  numbers are the ring's VoiceOver label and the sheet's; a pointer over it on iPad shows the
  tooltip. A tap opens the details as a sheet (`NWContextDetails(…, presentation: .sheet)`) on
  `bgRaised` with a drag indicator, fitted to the details' height (the whole screen when taller;
  a form sheet as wide as the form on iPad): the same header, total, bar, mark, split, Largest,
  footnote and buttons as the popover, at the sheet's width, with Largest's rows and the buttons
  at 44pt and "tap to find in thread". Almost full is the same sheet leading with the problem and
  the field for what to keep; compacting has nothing to press and the sheet closes itself when
  pi is done; just compacted offers Show summary. A tap on a Largest item or Show summary closes
  the sheet and scrolls the thread to it (loading older pages as needed); Esc on a hardware
  keyboard or a swipe down closes it. The thread's compaction lines are the Mac's (Thread ›
  Compactions): Show summary opens What the agent kept in place, and Copy puts the summary on
  the pasteboard. On a phone, or at a large text size, the line drops its rules, then puts Show
  summary under the words, which wrap; the summary's size goes under its title.

# Handoff spec — Shepherd native thread UI

> **Superseded by [`DESIGN.md`](../../DESIGN.md).** This is the first design handoff, as
> delivered and lightly formatted as Markdown, kept as history. Shepherd now implements Night
> Watch, the design system `DESIGN.md` describes (`Packages/ShepherdUI`), and most of what
> follows is gone from the code: the `Tokens`/`Fonts`/`Metrics` names, the mock palette, the
> type ramp, one-line tool rows and tool groups, the 52pt header, subagent rows in the sidebar,
> and many dimensions. Don't implement from this file; where it disagrees with `DESIGN.md`,
> `DESIGN.md` wins. The per-board renders live in [`boards/`](boards/) (iOS boards under
> [`boards/ios/`](boards/ios/)).

For the implementing agent. Source of truth for values: tokens.json (light + dark). Visual
reference: the Option A, Running, Tool row states, Foundations and Components artboards on
this canvas. Where this sheet and an artboard disagree, the artboard wins on layout and this
sheet wins on behaviour.

| Board | File |
| --- | --- |
| Thread, idle | [00-thread-idle.png](boards/00-thread-idle.png) |
| Thread, running | [01-thread-running.png](boards/01-thread-running.png) |
| Slash commands | [02-composer-slash.png](boards/02-composer-slash.png) |
| Model picker | [03-composer-model.png](boards/03-composer-model.png) |
| Command palette | [04-palette.png](boards/04-palette.png) |
| Tool row states | [05-tool-rows.png](boards/05-tool-rows.png) |
| Review pane | [06-review-pane.png](boards/06-review-pane.png) |
| Subagents, live | [07-subagents-live.png](boards/07-subagents-live.png) |
| Subagents, completed run | [08-subagents-completed.png](boards/08-subagents-completed.png) |
| Subagent card states | [09-subagent-cards.png](boards/09-subagent-cards.png) |
| Settings | [10](boards/10-settings-appearance.png) · [11](boards/11-settings-agents.png) · [12](boards/12-settings-worktrees.png) · [13](boards/13-settings-pi.png) · [14](boards/14-settings-remote.png) · [15](boards/15-settings-keyboard.png) · [16](boards/16-settings-advanced.png) |
| iOS | [17](boards/ios/17-ios-agents.png) · [18](boards/ios/18-ios-thread.png) · [19](boards/ios/19-ios-running.png) |
| Foundations | [20-foundations.png](boards/20-foundations.png) |
| Components | [21-components.png](boards/21-components.png) |
| This sheet | [22-handoff.png](boards/22-handoff.png) |

## 1 · Scope

Applies to the macOS thread view (DesktopNativeThreadView) and the sidebar. There is one view —
no Terminal/Native toggle. The iOS thread should adopt the same tokens and turn rules, with the
sidebar replaced by navigation.

Goals, in order: readable measure; user vs agent distinguished by shape not labels; tool
activity scannable in one line per call; nothing in the default view that isn't useful.

## 2 · Token mapping (Swift)

Replace ad-hoc colors in Tokens with the names below. Each has a light and a dark value in
tokens.json; resolve via a `Color(light:dark:)` helper or asset catalog colors of the same name.

| Token | Swift name | Use |
| --- | --- | --- |
| bg.canvas / surface / raised | `Tokens.bgCanvas` · `bgSurface` · `bgRaised` | window+sidebar · thread · composer/popovers |
| bg.muted / hover / hoverStrong / selected / bubble / track | `Tokens.bgMuted` … `bgTrack` | output area · row hover · sidebar hover · active row · user turn · segmented track |
| border.subtle / default / strong | `Tokens.borderSubtle` · `border` · `borderStrong` | row dividers · panels · buttons/composer |
| text.primary … disabled | `Tokens.text` · `textSecondary` · `textTertiary` · `textMuted` · `textDisabled` | replaces textDim, textSecondary |
| accent, success, danger, warning (+ .text, .bg) | `Tokens.accent` · `success` · `danger` · `warning`, each with Text/Bg suffix | replaces focusAccent, destructive |
| type.* | `Fonts.display` · `title` · `body` · `bodySmall` · `label` · `caption` · `section` · `code` · `output` · `micro` | replaces `Fonts.mono(size, weight)` call sites |
| size.*, space.*, radius.* | `Metrics.sidebarWidth`, `headerHeight`, `threadMaxWidth`, `toolRowHeight`, … · `Metrics.spacing2…32` · `Radius.xs…pill` | extends existing DesktopNativeMetrics |

## 3 · Layout

- **Window:** sidebar 256pt fixed (collapsible, ⌘⇧S) · main column flexible, min 720pt.
- **Header:** 52pt. Breadcrumb (project / thread title, title truncates) · status pill · spacer ·
  turn/ctx counter · options button. Padding 20pt.
- **Thread:** scroll view; content column `frame(maxWidth: 760)` centered; horizontal gutter
  32pt; top padding 28pt; turns separated by 28pt; nothing else separates them (no rules, no
  labels).
- **Agent prose:** `maxWidth: 680` so lines stay ~85 chars even though the column is 760.
- **User turn:** trailing-aligned, `maxWidth: 600`, padding 12×16, radius 12 with the
  bottom-trailing corner 4, fill bgBubble, bodySmall. Timestamp (micro, textMuted) below,
  trailing.
- **Composer:** pinned to the bottom of the main column in the same 760 column; a 30% gradient
  from transparent to bgSurface above it so the thread fades under it. Card: bgRaised, border
  borderStrong, radius 12, shadow composer. No key-hint row and no status text in or under the
  composer.
- **Sidebar:** 8pt padding; rows 32pt, radius 6; nested rows indent 22pt; section headers
  11/600 caps with a trailing count; bottom block (Automations, Shells) separated by a 1pt
  border.

## 4 · Turn rules

- No speaker labels anywhere. Role is carried by alignment + fill (user) vs plain prose (agent).
- Consecutive agent messages in one turn render as one turn: prose blocks separated by 10pt;
  tool calls that are consecutive collapse into a single ToolGroup; a prose block between tool
  calls splits the group.
- ThinkingDisclosure precedes the first prose of a turn when thinking exists: collapsed by
  default, "Thought for Ns" italic caption; while streaming it shows a spinner + "Thinking…".
  Expanded: 2pt left rule in border, italic tertiary prose.
- TurnFooter after the last block of a completed agent turn: copy, retry (28pt ghost icon
  buttons) and "time · duration · N tool calls" in micro/textMuted. Hidden while the turn is
  running.
- Streaming text appends in place; never re-layout earlier blocks. Auto-scroll only if the user
  is within 80pt of the bottom.

## 5 · Tool rows (ToolGroup · ToolRow)

One row per call, 36pt, in a group with border border, radius 10, fill bgSurface; rows divided
by borderSubtle. Columns, left to right, gap 10, padding 0 12:

| Slot | Content |
| --- | --- |
| Status glyph 14pt | running: spinner in accent · done: checkmark success · failed: × danger |
| Tool name, 40pt col | code font, textTertiary: read · edit · bash · grep · glob · write · web … |
| Preview, flexible | code font, text, truncates at the tail. read/write: path, plus `:start–end` in textMuted when a range was given. edit: path. bash: the command, first line only. grep: quoted pattern, "in", scope. Anything else: first non-empty output line, max 120 chars. |
| Result | 11pt. edit: DiffStat +n −m (success/danger) then "k blocks". read: "n lines". bash: exit 0 → "BUILD SUCCEEDED" / "n passed" / nothing if unknown, in successText; exit ≠ 0 → "exit n" in dangerText. grep: "n matches". |
| Duration | 11pt textMuted, 1 decimal under 60s ("10.2s"), otherwise "48s" / "1m 04s". Live while running. |
| Chevron 12pt | Only on expandable rows (bash, and any call with saved output). Expanded: row gets bgMuted (or dangerBg when failed) and an output block below: output font, textSecondary, padding 4 12 12 62, max 12 lines then "… n more lines" link that opens the full output in a sheet. |

Row hover: bgHover. Never show the raw JSON arguments inline; keep them behind ⌥-click →
"Show call" popover.

## 6 · Status model

| Agent state | Pill | Sidebar dot | Composer |
| --- | --- | --- | --- |
| idle | Idle · successBg/successText · dot success | grey (#c9c6bd); accent when it's the open thread | Send button, placeholder "Follow up, or / for commands…" |
| running | Running · Xm XXs · accent tint · spinner | success (green) — "alive" | Stop button (danger), placeholder "Queue a follow-up — sent when the turn ends". Field stays editable. |
| error | Error · dangerBg/dangerText | danger | Send button; InlineError banner above the composer with Reconnect. |
| stopped | Stopped · bgBubble/textSecondary | grey | Send button. |

## 7 · Keyboard & accessibility

⏎ send · ⇧⏎ newline · ⌘. stop · ⌘N new agent · ⌘D split · ⌘⇧B toggle pane · ⌘⇧S sidebar ·
⌘K command palette · / at line start opens the command list · ⌥⌘↑/↓ jump between turns.

Every control is a real Button/TextEditor; icon-only buttons carry `.accessibilityLabel`. Tool
rows expose "read, DesktopNativeThreadView.swift, 160 lines, done" as one label.

Colors meet 4.5:1 on their own background: textMuted is the lightest text allowed on
bgSurface; semantic .text variants only ever sit on their own .bg or on bgSurface.

Respect Reduce Motion: no spinner rotation, use a pulsing dot instead; no expand animation.

## 8 · iOS (App/iOS/ThreadView)

Same tokens, same turn rules; see the three iOS artboards. Differences from macOS:

- Navigation replaces the sidebar: Agents tab (grouped by host, each row = title + one-line
  live status in micro/mono), Shells, Settings. Row 56pt, chevron trailing. Unreachable host
  shows a dimmed card with Retry.
- Thread header: back · title (label/600) with the status line beneath it (pill text + dot, no
  pill fill) · options; the options button becomes Stop (danger) while running.
- Type: body 16 ×1.5, user bubble 15; tool rows 12 mono; bubble radius 14 with a 4 corner;
  thread gutter 16.
- ToolGroup on phone starts collapsed to one 44pt summary row ("6 tool calls · read 1 · edit 3
  · bash 2"); expanded rows are 40pt, paths truncate at the head (show the filename), and bash
  rows push to a full-screen output view instead of expanding inline.
- Composer: attach + pill field (44pt min, radius 22, grows to 5 lines) with the Send circle
  inside the field; sits above the keyboard with 30pt home-indicator padding.
- No permission or approval UI exists anywhere — Shepherd has no permission model. Tool calls
  run as the agent issues them.
- Touch targets ≥44pt everywhere; the 28–32pt desktop icon buttons become 40–44pt.

## 9 · Review pane (macOS)

A companion pane docked to the right of the thread, never a replacement for it: the thread
keeps running while you read the diff. While any right pane (review or subagent inspector) is
open the sidebar switches to its compact form: 184pt wide, 26pt rows (radius 5), 12pt labels,
6pt dots, 10pt section headers, 16pt nested indent, trailing slot only on the selected thread;
Automations and Shells collapse to one row each with a count; full titles in tooltips. It
returns to 256pt when the pane closes. Toggled with ⌘⇧B or the pane button in the thread
header; default width 600pt (min 480, max 50% of the window), left edge is the drag handle,
width persists per window. See the Review pane artboard (1600pt window: sidebar 232 · thread ·
pane 600).

- **Pane header** 52pt: "Review" with the scope + totals beneath in micro ("working tree vs
  HEAD · 4 files · +67 −58"); trailing Local | PR #n segmented (sm), options, close.
- **File strip** under the header (34pt, bgCanvas): one chip per file — status letter (M
  warning / A success / D danger / R accent), filename only, DiffStat; selected chip
  bgSelected; overflow shows "+n" and scrolls horizontally. No vertical file rail — the pane is
  too narrow.
- **File header** 36pt, sticky, bgMuted: collapse chevron, path with filename bold, hunk count;
  26pt icon buttons Open in Xcode · Revert (dangerText) · Viewed. Viewed files collapse and
  their chip dims.
- **Lines** 21pt, code 12 mono: old-number col 36 · new-number col 36 · sign col 14 · code.
  Removed rows dangerBg with − in danger; added rows successBg with + in success; hunk headers
  bgHover in textTertiary 10.5pt; context rows plain; syntax color on every row. Long lines
  truncate at the tail — hover shows the full line as a tooltip; never wrap.
- Runs of more than 8 same-sign or unchanged lines collapse to a 24pt strip ("13 more removed
  lines · 20–32") that expands in place; ⌥-click expands the whole file.
- **Inline comment:** hovering a line shows a 20pt accent + at the trailing edge; the card
  (bgRaised, borderStrong, radius 8) sits under the line, indented to the code column, with
  author, "line n · time", Edit. Comments are addressed to the agent and quoted back with
  file:line.
- **Thread ↔ pane links:** edit/write tool rows in the thread gain a trailing "review ›" link
  that opens the pane scrolled to that file; the pane's file chips highlight when the running
  agent touches that file again (chip gets a pulsing accent dot).
- **Review composer** pinned to the pane bottom: overall comment, "n inline · ⌘⏎", Commit
  (secondary, successText) and Request changes (primary). Request changes sends overall +
  inline comments as the next user turn — it queues if the agent is mid-turn; Commit sends
  "commit these changes" as the next user turn.
- **Keyboard inside the pane:** j/k hunks, n/p files, c comment, v viewed, ⌘⏎ send, esc returns
  focus to the thread composer.

## 10 · Subagents

A subagent is a turn inside a turn. Its spawn call renders as a SubagentCard in the ToolGroup
where the call was; the raw subagent_wait / status dumps never appear. See the Subagents window
and the Subagent card states sheet.

- **Card header** 40pt: branch glyph in the state color · name (label/600) · "mode · model ·
  thinking" in micro/textTertiary · trailing state: Running (spinner, accentText, elapsed) /
  Needs you (warning) / Done (success, duration) / Failed (danger). Needs-you cards tint the
  header warningBg; failed cards are one row on dangerBg with Retry + Transcript.
- **Running body:** progress row (step n/m, 4pt accent bar when the run reports steps, "turns ·
  tools · tokens" micro) and ONE live activity line — the subagent's latest tool call in ToolRow
  form with a relative time. Update in place; never grow the card while running.
- **Needs-you body:** the question as body text plus its choices as buttons (primary = the
  subagent's recommended option), a Reply… for free text, "n / m" when several are queued.
  Answering resumes the run; the parent's status pill shows "n subagents need you" and the app
  badges.
- **Done body:** the result summary as prose, then micro stats (files, DiffStat, tools, tokens)
  and Open transcript. Collapses to a single 40pt row once the parent turn moves on.
- **RunLedger.** After the whole run completes (parent idle, every subagent finished), the live
  cards are replaced in place by one RunLedger — see the Completed run artboard. Header 36pt on
  bgMuted: branch glyph, "n subagents", one 8pt state cell per run, "all done · wall time ·
  tokens", combined DiffStat + file count. Then one 44pt row per subagent, in spawn order: state
  glyph · name (72pt col, label/600) · its result summary in one line (bodySmall,
  textSecondary, tail-truncated) · "files · tools · duration" micro · chevron. Rows are links:
  click opens that run in the read-only inspector; the open one is highlighted accentBg with a
  3pt accent rule on the pane side. The ledger is permanent history — it is never collapsed
  away, and it stays clickable in old threads.
- TurnFooter of a turn that used subagents adds "· n subagents" as a link to the ledger.
- **Read-only inspector** for a finished run: header adds "k of n" and ‹ › to step between
  siblings; Goal strip gains a Result block (summary + touched files with DiffStat as links into
  the review pane); the transcript shows from the top with the parent's instruction as the first
  user turn ("from parent"); no Steer composer — the footer offers Re-run, Fork as new agent,
  Copy transcript, and "kept with the thread".
- **Actions on running cards:** Inspect (⌘I), Steer…, Pause, Stop (dangerText, trailing).
  Selected card gets the accent border + 12% ring, same as the composer focus ring.
- **RunsStrip:** more than 3 sibling runs collapse into one row — count, one 8pt cell per run in
  spawn order colored by state, "7 done · 3 running · 1 needs you · 1 failed", totals. Needs-you
  runs still render their own card beneath the strip. Clicking a cell opens that run in the
  inspector.
- **Inspector** is the docked right pane (shares the review pane's slot and width rules): header
  with name, mode/model/turns/tokens, Pause/Stop; a Goal strip; the subagent's own transcript in
  the same ToolGroup/prose components one step smaller (34pt rows, 14pt prose), following live
  with "n earlier turns · Show all"; a Steer composer whose placeholder and "to: worker · not
  the parent" line make the recipient unambiguous.
- **Sidebar:** subagents nest under the parent thread at depth 2 with a tree line; the branch
  glyph replaces the status dot and carries the state color; trailing slot shows elapsed /
  "needs you" / duration. While any run is live the group is always expanded. Once the parent
  turn ends the group gets a disclosure header ("3 subagents · done 11:09"), stays expanded for
  the selected thread and collapses for others, whose row shows "n sub" in the trailing slot.
  Subagent rows are kept as long as the thread is; selecting one opens the read-only inspector.
- **Composer while subagents run:** Stop stops all runs and asks once when more than one is live.

## 11 · Composer menus — slash commands & model

Both open above the composer card, left-aligned to it, 8pt gap; bgRaised, borderStrong, radius
12, shadow 0 8 28 14%. The composer takes the accent focus ring while a menu is open. See the
Slash commands and Model picker artboards.

- **SlashMenu** opens when "/" is typed at the start of a line (or the "/ commands" chip is
  clicked) and filters as you type. Full composer width, max 8 rows then scrolls. Header
  "Commands · n of m". Row 36pt: command in mono 150pt col with the typed prefix bold and
  argument hint ([session]) in textMuted · one-line description · optional source tag ("prompt"
  for user prompt templates) · ⏎ glyph on the highlighted row. Highlight = accentBg. No footer
  or key hints; ↑↓ select, ⏎ run, ⇥ completes the command plus a space for args, esc closes.
  Command list comes from the agent's command registry plus prompt templates — never
  hard-coded.
- **ModelPicker** opens from the model chip (or ⌘M). 380pt wide, anchored over the chip. Search
  field on top; groups: Recent (last models used in any thread), then per provider. Row 40pt:
  check for current · model id in mono + one-line note · context size. Model only — no
  reasoning settings inside it.
- **ThinkingChip** sits in the composer action row right after the model chip: bulb glyph ·
  "Thinking" · current level (Off / Low / Medium / High) · chevron. Clicking opens a small menu
  with the four levels; it is independent of the model and applies from the next turn. Hidden
  when the selected model has no reasoning control.
- **Keyboard:** arrows move, ⏎ picks, esc closes and returns focus to the composer text. Only
  one menu open at a time.

## 12 · Command palette & Settings

- **Command palette (⌘K):** 640pt card, 120pt from the top of the window over an 18% scrim;
  radius 14, bgRaised, large shadow. 56pt search row (16pt text, search glyph) with scope pills
  All · Commands · Agents. Results grouped under 10.5pt caps headers — Commands, This thread,
  Subagents (and Agents when searching). Row 38pt: 15pt stroke icon · label (14pt sans, not
  mono) · optional context in textMuted · real shortcut as keycaps on the right. Highlight =
  accentBg with an accent icon. Subagent rows use the branch glyph in their state color. No
  footer hints; ⌘1–9 numbering is dropped — only real shortcuts are shown.
- **Settings** replaces the app window content (Back to Shepherd at the top of its own 232pt
  nav): search field (⌘F), sections Appearance · Terminal · Agents · Worktrees · Pi · Remote ·
  Keyboard · Advanced with 15pt icons, versions pinned at the bottom. Content column 720pt, 44pt
  top padding; page title 22/600 with a one-line explanation.
- **Settings rows** live in grouped cards (bgSurface, border, radius 10, rows divided by
  borderSubtle, min 52pt): title 13.5/500, description 12.5 textTertiary, control on the right.
  Controls: SegmentedControl for 2–4 exclusive options, a 38×22 accent switch for booleans, a
  popup button (bgRaised, borderStrong, chevrons) for longer lists, stepper, slider with a mono
  value, keycaps for shortcuts, secondary buttons (danger text for destructive). Footnotes under
  a group are 12pt sans textMuted — never mono paragraphs.
- Inline problems sit in the row (e.g. Remote › Listener shows the bind error in dangerText
  under its description) rather than replacing the description.
- The old Conversation › Default View setting is gone along with the Terminal/Native header
  switch. Runtime (Terminal vs Native RPC) stays as a creation-time choice.

## 13 · Build order

1. Add tokens (colors, fonts, metrics) and switch existing call sites — no visual change
   intended yet beyond palette.
2. Thread column width + user bubble + remove speaker labels.
3. ToolRow / ToolGroup with previews and DiffStat (needs a small edit-payload parser for +/−
   counts).
4. Header status pill, TurnFooter, ThinkingDisclosure.
5. Composer states (idle / running / queued follow-up).
6. Sidebar rows and section headers; dark mode pass with the dark token set.
7. iOS: Agents list, thread header, collapsed ToolGroup, pill composer.
8. Review pane: file strip, colored unified diff with collapsed runs, inline comments, review
   composer; Split mode last.
9. Subagents: SubagentCard states, RunsStrip, inspector pane with Steer, sidebar nesting.
10. Composer menus: SlashMenu (registry-driven), ModelPicker, ThinkingChip.
11. Command palette and Settings pages.

Tests: extend NativePresentationTests — preview text per tool kind, DiffStat counts, duration
formatting, status → pill mapping.

# Up next (the queue)

> Read when you change the queue above the composer, steering, or Send now.

Messages sent while pi works stack in **Up next** (QueueStack, QueueSteer, QueueEdit, QueueStates;
`QueueStackView` in `Thread/QueueStack.swift`, on ShepherdUI's `NWQueueStack` and `NWQueueRow`;
sizes are `NWQueueMetrics`): a card directly above the composer card, in the same column,
`AppLayout.menuGap` (8pt) above it, under any widgets and banners. The host holds the queue
([native-thread.md](../native-thread.md) › The queue; its rules are `NativeQueueRules`, shared by
the host and every client), so every Mac viewing the agent sees and edits the same one. Nothing in
it has reached pi, except a Steering row. Each message can be steered now, edited, reordered, or
deleted. Waiting is what Return does: the message goes when pi finishes this turn. **Steer now**
stops pi and sends it at once. Nothing steers at pi's next step any more (the user's call,
2026-09-30), so a message sent while pi works is a queued row from the start, numbered in the order
it goes. A Steering row (below) only shows where Steer now falls back to a steer: a host that
cannot stop pi, a compaction, or an older client's send.

- **Placement:** it shows while it has a row to show: a message, or an Undo row (a lone Undo row
  reads "Up next 0"). The card never moves: the stack grows upward, and the thread's inset follows
  the composer's measured height, so the thread keeps its last turn in view
  (`QueueStackIntegrationTests`). Collapse and Show more are view state (`QueueStackState`) and
  are never saved; the stack forgets its expansion once it empties.
- **The card:** `bgRaised`, a 1px `lineStrong` line drawn inside (`nwBorder`), radius `NW.Radius.m`
  (8). A 32pt header (`NWQueueMetrics.headerHeight`; 12pt leading, 6pt trailing, items 8pt apart, a
  hairline beneath): the queue glyph (`NWQueueGlyph`, 12pt, `textTertiary`: a line, then two
  indented lines behind a play mark), "Up next" in `.nwSans(12, .semibold)` `textSecondary`, the
  count in `.nwMono(11)` `textTertiary` (every message, steering ones included, never an Undo row;
  it rolls, `content`), "Paused" in `.nw(.caption)` `textTertiary` while the queue waits (its
  tooltip is the host's reason, else "The queue waits for you: send it, steer it in, or send a new
  message."), a spacer, then ••• (`NWOptionsMenu("Queue options")`) and Collapse (`chevron.down`;
  tooltip "Collapse the queue", or "Expand the queue"), both 24pt circular icon buttons
  (`NW.Height.controlS`). The chevron turns up while collapsed, and a collapsed stack is its header
  alone. Rows follow, a hairline above each but the first; they keep to the card's bottom corners.
- **A queued row** (`NWQueueRow`; QueueStack, QueueStates · queued and hover; 40pt, not scaled by
  Density; 8pt leading, 6pt trailing, items 8pt apart): the grip (`NWGripGlyph`, six `textTertiary`
  dots in an 8×14 slot, shown on hover or focus: the only drag handle, with the open-hand pointer,
  closed while dragging), its number (`NWQueueNumber`: `.nwMono(10.5)` `textSecondary` in an 18pt
  `lineStrong` ring: the order it goes, not a count, never counting Steering or Deleted rows; it
  rolls when the order changes), the text in `.nwSans(13)` `textPrimary` on one line, truncated at
  the tail (a click edits it; tooltip "Edit"), its attachments (below), and an 82pt slot
  (`NWQueueMetrics.actionsWidth`) that always keeps room for its actions, so hovering never
  re-truncates the text. The actions are built only while the row is hovered or focused: Steer now
  (`arrow.turn.down.right`; **Send now** while pi is idle), Edit (`pencil`), and Delete (`trash`),
  26pt circular icon buttons (`.nwIcon`: 14pt glyphs in `textSecondary`; under the pointer
  `textPrimary` on `bgHover`, and `bgSelected` while pressed) 2pt apart, with system tooltips
  saying what they do and naming their keys ("Stop the agent and send this now  ⌘↩", "Delete  ⌫").
  Steer now stops pi: until the host has sent the message it stays a queued row, first in the
  stack (#1), and then it leaves for the thread as an ordinary message that starts the next turn
  (its "From the queue · 1" only when it was queued to begin with; a message sent with ⌘↩ from
  the composer never shows the label). The Steering row itself has no Steer now. Hovered, the row is `bgHover`; with
  keyboard focus it is `bgSelected` with the `focusRing` ring drawn inside it (2pt, inset 2pt,
  radius 6), since a ring outside would cover its neighbours.
- **Attachments** (QueueStates · with attachments) ride along with the message and sit after its
  text as compact chips (`NWAttachmentChip(size: .compact)`, 4pt apart): 22pt, a 1px `lineStrong`
  line, radius 4, the name in `.nwSans(11)`, 6pt padding; an image leads with its 16pt thumbnail
  (radius 3, 3pt leading), or an 11pt `photo` glyph where the bytes stayed on another Mac. The
  chips keep their width and the text truncates first. Elements picked in the Browser ride along
  too (Side pane: Browser): an element chip (`NWElementChip(size: .compact)`) leads with an 11pt
  element glyph (a dashed square with a pointer) in `textSecondary`, then its label in
  `.nwMono(11)`, e.g. "button.pay", before any images. **Not built yet:** files; the board draws
  no file chip.
- **A Steering row** (QueueSteer, QueueStates · steering) is the fallback's: it shows only where
  Steer now cannot stop pi and steers the message in instead (a host without
  `native.interrupt.v1`, a compaction, a prompt still on its way, pi refusing the abort) or an older
  client sent a steer. Return and Steer now on a host that stops pi never draw one. It is always
  first, above the queued rows, in the order they were steered, on `runningTint` (hovered or
  focused too; focus adds the ring): the
  grip's slot stays empty, then the still 14pt steer glyph (`arrow.turn.down.right`) in `running`
  where a queued row has its number (so its text starts 4pt further left; LiveText: waiting isn't
  working, so nothing on it moves), the text, `NWStatusPill(.running, label: "Steering", symbol:
  "arrow.turn.down.right")`, and Back to the queue (`arrow.uturn.backward`, a 26pt icon button 4pt
  after the pill), both shown at rest, not only on hover. Back to the queue returns it to the queue
  as #1 until pi reads it; if pi has already read it, the host refuses ("The agent has already read that
  message." as the composer's notice) and the message lands in the thread where pi read it. It has
  no grip, number, Edit, or Delete, its text is not a click target, and nothing drops above it.
  Stop also returns every Steering row to the queue (Composer › States).
- **Editing** (`NWQueueEditor`; QueueEdit, QueueStates · editing): a click on the text or the
  pencil, ↩ on a focused row, or ↑ in an empty composer with no menu open (for the last queued
  message) opens the row in place. The row sinks to `bgWindow` with 8pt padding (24pt leading, so
  the number keeps its column): the number top-aligned beside a field of one to six lines
  (`.nwSans(13)` at the board's 1.5 line height, `textPrimary`, 8×10 padding, `bgRaised`, radius 6,
  a `lantern` line inside a 3pt `lanternTint` ring, a `lantern` caret after the text, placeholder
  "Queued message"), and under it, trailing and 6pt apart, Cancel (`.nw(.ghost, size: .s)`) and Save
  (`.nw(.secondary, size: .s)`, since Send stays the surface's primary; disabled while the text is
  empty). ↩ saves, ⇧↩ adds a line, Esc cancels. The message keeps its place and number. One editor
  is open at a time: opening another cancels the first. While it is open, the host holds the queue
  (renewed every `AppLayout.queueHoldRenewal`, a minute; a hold lapses after two), so nothing is
  delivered under you; saving unchanged text only releases the hold. If the message leaves the queue
  meanwhile (another Mac steered or deleted it), the editor closes.
- **Deleted** (`NWQueueDeletedRow`; QueueEdit, QueueStates · deleted): the delete goes to the host
  at once, and an Undo row takes the message's place, cross-fading in the same 40pt (34pt leading,
  `NWQueueMetrics.secondaryInset`, so it starts under the number column; 12pt trailing): a 12pt
  `trash` glyph, "Deleted" and the struck-through text in `.nw(.ui, weight: .regular)`
  `textTertiary` on one line, and Undo (`.nwLink(font: .nw(.ui))`, `running`). It counts in neither
  the header nor the numbers. It closes after `AppLayout.queueUndoWindow` (5s), counting only while
  the pointer is off it, and Undo puts the message back where it was. Clearing the queue leaves one
  such row, "Cleared 3 messages" ("Cleared 1 message"), that puts them all back. A message that
  comes back another way (Undo on another Mac, or a delete the host refused) takes its Undo row's
  place.
- **Long stack** (QueueStates · long): up to three rows (Steering, queued, and Undo rows alike) all
  show; past three, the first two and "Show N more" (`NWQueueMoreRow`: a 32pt row, 34pt leading,
  `.nwLink(font: .nwSans(12))` in `running`), so the thread keeps its room. It expands the stack in
  place ("Show fewer"). Expanded past six rows, the rows scroll inside a 240pt frame
  (`NWQueueMetrics.expandedMaxRows` × 40) with "Show fewer" pinned beneath. An editor opened below
  the fold expands it.
- **Reordering** (QueueStates · reordering): dragging the grip lifts the row out of the stack onto a
  floating card (`bgRaised` under `bgHover`, radius 8, a `lineStrong` line, the popover's shadow
  (`nwFloatShadow`), a 1° counter-clockwise lean, `NWQueueMetrics.liftTilt`), 22pt right of its slot
  and 14pt past the stack's trailing edge (`NWQueueMetrics.liftInset`), over its neighbours, the
  drop line, and the composer card. It keeps its grip but shows no actions, and follows the pointer
  at once, up to half a row past the first and last rows. Past the middle of a neighbour it takes
  the neighbour's side: the neighbours step aside (`list`), and a 2pt `lantern` drop line
  (`NWDropIndicator(color: .nw.lantern)`, inset 8pt each side) tops the gap. Letting go where it
  began changes nothing. Nothing drops above a Steering row. ⌥↑ ⌥↓ move a focused row one place.
- **The ••• menu** (QueueStates · QueueOptions; native, `NWOptionsMenu`): Steer all now (stops pi
  and sends every queued message at once, in order, as one turn; help "Stop the agent and send
  these now, in order"; `arrow.turn.down.right`; **Send all now** with `arrow.up` while pi is
  idle), a divider, the
  section "When the turn ends, send" with an inline picker of One message per turn and Everything at
  once (a check on the current one; this agent's choice, else the host's default from Settings), a
  divider, and Clear the queue (`trash`, destructive, leaving its Undo row; Steering rows stay).
  Steer all and Clear are disabled while nothing is queued. **Everything at once** is the default:
  the queue arrives as one turn, in order, the messages joined with a blank line; a message that
  starts with "/" goes alone, and one delivery carries at most 4 images and 64 KiB
  (`NativeQueueRules.batchCount`).
- **Keys** (QueueStates · Keyboard; shown in menus and tooltips and listed under Settings ▸ Keyboard
  ▸ While the agent is working, never written in or under the composer): ↩ queues the message and
  ⌘↩ sends it as Steer now (Composer › Sending while pi works); ↑ in an
  empty composer edits the last queued message; ⌥↑ ⌥↓ move the focused message; ⌫ deletes it; ⌘↩
  steers it (sends it now while pi is idle); Esc in the composer stops pi. With keyboard navigation
  on, ⇥ reaches the rows. On a focused row ↑ ↓ move between rows (↓ past the last returns to the
  field), ↩ edits, and Esc or ⇥ return to the field. Deleting a focused row hands focus to the next
  row, else the previous, else the field. On a focused Steering row only ↑ ↓, Esc, and ⇥ do
  anything.
- **Settings** (QueueStates · Settings › Agents · While the agent is working; see Settings): one row,
  an `NWSegmentedPicker`. "When a turn ends, send the queue", subtitle "All at once arrives as one
  turn, in the order you queued it.": One per turn or **All at once** (the default); it is the
  host's default for its agents, and each agent's ••• menu overrides it. There is no Return setting:
  ↩ always queues and ⌘↩ always steers now (the QueueStates board's "Return while the agent is
  working" row is retired). iPhone and iPad have the same row in a host's settings (and the
  delivery mode in each thread's Up next menu).
- **Motion:** the stack comes and goes with `list` from the bottom (the card stays anchored); a
  queued row rises from the bottom, and a row pi takes leaves toward the thread (`list`) while the
  numbers roll (`content`); hover fills, the grip, and the actions fade (`hover`) in slots that
  are always laid out; Steer now and Back to the queue move the row (`list`) while its number and
  spinner, and its actions and pill, cross-fade (`content`); Show more and Collapse disclose
  (`disclosure`). No bubble flies from the stack into the thread.
- **In the thread** (QueueStates · In the thread, QueueSteer; Thread › From the queue and Steered):
  queued messages join the thread only when they reach pi, each keeping the time you sent it. A
  delivery opens with `NWQueueDivider` ("From the queue · 2") and one bubble per message, then pi's
  turn. A steer (the fallback's, or an older client's) stands where pi read it, between tool calls,
  in a bubble with a `running` outline under "Steered". No line says what a steer skipped.
- **Limits and refusals:** the host holds at most 32 messages and 64 KiB of text. A send past that
  is refused with "The queue is full. Send it or clear some of it first." Like any refused queue
  action, the host's message shows as the composer's notice line above the card (caption
  `textTertiary`). A delivery pi refuses puts the messages back at the head and pauses the queue,
  with the reason in the header's tooltip.
- **Accessibility:** the header reads "Up next, 3 messages". A queued row reads "Queued 2 of 3:
  <text>" with the actions Steer now (or Send now), Edit, Delete, Move up, and Move down; a Steering
  row reads "Steering: <text>, waiting for the agent's current tool calls" with Back to the queue; Steer now
  carries the hint "Stop the agent and send this now"; the
  editor's field is "Edit queued message 2"; an Undo row reads "Deleted: <text>" (or "Cleared 3
  queued messages") with Undo. The glyph, the grip, and the number are hidden from VoiceOver.

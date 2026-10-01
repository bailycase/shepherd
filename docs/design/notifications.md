# Notifications and Live Activities

> Read when you send a notification or build a Live Activity, on the Mac or iOS.

How Shepherd reaches you outside its window, on iPhone, iPad and Mac. The authority is the
Notifications page (NotifCatalog, NotifPhoneBanner, NotifPhoneStacks, NotifPhoneRich,
NotifPhoneReply, NotifPhoneReview, NotifPhoneSummary, NotifSettings, NotifiPadBanner,
NotifiPadCenter, NotifMac) and the lock-screen boards (MobileLock, MobileAnswer, MobileLiveLock,
MobileIsland, iPadLock).

**What is built:** only the Mac's notifications, for its own agents and every connected host's
(`AgentNotifications`, worded by `AgentBanners`, posted by `ShepherdViewModel+Notifications.swift`;
On the Mac today, below). The iOS client posts no notifications and has no Live
Activities or widgets: it drops every host's connection in the background, and a push needs a relay
that doesn't exist yet ([docs/ios](../ios/README.md) › Not in the first release). On iPhone and
iPad, Home's Needs you inbox stands in: questions and blocked threads across hosts, answered in
place when short. Everything else in this section is **not built yet**, and several kinds wait on
features that don't exist either (Missions, plan approval, token budgets, Designs).

**Who draws what.** The system draws a notification: its card, its type, the app icon, the relative
time, the "TIME SENSITIVE" label, stacks, and where the actions appear. Shepherd decides the words
(title, subtitle, body), the actions and their order, the interruption level, the group
(`threadIdentifier`), what a tap opens, and any rich content (a content extension, attachments). So
the boards' notification cards are the system's, filled with Shepherd's content. A Live Activity,
the Dynamic Island and a widget are Shepherd's own drawing, in Night Watch. Where a board draws
something only the system decides, this section says so. Never rebuild the system's chrome inside
the app to get it.

## The catalog

Every notification Shepherd sends, in three groups (NotifCatalog): **Needs you** (the `attention`
state), **Problems** (`failed`) and **Finished** (`done`). Titles name the thing. Bodies are one
sentence. Actions are the same choices the app shows for that moment, never more. In Needs you and
Problems the first action is the recommended one, and the only one in lantern wherever a surface
draws emphasis (a Live Activity, the iPad boards' buttons); Finished work's actions are plain.

| Group | Kind | Title | Body (the board's words) | Actions, in order | Level | Grouped by |
| --- | --- | --- | --- | --- | --- | --- |
| Needs you | Planner question | the mission ("Refund events") | the question: "Which key joins a refund to the funnel?" | each option, the planner's pick first ("order_id", "payment_id"), then Reply… | Active | mission |
| Needs you | Subagent question (**not sent**: a subagent asks its parent, never you) | "thread · subagent" ("Restyle native UI · reviewer") | the question: "Rename the new tokens, or replace the old ones everywhere?" | each option the subagent offered ("Replace everywhere", "Rename new ones"), then Reply… | Active | thread |
| Needs you | Plan to approve | the thread ("Dock review pane") | "Plan ready: dock the review pane on the right." | Approve plan, Open | Active | thread |
| Needs you | Stuck lane | the mission ("Checkout funnel events") | "orders is stuck after 3 tries." (the banner adds the planner's pick: "The planner suggests a retry with a hint.") | Retry with hint, Replan the lane, Open | Time Sensitive | mission |
| Needs you | Out of budget | the mission | "Paused at 6M tokens. About 0.9M to finish." | Add 1M and resume, Open | Time Sensitive | mission |
| Needs you | Off the map | the mission | "Paused: a contract change needs a patch." | Review patch | Active | mission |
| Needs you | Ready to review | the mission | "4 PRs ready. Contract: 10 of 10 passed." | Approve · start train (needs Face ID; the board's chip carries a lock), Open | Active | mission |
| Needs you | Automation question | the automation ("Triage new Sentry issues") | the question: "Is this a regression from #231?" | each option ("Yes, open a fix", "No") | Active | automation |
| Problems | Turn failed | the thread ("Fix remote nightly") | what failed: "Build failed in RemoteClient.swift." | Retry, Open | Active | thread |
| Problems | Automation failed | the automation ("Weekly dependency bump") | "1 PR failed CI." | Retry, Open | Active | automation |
| Problems | Host offline | "*host* is offline" ("horizon is offline") | what waits on it: "1 automation paused until it's back." | Retry | Active | host |
| Finished | Turn finished | the thread ("Investigate SwiftUI live preview") | the turn's result: "Done. 3 files changed, tests pass." | Review | Passive | thread |
| Finished | Mission merged | the mission | "Merged in order: 4 PRs in 2h58." | Open | Passive | mission |
| Finished | Automation passed | the automation ("Nightly migrations dry run") | "3 migrations, all reversible." | none: a tap opens it | Passive | automation |
| Finished | Boards ready | the design ("Onboarding flow") | "4 boards drawn in acme-web." | Open | Passive | design |

- **The subtitle is the kind** as this table names it ("Planner question", "Turn finished"), plus "·
  *where*" when the moment has a place ("Stuck lane · orders-svc"). Host offline's is "Host"
  (NotifiPadCenter).
- **Which setting covers a kind** (NotifSettings › Send me): Questions and approvals (planner and
  automation questions, plans, reviews; a subagent's question is not sent), Blocked work (stuck lanes, empty budgets),
  Failures (failed turns, failed automations, hosts going offline), Finished work.
- **Built:** on the Mac, Automation question, Turn failed, Turn finished and Host
  offline, plus a thread's own question (any pi dialog: "Question"), each as this table words it
  (see On the Mac today). An automation's run is an ordinary agent wearing the automation's name,
  so its question asks as Automation question, and its failure and finish post as that agent's
  (Automation failed and Automation passed have no kind of their own yet). Nothing else in the
  table exists yet: Missions, plan approval, budgets and Designs are not built.

## Rules for sending

As the board lists them (NotifCatalog › Rules):

1. **One device: the one you're using.** If the Mac had input in the last 2 minutes, only the Mac
   gets it. Otherwise the phone or iPad you used last does (NotifSettings' "Only when I'm away from
   my Mac").
2. **Answer once, gone everywhere.** Answering on any device clears the notification from the
   others. The board clears it with a silent push.
3. **Progress is a Live Activity.** Running threads, missions and automations update their Live
   Activity. A notification only marks a change that needs you, or an end.
4. **Time Sensitive only when blocked and spending.** A stuck lane or an empty budget can break
   through Focus. Nothing else can: every other Needs you kind and every Problem is Active.
5. **Successes are quiet.** Finished work is Passive and lands in the Scheduled Summary; failures
   are Active. (Whether Shepherd is in the Scheduled Summary is the person's choice in iOS Settings;
   Passive is what Shepherd sets.)
6. **Grouped by the thing, not the app.** `threadIdentifier` is the mission, thread, automation,
   host or design (the board's payload: `"thread-id": "mission:anl-214"`), so a busy mission is one
   stack.
7. **Never a permission prompt.** No notification asks to allow a command or a tool. They carry
   decisions about the work, not about the agent's access (Principles › No permission model).
   **Built:** the Mac's notifications carry turns, questions and hosts only.
8. **Approving code needs Face ID.** An action that merges or pushes is `.authenticationRequired`,
   so a locked phone can't start a merge train. NotifPhoneReview asks for Face ID even on an
   unlocked phone; `.authenticationRequired` alone asks only for an unlocked device, so that needs
   Shepherd's own Face ID check before it acts.
9. **Quiet while you watch.** No notification for a thread that's open on screen; its Live Activity,
   or the view itself, already shows it. **Built on the Mac:** nothing posts about a thread while
   it is selected and Shepherd is frontmost (a remote thread too), nor about a host whose thread is
   on screen; a question seen that way does not post later either.

## Anatomy

A notification, top to bottom (NotifCatalog › Anatomy; NotifPhoneBanner):

1. **Interruption level:** "TIME SENSITIVE" over the title, on stuck lanes and empty budgets only.
   The system draws it.
2. **Title:** the mission, thread or automation (the host, for Host offline), never "Shepherd".
3. **Subtitle:** the kind and where: "Stuck lane · orders-svc".
4. **Body:** one sentence, with the planner's pick when there is one: "orders is stuck after 3
   tries. The planner suggests a retry with a hint."
5. **Long press** (on a banner, pulling it down) shows a rich view (attempts, lanes, thumbnails) and
   up to three actions.

**A tap opens the thing it names,** straight to what asked, even from a cold launch: the mission (at
the station that asked, MXNav), the thread at its question, the automation's run, the review, the
boards. **Built on the Mac:** a click brings Shepherd forward and selects the thread (a remote one
too), and a click that launches Shepherd still lands; a host's opens the Hosts page; a banner whose
thread is gone only brings Shepherd forward.

Words follow the boards: sentence case, the thing's own name, " · " between parts, figures as digits
("3 tries", "4 PRs", "10 of 10 passed"), durations as the app writes them ("2h58", "1h38").

## Actions and answering

The board's categories (NotifCatalog's `NotificationCategories.swift`):

| Category | Actions (identifier, title, options) |
| --- | --- |
| `shepherd.stuck` | `retry-hint` "Retry with hint"; `replan` "Replan the lane"; `open` "Open" (`.foreground`) |
| `shepherd.review` | `approve` "Approve · start train" (`.authenticationRequired`). The board's code has only this action; NotifPhoneReview lists Open review under it |
| `shepherd.question` | one action per option the asker offered, then `reply` "Reply…": a `UNTextInputNotificationAction` whose button is "Send", with the placeholder "Tell the planner…" for a planner question |

- **Order:** the recommended answer first (the planner's pick), then the other options, Reply…, and
  Open last. Where the system lists actions (a long press on iPhone), up to three show
  (NotifCatalog); MobileAnswer's four (two options, Reply…, Open mission) is the most any board
  lists.
- **Glyphs** (SF Symbols, `UNNotificationActionIcon`), as the boards draw them: `checkmark` on the
  planner's pick (MobileAnswer), `arrow.clockwise` on Retry, `map` on Replan the lane, `text.bubble`
  on Reply…, `faceid` on Approve · start train, `chevron.right` on Open (Open mission in
  NotifPhoneRich, Open review). Other options carry none. MobileAnswer draws `map` on its Open
  mission instead; the boards disagree, so settle it before building.
- **Answers go where the question came from.** A typed answer or a chosen option goes to the
  planner for a planner question, and to pi's dialog for a thread's. The boards also draw a reply
  that goes to the subagent that asked (NotifPhoneReply: "Goes to the reviewer, not the parent
  thread."), which Shepherd does not build: a subagent never asks you. Tapping a choice needs no typing.
- **Answering never opens Shepherd** (NWMissions: the choices are actions "so answering never opens
  the app"). Open, Review and Review patch open Shepherd at the thing.

## iPhone

**Not built yet.** The iPhone posts nothing today (What is built, above).

- **Banner** (NotifPhoneBanner): a Time Sensitive stuck lane shows over any other app, with the
  anatomy above. Pulling the banner down shows the choices; tapping it opens the mission.
- **Notification Center** (NotifPhoneStacks): stacks by `threadIdentifier`, so a mission's
  notifications are one stack ("2 more from this mission" under the newest), and each thread,
  automation and host is its own. Finished work collapses ("3 more finished · in your 6 PM
  summary"). The stuck lane leads the list; NotifCatalog's payload gives it `relevance-score` 0.9.
- **Lock Screen** (MobileLock): the board draws three notifications under the clock (the stuck lane,
  a planner question, and an automation's finish: "Merge PR #24 after CI", "Merged. main is
  green."), then the mission's Live Activity (Live Activities, below). The system decides that
  order. The board draws a question as "Refund events · question" with no subtitle and the options
  in its body ("…: order_id or payment_id?"); the catalog's anatomy (the kind as subtitle, the
  question as the body) is the rule.

**Rich views** (a long press). Each is Shepherd's own content in the system's expanded card, drawn
in Night Watch from the same tokens as the app: `bgRaised` behind (radius 20, padding 14 × 16,
its blocks 12pt apart in the stuck-lane view, 10pt in the review), `textPrimary` text,
`textSecondary` for supporting lines, `textTertiary` for meta, `lineSubtle` hairlines, a 26pt app
icon (radius 6) beside the title (14pt semibold) and its meta (a mono 10pt "TIME SENSITIVE" in
`lanternText`, or the time at 12pt in `textTertiary`). Under the card, the system lists the actions
(Actions and answering).

- **Stuck lane** (NotifPhoneRich): the mission's lanes as `NWLaneStrip` rows ("A lane as a tiny
  subway line", NWMissions; not built): the lane's name (mono 11pt, `textSecondary`, a 90pt column),
  a 120pt three-stop track (9pt stops joined by 2pt lines in `done`; a finished stop filled `done`,
  the running one a ring in `running` on `bgRaised`, the stuck one filled `failed`), then where it
  is in mono 10.5pt ("done" and "at join" in `textTertiary`, "go test" in `running`, "stuck" in
  `failed`), 20pt rows 4pt apart. Under a hairline: the headline ("orders is stuck after 3 tries",
  14.5pt semibold), then each attempt (a 16pt circle outlined in `failed` with its number in mono
  9.5pt, then what that try did at 12.5pt in `textSecondary`: "Wrote OrderPlaced after InsertOrder",
  "Wrapped the test in a savepoint · same failure", "Reset the outbox · same failure"), rows at
  least 24pt. Last, the planner's read on `bgSunken` (radius 12, padding 10 × 12): "Planner's read"
  (11.5pt, `textTertiary`) over its paragraph (13pt, line height 1.45) ending in the hint. Actions:
  Retry with hint, Replan the lane, Open mission.
- **Planner question** (MobileAnswer): the question, then under a hairline why it matters (13pt,
  `textSecondary`: "Changes the validation contract, so nothing is drafted until you answer. The
  rest of the brief is ready."), then each option: its name in mono semibold (an 84pt column) and
  what choosing it means in `textSecondary` ("payments-svc already has it on every refund"), the
  pick marked "· planner's pick" in `lanternText`. Actions: the pick (`checkmark`), the other
  option, Reply…, Open mission.
- **Subagent question, replying** (NotifPhoneReply; **not built**: a subagent never asks you): the question notification on top; under it,
  over the keyboard, the choices as 34pt buttons (radius 8, `bgRaised`, 13.5pt) on a `bgSunken`
  strip, then the reply field: a capsule at least 38pt tall (radius 19, `bgRaised`, a `lineStrong`
  border, 16pt text, a lantern caret) with **Send** beside it (16pt semibold, `running`). Tapping a
  choice answers without typing. The typed answer goes to the subagent that asked.
- **Ready to review** (NotifPhoneReview): the mission and "now", then "Ready to review" (15pt
  semibold); "Contract: 10 of 10 passed" (13pt) after a `checkmark.shield` in `done`, and "· merges
  in this order" in `textTertiary`; then one row per PR in merge order, at least 26pt: its place
  (mono 10.5pt, `textTertiary`, a 12pt column), the repository (mono semibold), the PR number (mono
  11.5pt, `running`) and `NWDiffStat` (mono 11pt). Actions: Approve · start train (`faceid`), Open
  review. Approving asks for Face ID even on an unlocked phone ("Approving needs Face ID, even with
  the phone unlocked. The diffs are one tap away in Open review.").
- **Scheduled Summary** (NotifPhoneSummary): finished work arrives Passive, so it can wait for the
  summary ("Your Evening Summary", "7 notifications · Shepherd"). Each entry is the catalog's title
  and body (Mission merged, Boards ready, Turn finished, Automation passed). Under Boards ready the
  board draws three board thumbnails side by side (58pt tall, sharing the width, radius 8, 6pt
  apart), from its attachments. The system draws the summary and its "3 more".

## iPad

**Not built yet.** The same catalog, anatomy and rules as the iPhone, with room to spare.

- **Actions without a long press** (NotifiPadBanner, NotifiPadCenter): "On iPad the actions sit
  right in the notification: there's room, so you don't need to long-press first." The boards draw
  them as a row of 28pt buttons (`NW.Height.controlM`, radius 6, 12.5pt, 8pt apart, 8pt under the
  body): the recommended one primary (`lantern` fill, `textOnLantern`, semibold), the other choices
  secondary (`bgRaised`, a `lineStrong` border), Reply… and Open ghost (`textSecondary`). Retry
  carries `arrow.clockwise`. Where no option is recommended (a planner question without a pick,
  NotifiPadCenter), no button is primary. **Platform limit:** iPadOS, like iOS, shows a
  notification's actions only once it is expanded, so building this as drawn needs a decision first.
- **Banner** (NotifiPadBanner): 480pt wide, centred 30pt under the top edge, over whatever is on
  screen: the board's subagent question with Replace everywhere (primary), Rename new ones, Reply…
  (not built: a subagent never asks you). The
  board's backdrop (the Missions list and a stuck lane's detail) belongs to Missions.
- **Notification Center** (NotifiPadCenter): a 520pt column, 36pt from the right edge, headed
  "Notification Center" and the app's group ("Shepherd · 9"). Rich previews show at full width:
  Boards ready ("4 boards drawn in acme-web. 2 comments resolved.") shows its thumbnails as a row of
  86pt-tall tiles sharing the width (radius 8, 8pt apart); a board still drawing is a `.nwShimmer()`
  tile on `bgSelected`. The stuck lane keeps its stack; a planner question offers its options and
  Reply…; Host offline reads "horizon is offline", "Host", "1 automation paused until it's back."
  with Retry, its only action, drawn secondary.
- **Lock Screen** (iPadLock): no Dynamic Island on iPad. Live Activities stack in a 440pt column on
  the right (36pt from the edge, 46pt down), notifications under them, and a Shepherd widget sits
  under the clock (Lock-screen widget, below).

## On the Mac today

`AgentNotifications` posts, and `AgentBanners` words, a notification for this Mac's agents and for
every connected host's (`ShepherdViewModel+Notifications.swift` decides when;
`Tests/ShepherdAppUnitTests/AgentBannersTests.swift` pins the words and the rules):

| Moment | Title | Subtitle | Body | Actions | Level |
| --- | --- | --- | --- | --- | --- |
| A turn finished | the thread | Turn finished | the first line of the agent's closing reply, its Markdown dropped ("Done. 3 files changed, tests pass."), or "Finished its turn." | Review | Passive, no sound |
| A turn failed | the thread | Turn failed | the error's first line, or "The model request failed." | Retry, Open | Active |
| The thread asks (any pi dialog: confirm, select, input, editor) | the thread | Question, or Automation question for an automation's run | the question | the dock's choices: each option (Yes and No for a confirm), and Reply… for an input or editor | Active |
| An asking tool waits and no question follows within 2s | the thread | Question | "Waiting on your answer." | none: a click opens it | Active |
| A connected host goes away (Shepherd retries it) | "*host* is offline" | Host offline | "Remote agents resume when it’s back." | Retry | Active |
| The agent's `notify` tool | the tool's title | none | the agent's name, then the tool's body | none | Active |

- **Every host's threads:** a remote thread's questions post as this Mac's do,
  and a host that drops while connected posts Host offline once (NotifMac). A remote turn's end
  posts nothing yet (see below).
- **When:** a turn's banner posts only when a turn ends (working to done); idle churn from a launch
  or a session restart posts nothing. A question posts when the thread starts asking it (the host's
  `waitingOn`, so any dialog, not only a tool named like `ask`). Nothing posts about a thread while
  you watch it, except the `notify` tool, which always posts because the agent asked.
- **Actions** (the catalog's categories, one per set of actions; macOS shows the first as the
  banner's button and the rest under **Options**): Retry retries the failed turn in place, once
  the agent is idle (Thread › Retry; a host from before that gets the prompt again); Review selects the thread and opens its Changes; Retry on a
  host reconnects at once; an option answers pi's dialog, and Reply… opens a field whose **Send** does the same with the words typed. Answering and
  retrying never bring Shepherd forward; Open and Review do. A question answered meanwhile takes
  nothing. Glyphs follow the boards: `arrow.clockwise` on Retry, `text.bubble` on Reply…,
  `chevron.right` on Open.
- **Grouped by the thing:** every banner carries its thread's `threadIdentifier` (a remote thread's
  names its host too; a host's is its own), so macOS stacks a thread's banners together.
- **Quotes:** an error, question or result is cut to its first line, at most 200 characters, ending
  in "…" when cut.
- **Replacing and removing:** a thread's turn banners replace each other, and so do its questions. A
  subagent's question posts none: it goes to its parent. A question's banner comes down once it is
  answered (anywhere: here, in the thread, or on another device), a host's once it is back, and a
  deleted thread's with it. Every `notify` is its own.
- **Clicking** brings Shepherd forward and selects the thread (see Anatomy). Banners from the
  previous run are removed at launch, because their sessions died with it.
- **Frontmost:** banners show while Shepherd is in front, for the threads you aren't watching.
- **Permission** is asked the first time Shepherd has something to post (alerts and sound), never at
  launch. Notifications are turned on and off in System Settings ▸ Notifications; Shepherd has no
  toggle of its own. Only the `notify` tool has a switch: Settings ▸ Pi's Terminals and agent tools
  (the bundled `panes` extension; "…manage automations and send notifications") carries it.
- **Not yet as the catalog says:** a remote thread's turn finishing or failing posts nothing (the
  host's state doesn't say whether a turn failed, so its end can't be worded); Automation failed and
  Automation passed post as the run's Turn failed and Turn finished; and the NotifMac items under Mac,
  below.

## Mac

NotifMac: the Mac follows the catalog with the Mac's own notification styles. Built as On the Mac
today describes: questions take a typed answer inline (Reply… with **Send**, to whoever asked),
finished work is Passive with **Review**, the first action is the banner's button and **Options**
holds the rest, banners stack by thread, and every host's threads notify here. **Not built yet:**

- **Anything that needs you is an alert,** so it stays until you act, and finished work a banner
  that leaves on its own. macOS sets alert or banner style per app, in System Settings, not per
  notification, so this needs a decision before it is built.
- **Stacks:** the board draws the rest collapsed as "2 more from Shepherd · Merge PR #24 after CI,
  Nightly migrations"; the catalog's rule (grouped by the thing, not the app) is the rule, and the
  system draws the stack.
- A stuck lane's "TIME SENSITIVE", its Retry with hint and the rest of its Options ("Replan the
  lane", "Take over in a thread", "Open mission", "Mute this mission"), and a Planner question:
  Missions are not built. Time Sensitive also needs the Time Sensitive Notifications entitlement,
  on the Mac as on iPhone.
- **Mute** from Options ("Mute this mission"), and from a thread's or mission's ••• menu (Settings,
  below).
- The board's backdrop (Missions, Designs, a Needs you section and Recents in the sidebar) is the
  Missions and Design tool boards', not the Mac's sidebar (Sidebar).

## Settings ▸ Notifications (iPhone and iPad)

**Not built yet** (NotifSettings). A screen pushed from Settings (its row is on the MobileSettings
board), titled "Notifications" with "Settings" as its back label. It is built like the rest of iOS
Settings: `SettingsSection` headers (`NWListHeader`; the board draws them 13pt semibold in
`textSecondary`, where `NWListHeader` draws the caption size in `textTertiary`) over
`NWListCard`s (`bgRaised`, a `lineSubtle` border, radius 12, `NW.Radius.l`), rows of `NWListRow`
height (48pt, or 56pt with a second line: the title at 15pt, the line under it at 12.5pt in
`textTertiary`), 14pt side padding, and `.nwSwitch` switches (30 × 18, lantern when on).

- **Send me** (a switch each; all four are on in the board):
  - Questions and approvals: "Planner and automation questions, plans, reviews"
  - Blocked work: "Stuck lanes and empty budgets. Can break through Focus."
  - Failures: "Failed turns, failed automations, hosts going offline"
  - Finished work: "Quietly, and in your Scheduled Summary"
- **Which device:**
  - Only when I'm away from my Mac (a switch): "Your Mac gets it first. This phone only after 2
    minutes idle."
  - Live Activities: its value ("On") and a chevron (the page it opens is not drawn).
- **Per mission and thread:** a row per mission, thread or automation (the board's third is an
  automation), each with its level as the value and a chevron: **Everything**, **Only blocked** or
  **Only failures** ("Checkout funnel events · Everything", "Refunds in the ledger · Only blocked",
  "Nightly migrations dry run · Only failures").
- **Footer** (12pt, `textTertiary`): "Mute anything from its ••• menu. Lock-screen previews follow
  iOS settings." So a thread's ••• menu (and a mission's) gets a Mute item, and Shepherd has no
  preview setting of its own.

On the Mac, Shepherd has no notification settings page today and no board draws one; only the
Terminals and agent tools switch (the `panes` extension) in Settings ▸ Pi governs the `notify`
tool (On the Mac today).

## Live Activities

**Not built yet** (MobileLiveLock, MobileLock, iPadLock; the Dynamic Island below). Running work
shows its progress on the Lock Screen: a thread, a thread with subagents, an automation, a mission.
A notification marks only a change that needs you, or an end (Rules).

**The card:** `bgRaised`, radius 22, padding 13 × 15, its lines 9pt apart (MobileLock's mission
card: 14 × 16 and 10pt); cards stack 8pt apart (10pt on iPad, in its 440pt column). They use Night
Watch roles and follow the device's appearance (the boards draw dark); only the island is always
dark. Sizes the iOS ramp doesn't name are set with `Font.nwSans` and `Font.nwMono` at the board's
size.

- **Header** (every card): a leading glyph, the title (14pt semibold, `textPrimary`, one line), and
  trailing meta in mono 11.5pt `textTertiary`. The glyph says what it is and how it's going: a 14pt
  spinner in `running` for a working thread, `NWBranchGlyph` (15pt) for a thread with subagents (in
  `lanternText` while one needs you), a bolt in `running` for an automation, the crook (`NWCrook`,
  15pt, in `lantern`) for a mission. The meta is the elapsed time for a thread (counting live:
  "4:12", "37m"), the host for an automation ("This Mac"), elapsed over the time budget for a
  mission ("1h38 / 4h").
- **A thread** (MobileLiveLock, iPadLock): what it's doing now (13.5pt, `textPrimary`: "Running
  tests") with the command in mono 11.5pt `textTertiary` ("swift test --filter toolPreview"); then
  its changes and where it runs (12pt, `textSecondary`: "Edited 3 files", `NWDiffStat` in mono 11pt,
  "· This Mac" in `textTertiary`); then **Steer** and **Stop**.
- **A thread with subagents** ("Restyle native UI · 3 subagents"): one row per subagent (13pt): its
  state (an 11pt spinner in `running`, the glowing 7pt `attention` dot, or a 12pt checkmark in
  `done`), its label in mono semibold (a 70pt column), then what it's doing in `textSecondary`
  ("step 1 of 3 · restyling ThreadView", "14 of 14 pass") or its question in `lanternText` ("Replace
  the old token names everywhere?"). While one asks, the buttons are its options: the first primary,
  the second secondary ("Replace everywhere", "Rename new ones").
- **An automation** ("Merge PR #24 after CI"): what it waits on (13.5pt: "Waiting for CI") with its
  progress in mono `textTertiary` ("3 of 5 checks · ~4m"); an `NWStepStrip` of 5pt segments 4pt
  apart (done, running, then pending in `lineStrong`); and what happens next (12pt, `textSecondary`:
  "Merges into main when all checks are green."). No buttons.
- **A mission** (MobileLock, iPadLock): one `NWLaneStrip` row per lane (the label in mono 11pt
  `textSecondary` in a 104pt column, a 130pt three-stop track, where it is in mono 10.5pt; the
  stuck-lane view's colors, iPhone above), 20pt rows 10pt apart (9pt on iPad). On iPhone a footer
  says what needs you and what's next (12.5pt: the glowing 7pt `attention` dot, "orders needs you"
  in `lanternText`, "· then validator, ~40m" in `textTertiary`); on iPad it has buttons instead:
  **Retry with hint** (primary) and **Open**. NWMissions names it `NWMissionLiveActivity` and
  draws it smaller (Missions: iPhone and iPad: radius 18, 12×14 padding, 8pt apart, 18pt rows,
  an 80pt label column in mono 10.5, the step in mono 10, the title at 13/600). The two boards
  disagree; settle one set of measures before building.
- **Buttons:** 34pt capsules (radius 17) sharing the card's width, 8pt apart, 13.5pt semibold.
  Secondary is `bgSelected` with `textPrimary`; Stop is `bgSelected` with `failed` text; primary is
  `lantern` with `textOnLantern`. At most one primary. **Steer** takes a message for the thread
  without opening Shepherd; **Stop** stops the turn and asks nothing (MobileIsland).

**Platform limits** to settle before building: a Live Activity can't hold a text field, so Steer
can't take text in place; a button runs an App Intent, which runs while the device is locked only if
the intent's authentication policy allows it; and an update pushed from the host can't be encrypted,
so what it carries (a command, a question's text) would cross the push relay in the clear.

## Dynamic Island

**Not built yet** (MobileIsland). Every Live Activity has three sizes. The island is always black,
so its colors don't change with the theme: text is white (the board's `#f4f5f7`) and 55% white for
secondary, buttons are 14% white, and the state colors are Night Watch's dark values (`running`,
`lantern`, `done`, `failed`). These whites are not roles yet; add them as roles before building
(Adding a theme or a role).

- **Compact** (a 36pt pill beside the camera, 12pt inside):
  - Thread: a spinner and the current command (mono 11.5pt, 55% white: "swift test"), elapsed on the
    right (mono 12.5pt semibold, `running`: "4:12").
  - Subagents: the crook and how many are running ("3", white), the board adds a lantern dot (8pt)
    and how many need you ("1", `lantern`), which Shepherd would not draw: a subagent never needs you.
  - Automation: a bolt and "CI", and on the right an 18pt ring that fills as checks pass (`running`
    over 18% white).
  - Design agent: a pen-nib glyph and the design ("Onboarding", 55% white), boards drawn so far on
    the right ("2/4").
  - Finished thread: a checkmark in `done`, "Pushed" and the branch ("main", 55% white). It stays 4
    seconds, then the activity ends.
- **Minimal** (two at once): the newer activity keeps a compact pill (a spinner and "4:12"), and the
  older shrinks to a 36pt dot; a 9pt lantern dot in it means something there needs you.
- **Expanded** (a long press; radius 40, padding 20 × 24, lines 10pt apart):
  - Thread: a spinner, the title (15pt semibold) and elapsed (mono 12.5pt, `running`); "Running
    tests" (13.5pt) with the command (mono 11.5pt, 55%); "Edited 3 files · +67 −48 · This Mac"
    (12.5pt, 55%, the counts in `done` and `failed`); then **Steer** and **Stop** (38pt capsules,
    radius 19, 14% white, 14pt semibold; Stop's text `failed`). Steer opens a text field without
    launching the app; Stop asks nothing.
  - Subagents (as the board draws it; not for Shepherd, whose subagents never ask you): the crook, "reviewer needs you" (15pt semibold) and the thread ("Restyle native UI",
    12pt, 55%); the question (13.5pt, code in mono 12pt: "Two token names collide with
    `Tokens.textSecondary`. Rename the new ones, or replace the old ones everywhere?"); its options
    as buttons, the first primary (`lantern`, `textOnLantern`: "Replace all"), then "Rename new
    ones". The board answers a subagent's question in place.
  - Design agent: the pen nib, "Onboarding flow" and "2 of 4"; the boards as 62pt tiles (radius 8,
    8pt apart), filling in as they're drawn: a drawn board's thumbnail, the one being drawn
    shimmering on 12% white with a small spinner, the rest empty at 6% white; then **Open boards**.

## Lock-screen widget (iPad)

**Not built yet** (iPadLock). A Shepherd widget under the clock: counts only, and a tap opens the
Overview. 340pt wide, radius 22, padding 16 × 18, on the system's lock-screen glass (the board's 10%
white). Its header is the crook (14pt) and "Shepherd" (13pt semibold, 72% white). Three counts sit
22pt apart, each a figure (34pt semibold) over its label (12.5pt, 72% white): "4" in `lantern` over
"need you", "6" over "running", "3" over "merged today". Its last line is the hosts: "build-01 and
This Mac online · horizon offline".

## Delivery

**Not built yet.** NotifCatalog's pipeline: the host decides and sends; a push relay carries only
IDs and one line of text through Apple's push service; the device's Notification Service Extension
fetches the rich content (attempts, lanes, thumbnails) from the host, "so code never passes through
the relay". Its payload carries the title, subtitle and body, the category, the `thread-id`, the
interruption level, a relevance score, `mutable-content`, and the host and station. The board names
a host daemon (`shepherd-d`) that Shepherd doesn't have: sessions live in the app (AGENTS.md), so
the app is what sends.

**Previews:** when these are built, each surface gets a preview render like every other: the Live
Activity cards and the island's sizes, the iPad widget, Settings ▸ Notifications, and the rich
views, in both appearances (the island in dark only).

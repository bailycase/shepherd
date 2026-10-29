# Notifications and Live Activities

> Read when you send a notification or build a Live Activity, on the Mac or iOS.

How Shepherd reaches you outside its window, on iPhone, iPad and Mac. The authority is the
Notifications page (NotifCatalog, NotifPhoneBanner, NotifPhoneStacks, NotifPhoneRich,
NotifPhoneReply, NotifPhoneReview, NotifPhoneSummary, NotifSettings, NotifiPadBanner,
NotifiPadCenter, NotifMac), MobileAnswer, and the glance boards (GlanceWatch, GlanceFollow,
GlanceIsland, GlanceLock, GlanceHome, GlanceiPad, GlanceControls).

**What is built:** the Mac's notifications, for its own agents and every connected host's
(`AgentNotifications`, worded by `AgentBanners`, posted by `ShepherdViewModel+Notifications.swift`;
On the Mac today, below); the iPhone's opt-in push alerts through the relay ([docs/ios](../ios/README.md));
and the glance surfaces, updated while the app is in front (Glance, below). On iPhone and
iPad, Home's Needs you inbox stands in: questions and blocked threads across hosts, answered in
place when short. Everything else in this section is **not built yet**, and several kinds wait on
features that don't exist either (Missions, plan approval, token budgets, Designs).

**Who draws what.** The system draws a notification: its card, its type, the app icon, the relative
time, the "TIME SENSITIVE" label, stacks, and where the actions appear. Shepherd decides the words
(title, subtitle, body), the actions and their order, the interruption level, the group
(`threadIdentifier`), what a tap opens, and any rich content (a content extension, attachments). So
the boards' notification cards are the system's, filled with Shepherd's content. A Live Activity,
the Dynamic Island and a widget are Shepherd's own drawing, in Shepherd Design. Where a board draws
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
  table exists yet: mission-specific questions, approvals, budget alerts and design notifications are not wired.

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
- **Answering never opens Shepherd** (SHMissions: the choices are actions "so answering never opens
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
in Shepherd Design from the same tokens as the app: `bgRaised` behind (radius 20, padding 14 × 16,
its blocks 12pt apart in the stuck-lane view, 10pt in the review), `textPrimary` text,
`textSecondary` for supporting lines, `textTertiary` for meta, `lineSubtle` hairlines, a 26pt app
icon (radius 6) beside the title (14pt semibold) and its meta (a mono 10pt "TIME SENSITIVE" in
`lanternText`, or the time at 12pt in `textTertiary`). Under the card, the system lists the actions
(Actions and answering).

- **Stuck lane** (NotifPhoneRich): the mission's lanes as `SHLaneStrip` rows ("A lane as a tiny
  subway line", SHMissions; not built): the lane's name (mono 11pt, `textSecondary`, a 90pt column),
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
  11.5pt, `running`) and `SHDiffStat` (mono 11pt). Actions: Approve · start train (`faceid`), Open
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
  them as a row of 28pt buttons (`SH.Height.controlM`, radius 6, 12.5pt, 8pt apart, 8pt under the
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
  86pt-tall tiles sharing the width (radius 8, 8pt apart); a board still drawing is a `.shShimmer()`
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
  mission-specific notifications are not built. Time Sensitive also needs the Time Sensitive Notifications entitlement,
  on the Mac as on iPhone.
- **Mute** from Options ("Mute this mission"), and from a thread's or mission's ••• menu (Settings,
  below).
- The board's backdrop (Missions, Designs, a Needs you section and Recents in the sidebar) is the
  Missions and Design tool boards', not the Mac's sidebar (Sidebar).

## Settings ▸ Notifications (iPhone and iPad)

**Not built yet** (NotifSettings). A screen pushed from Settings (its row is on the MobileSettings
board), titled "Notifications" with "Settings" as its back label. It is built like the rest of iOS
Settings: `SettingsSection` headers (`SHListHeader`; the board draws them 13pt semibold in
`textSecondary`, where `SHListHeader` draws the caption size in `textTertiary`) over
`SHListCard`s (`bgRaised`, a `lineSubtle` border, radius 12, `SH.Radius.l`), rows of `SHListRow`
height (48pt, or 56pt with a second line: the title at 15pt, the line under it at 12.5pt in
`textTertiary`), 14pt side padding, and `.shSwitch` switches (30 × 18, lantern when on).

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

## Glance: Live Activities and widgets

**Partial** (GlanceWatch, GlanceFollow, GlanceIsland, GlanceLock, GlanceHome, GlanceiPad,
GlanceControls; they replace MobileLiveLock, MobileLock, MobileIsland and iPadLock). Running
work shows on the Lock Screen, in the Dynamic Island, and in widgets on the Home Screen, the Lock
Screen and in Control Center. A notification still marks only a change that needs you, or an end
(Rules).

**Built:** every surface below, drawn by `SHGlance*` in ShepherdUI (`Components/Glance/`) from
one `SHGlance`. The app publishes it (`GlanceBridge`) from Home's feed while it is in front: to
the widget extension's app group (`GlanceStore`), and to the Live Activities it starts. **Not
built:** updates while the app is in the background. The phone drops its host connections there
and the push relay sends only alerts, so a surface goes stale `SHGlance.staleAfter` (5 minutes)
after the app leaves the foreground. Push updates need relay support for Live Activity pushes and
a decision on what crosses the relay (Delivery).

**The model.** `SHGlance` lists every host's threads with a state: needs you, failed, running,
done (finished today). Items rank most urgent first: needs you (oldest question first), failed
(newest first), running (longest first), done (newest first). Automation runs count as running
under the automation's name. Project threads keep their question, answered only in the app.
Subagents never ask you, so no surface carries a subagent's question. A Live Activity's content
keeps the four most urgent items and only counts the rest (`forActivity`), to stay under
ActivityKit's 4 KB.

**Stale, never frozen.** Past `staleAfter` every surface says when it last heard and which hosts
it cannot reach ("Last update 6m ago · This Mac unreachable"). A running thread then shows
"Was running" and a hollow dot instead of a spinner and a timer. Buttons become **Open**.

### Live Activities (GlanceWatch, GlanceFollow)

- **Watch:** one activity for every host, started when the app is in front and something runs
  or waits, and ended 15 minutes after nothing does. Its header counts ("3 need you · 4
  working"), with the online hosts on the right. The most urgent thread leads with its time and
  what it runs, asks or ended with; below it, up to three rows, or one under a question's
  buttons, then "+N more". Swiping it away keeps it gone until nothing runs.
- **Follow:** one thread, started from a row's long press (Follow on Lock Screen, Stop
  Following). It shows the call running now, a live timer, the subagent line ("1 running · 1
  waiting on parent · 1 done"), the goal and its state, the latest turn's diff, the queue and the
  host. It ends when the thread finishes or fails, showing the result.
- **Buttons:** 34pt capsules sharing the row, at most one primary. A question offers its first
  two options (the first in lantern) and **Reply…**; a running thread offers **Steer** and
  **Stop**; a finished one **Review**; a failed one **Open**. Answers and Stop run App Intents
  in the app over the host's own connection, or over one made for the request and closed after.
  Both need an unlocked device. Reply…, Steer, Review and Open are `shepherd://` links into the
  app.
- The card is the system's, filled `bgRaised`, padded 12 × 16; it follows the appearance.

### Dynamic Island (GlanceIsland)

Always black. Its text is `islandText` (#f4f5f7), secondary text `islandSecondary` (55% white),
buttons `islandFill` (14% white); state colors are the dark appearance's.

- **Compact:** the most urgent state's mark on the left (a still spinner arc, the crook in
  lantern, a check, a cross; a clock when stale). On the right, how many need you (a lantern dot
  and count), else how many run, or a followed thread's timer, "Done" or "Failed".
- **Minimal:** one 9pt dot in the most urgent state's color.
- **Expanded:** the state's mark and word on the left, the timer or "host · 2m" on the right,
  then the thread, what it runs or asks, and the card's buttons at 38pt.

### Widgets (GlanceHome, GlanceiPad, GlanceLock, GlanceControls)

One widget in every size, the sidebar in miniature: Needs you (lantern tags), Failed, Working
(minutes running), Done today, each group head counting. A row opens its thread.

- **Small:** the most urgent thread, or the one thread the widget shows: its state, title, the
  question, call or result, and its host.
- **Medium:** the groups, five rows shared out most urgent first.
- **Large:** a "Shepherd" header with the scope, twelve rows with Done today, and the hosts
  line ("This Mac, build-01 online · horizon offline").
- **Extra large (iPad):** a column per host; an offline host says so.
- **Lock Screen:** circular, how many need you with a ring while any do (the Lock Screen draws in
  one tint, so the ring says it), else how many run; rectangular, the counts then the top thread
  and why; inline, the counts beside the date.
- **Scope** (the widget's edit sheet): All work, a host, or one thread.
- **Empty:** "Nothing running or waiting" and the hosts line.
- **Control Center:** **New thread** opens the composer; **Needs you** shows how many wait and
  opens them.

**Departures from the boards** (the user's to settle): running rows show minutes, not a
sparkline (the phone reads no activity history); Failed offers Open, not Retry (a retry needs the
failure's checkpoint); the goal line is the goal and its state, not "step 1 of 1 · 62%" (a goal
has no steps); widget scope has no project yet; Stop asks for an unlocked device, like answers,
because the host's token is readable only then.

## Delivery

**Not built yet.** NotifCatalog's pipeline: the host decides and sends; a push relay carries only
IDs and one line of text through Apple's push service; the device's Notification Service Extension
fetches the rich content (attempts, lanes, thumbnails) from the host, "so code never passes through
the relay". Its payload carries the title, subtitle and body, the category, the `thread-id`, the
interruption level, a relevance score, `mutable-content`, and the host and station. The board names
a host daemon (`shepherd-d`) that Shepherd doesn't have: sessions live in the app (AGENTS.md), so
the app is what sends.

**Previews:** `GlancePreviewTests` renders the Live Activity cards, the island's sizes (dark in
both appearances) and the widgets in light and dark. Settings ▸ Notifications and the rich views
get theirs when they are built.
# Settings: MCP servers and Experiments

> Read when you change Settings ▸ MCP servers or Experiments.

## MCP servers (SettingsMCP, SettingsMCPAdd, SettingsMCPLocal, SettingsMCPSignIn, MCPStates)

The page (`SettingsMCP.swift` over `MCPStore`) lists the MCP servers every agent Shepherd starts
can use, kept in `~/.config/mcp/mcp.json` (the file other MCP clients share; `SHEPHERD_MCP_CONFIG`
moves it). Shepherd's own fields sit under each entry's `shepherd` key, which other tools ignore;
a secret is a `${keychain:<server>/<NAME>}` reference, and OAuth tokens live only in the Keychain.
It sits between Skills and Remote in the nav, with `server.rack`. Stage 1 serves This Mac only.

- **Header:** "MCP servers" and its explanation, with Import… (a menu: From a JSON file…, Paste
  JSON…) and the primary Add server trailing. Both disable while mcp.json doesn't parse, and the
  page says which line fails.
- **Filter:** a 240pt search field (name or endpoint) and All / Connected / Needs you with counts.
- **The list:** one card, a column head (Server, Sign-in, Tools), then a lazy stack of
  `MCPServerRow`s in the file's order: the on/off switch, a state dot (`MCPStatusDot`), the name
  in mono semibold with a Remote or Local badge, the URL or command line in mono under it (or the
  row's error in `failed`, or "Starting on This Mac…"), the Sign-in cell (an account, `$VAR`, a
  secret's name, "2 variables", a lantern Sign in, Expired or Needs … with Sign in, or None), the
  tool count, and a chevron. A row opens in place (`MCPServerDetail`): Sign-in (who, scopes, when
  refreshed, Sign in again, Sign out), Tools with their count and first names, "Through one mcp
  tool" or "Each tool on its own" with each one's token estimate, Choose which tools…, then
  Connection (transport, Start: When used / With each session / Always on, and This Mac's
  state); under a hairline, Edit…, Reconnect, Copy JSON (the entry without Shepherd's fields) and
  Remove (confirmed; it deletes the entry's Keychain items too). One server's change redraws its
  row alone (`ListPerformanceTests`).
- **The rail** (280pt): How the agent uses them over `MCPBudget` ("In every prompt ~200 tokens",
  a bar and what makes it up), Options (Same servers on every host, Open sign-in pages by itself,
  Also use a repo's .mcp.json; the second opens the sign-in sheet and the browser when an agent
  reaches a server that needs a sign-in), and Hosts with mcp.json's path and This Mac.
- **Add server** (`AddMCPServerSheet`): Remote (a URL, checked as you paste it: the server's name,
  its transport, whether it signs in with OAuth; headers; Advanced for a client ID, secret and
  scopes), Local (a command line, env vars whose secret values go to the Keychain) and Paste JSON,
  each with Start. **Import…** takes an `mcpServers` block or file, asks before replacing
  servers of the same name, and moves plaintext secrets to the Keychain.
- **Sign in** (`MCPSignInSheet`): three steps (finding the sign-in server, registering Shepherd,
  waiting in the browser) with Open browser again and Copy link; done closes by itself, a failure
  names the step and says nothing was saved. It runs OAuth 2.1 with PKCE (S256) on a one-shot
  127.0.0.1 redirect, over https only (plain http only to this Mac).

## Experiments (SettingsExperiments)

The last page of the nav, with `flask` (`SettingsExperiments.swift`, `SuggestionsModel`): features
still being tried, each off until the user turns it on. Header: "Experiments", then "Features
we're still trying out. Each is off until you turn it on." Its experiments are Suggested
instructions, the Design tool and Goals. Goals uses the same experiment card and native switch,
with its existing two-stroked-ring mark in the lantern tile, "Goals", and "Keep a conversation
working toward a condition you set with /goal. No time or token budgets. Turning this off pauses
active goals without clearing them." It has no budget fields/options and defaults off
(`AppSettings.goalsEnabled`). The switch applies live to this host's running agents. Off cancels
Checking, pauses active goals, hides goal chrome and the slash row, and rejects goal controls;
on shows the preserved Paused goal but never resumes it. Ordinary work and in-flight tools are
not aborted. The user requested this card after the supplied GoalStates board.
The Design tool's card (not drawn on the board) is the same card
with the nib in its tile, "Design tool", "Describe a page or flow and a design agent draws it as
HTML boards on a canvas you pan and zoom. Adds Designs to the sidebar and “Start a design” to New
thread.", and its switch; it has no options and no "on since" tag, and it is a preference of this
Mac (`AppSettings.designToolEnabled`). Suggested instructions lives on the host (`SuggestionsStore`, `suggestions.json` beside the
instructions): agents suggest through the instructions extension's `suggest_instruction`, which an
agent gets only while the experiment is on for its kind and names the files it may suggest for
(`SHEPHERD_SUGGEST_FILES`); remote clients read and act on it over `suggestions.v1`.

- **An experiment card:** a card with a 1px `lineStrong` line, radius `m`, on `bgWindow`.
  - The top, 14pt × 16pt padding, aligned to the top: a 36pt tile (radius `m`; the board's 9,
    `lanternTint`) holding the experiment's glyph (18pt, `lanternText`; `flask` here); the name in
    Geist 14/600 ("Suggested instructions") beside, while it is on, a small mono 10.5 tag in
    `lanternText` on `lanternTint` (18pt tall, radius `xs`) saying since when ("on since Sep 12";
    `SuggestionsPresentation.sinceTag`); under them its description in 12.5/1.5 `textSecondary`, at
    most 620pt wide: "When an agent learns something the hard way (a re-run, a failed check, a
    correction from you) it drafts one line for your root instructions. Nothing is written until you
    add it."; the switch trailing.
  - Its options, while on, under a hairline on `bgBase`: rows whose content is at least 48pt, 10pt
    in from their top and bottom (68pt, as the canvas renders them), with a 13/500 title
    over a 12/1.45 `textSecondary` note and the controls trailing, hairlines between:
    - Learn from, "Where agents may notice a lesson.": `.nwCheckbox`es 14pt apart for Threads and
      Automations (both on).
    - Can suggest for, "APPEND_SYSTEM.md overrides everything else, so it stays off unless you want
      it.": AGENTS.md (on) and APPEND_SYSTEM.md (off).
    - Hosts, "Lines go where Settings › Instructions sends them: right now that's every host." (or
      "This Mac alone." per host), with Open Instructions as a trailing `running` text action.
- **Waiting for you · 3** (a label with the count, and "Add all" trailing as a `running` text
  action once two or more wait), shown while the experiment is on: the drafted lines, newest
  first, cards 8pt apart; with none, "Nothing is waiting. When an agent learns something the hard
  way, its line shows up here." in the footnote style. A suggestion card is radius `m`, a
  `lineSubtle` line on `bgRaised`, 12pt × 14pt padding, three lines 8pt apart:
  - where it came from: a 13pt glyph for the source (an automation's `bolt`, a thread's
    `bubble.left`, `textSecondary`), its name in 12.5/600, and the source's kind and age in 12
    `textTertiary` ("automation · 2h ago", "thread · yesterday", "thread · Sep 19";
    `SuggestionsPresentation.origin`); trailing, a 24pt target chip (radius `s`, a `lineStrong`
    line, Geist 11.5) that retargets its file: a `doc.text` glyph and the file in mono
    (`AGENTS.md`), a `textTertiary` "·", a `desktopcomputer` glyph and where it goes in
    `textSecondary` ("every host", or "This Mac" per host), and a chevron. It is a menu of the two
    files.
  - the line itself as it would be added: mono 12.5/1.5 on `doneTint` (radius `s`, 6pt × 10pt
    padding), a `done` "+ " before the Markdown (its bullet in `lanternText`, code spans in
    `synString`, the rest `textPrimary`). Edit first turns it into a mono field (⏎ adds it).
  - the reason in 12/1.45 `textSecondary` ("A missing checkout_id made two services re-run their
    steps."), then 24pt buttons: Dismiss and Edit first (ghost; Cancel while editing), and "Add to
    AGENTS.md" (secondary), which names the target file.
- **How it works** (side column, 320pt): three numbered steps separated by hairlines, the number in
  an 18pt `lineStrong` ring (mono 10.5 `textSecondary`), a 12.5/1.5 sentence whose lead is
  semibold and whose rest is `textSecondary`: "An agent hits something it had to learn" a re-run,
  a red check, or you telling it no. · "It drafts one line" for a root file, with the reason. ·
  "You decide" Add it, edit it first, or dismiss it. Dismissed lines aren't suggested again.
- **Added from suggestions** (once a line was added): rows of at least 44pt, a hairline above each:
  the added line in 12.5 without its bullet over "Sep 18 · from Ledger cleanup" in 11
  `textTertiary`, and Undo as a trailing `running` text action.
- **About experiments:** a 12/1.5 `textTertiary` note, "Experiments can change or go away. Turning
  this one off keeps the lines you added and drops what's waiting.", and a small secondary Send
  feedback button with `bubble.left`, which opens a new issue for Shepherd on GitHub.
- **Rules:** nothing is written to an instruction file until the user adds a line (Add, Add all, or
  Edit first then Add); a line goes in last, as a Markdown list item; a lesson already waiting, in
  its file, or dismissed before is never suggested again (`InstructionsText.lineKey`: its words,
  whatever the case, spacing or Markdown); Undo removes an added line from its file. Adding a line
  changes This Mac's instructions, which reach every host with Same on every host on, and a draft
  open on the Instructions page keeps the line. The host keeps the newest 30 lines waiting and
  added, and 300 dismissed.

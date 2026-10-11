# Settings: Pi

> Read when you change Settings ▸ Pi (and its From pi section), Extensions, Slash commands, Sign-in or the CLIProxyAPI connection.

## Pi (SettingsPi, SettingsPiFromPi, SettingsPiExtensions)

"Shepherd's own copy of pi." One page, in this order (macOS Settings boards, revision 1083):

- **Shepherd's pi** (footnote "Shepherd runs its own copy of pi, with its own sign-ins, settings
  and conversations. The pi in your terminal is yours: Shepherd never runs it or changes its
  files."): a `PathRow`, "pi 0.87.1" (the version the app ships; "pi" alone when a Debug build's
  override brings its own), "Included with Shepherd, and updated with it. Its home:", then the
  home's folder name in mono (its path on hover) and Reveal.
- **From pi**, a second heading inside the page (Geist 17/600, `AppLayout.settingsSectionTitleSize`)
  with its own explanation: the section below, "Pi ▸ From pi".
- Native subagents and their defaults are on Settings ▸ Subagents, under the list
  ([settings-subagents](settings-subagents.md)).

## Extensions (SettingsExtensions, SettingsPiDesignReferences)

"Control the extensions included with Shepherd." (`ExtensionsSettings`, its own nav row.) The
sidebar's Extensions destination opens this page.

- **Bundled extensions** (footnote "Applies to agents launched on this Mac, including automations
  and remote agents. Running agents keep their extensions until restarted. Status and session
  tracking are always on."), switches, all on by default:
  - Terminals and agent tools, "Let agents open and drive terminals, message or spawn agents,
    manage automations and send notifications." (the stored key `shepherd.pi.extension.panes`
    and the extension's id, `panes`, keep their names)
  - Diff review tool, "Let agents open the review pane with `review_diff`."
  - MCP servers, "Let agents use the servers in Settings ▸ MCP servers, with tool search."
  - Browser tools, "Let agents open pages in their thread's Browser, read and click through them,
    and take screenshots." A design's agent never gets the tools, whatever the row says
    (docs/browser.md).
  - Design references, "Let a thread read the design pieces you hand it with `design_get`. Only a
    thread you sent one to gets the tool.", shown only while Settings ▸ Experiments ▸ Design tool
    is on (SettingsPiDesignReferences).
- **Name agents automatically** is gone: naming is always on (the user's decision, 2026-10-07).
  Agents ▸ Session naming model picks the model.

The native subagent groups below sit on [Settings ▸ Subagents](settings-subagents.md), under the
list of definitions (the user's decision, 2026-10-07).

- **Native subagent defaults** (only while Native subagents is on; footnote "Precedence: explicit
  call → agent file → these defaults → parent. Child tools run with your account's access."):
  - Concurrency, "Child process limit per parent, including workflows.": a stepper, 1–16, default 4.
  - Model, "Agent files and explicit calls override this.": Inherit parent, a divider, then pi's
    model ids; the configured model stays listed even when the catalog lacks it.
  - Thinking, no description: Inherit parent, a divider, then Off · Minimal · Low · Medium · High ·
    Xhigh · Max.
  - Context, "Start each child fresh, or fork the parent's conversation.": Fresh · Fork.
- **No Updates group** (a departure from SettingsPi, which draws Update pi daily, Update extensions
  daily and a version row with Check now and Update now): Shepherd runs its own pi, which ships
  inside the app and updates only with it, so nothing on the page runs `pi update` or checks npm
  (the "Bundled pi, isolated home" plan). Remote clients' two update switches are ignored.

## Slash commands (SettingsPiSlashCommands)

Its own nav row, after Extensions: "Commands supplied by extensions, prompt templates and skills.
Turn one off to disable it entirely, including when typed directly."
(`SettingsSection.piSlashCommands`; full available width with 40pt side gutters;
`SlashCommandsSettings`, its groups derived once per change by `SlashCommandsModel`).

- **Search commands:** a 280pt `NWSearchField` and, trailing in caption `textTertiary`, the count:
  "7 commands", "7 commands · 2 disabled", "No commands yet". The search matches a command's name or
  description ignoring a leading slash, and the count stays the whole list's.
- **Groups**, each a `SettingsGroup` card, in this order and each by name: **Extensions**,
  **Prompt templates**, **Skills** (the `skill:` commands), **Unreported commands** (a source pi
  did not say, and disabled names no pi lists now). A group with no row left by the search is not drawn.
- **A row** (`SlashCommandListRow`, at least 54pt, the Skills list's measures, a hairline above each
  but the group's first, lazy in a `LazyVStack` so 128 commands build only what is on screen):
  `/name` in Geist Mono 13 semibold `textPrimary` (`textSecondary` while off), its argument hint after
  it in mono 11.5 `textTertiary` ("[tag]"), the description under it in Geist 12.5 `textSecondary`
  on one line, and the lantern switch trailing (`SettingsSwitch`, labelled "/name" for VoiceOver).
  Off, the description line says "Disabled. Cannot be invoked until re-enabled." in `textTertiary`.
  The row's tooltip: "Turn off to disable /name in every thread, typed or picked from the / menu."
  and, off, "Disabled. /name can't be invoked until you turn it back on."
- **Empty:** with nothing listed, one card: "No commands yet. pi reports its commands when an agent
  starts, so they list here once one is running."; with a search that leaves none, "No command
  matches “<query>”."
- **No footnote**: the board draws none.
- **What a switch does:** every command is on until it is switched off (`AppSettings.hiddenSlashCommands`,
  `shepherd.pi.slashCommands.hidden`, a sorted list; Reset settings turns them all on). The server
  hears each change (`SessionServer.setHiddenSlashCommands`). The host's projection of pi's
  `get_commands` leaves the names out of every thread's snapshot, so every client's `/` menu loses
  them on its next pull. Sending one, typed or picked, is refused before pi sees it with
  "/name is disabled. Turn it back on in Settings ▸ Slash commands." (`RPCThreadState`'s command
  check, which every send, edit, steer and dispatch path runs). The host still lists the command for
  this page (`SessionServer.slashCommandCatalog`) so it can be switched back on.
- **This Mac's setting.** It is not in `HostSettings`: another client cannot switch a host's
  commands from its own Settings, because the iPhone and iPad have no page for it. The filter
  is on the host, so a remote client's menu follows the host's switches; changing them from a client
  would add a `HostSettingChange` and the page. Not built.
- **Settings ▸ Skills ▸ Skills in the / menu** is still a client-side filter for skill commands on
  this Mac's composer; a skill switched off here is gone from every client's menu either way.

## Sign-in (SettingsPiSignIn, SettingsPiSignInKeys, PiAuthStates)

"Subscriptions and API keys for agents on this Mac. They live in Shepherd’s own pi, so your
terminal pi keeps its own." The header's trailing edge holds **Re-import from pi**
(secondary, small, no glyph, as the board draws it), which copies every login again (disabled with no
pi of yours). Everything here is Shepherd's pi's alone (its home's `auth.json` and
`models.json`): nothing reads or writes the user's pi but a Re-import, which only reads it.

- **Groups**, each a `SettingsGroup` whose card holds `NWProviderRow`s (hairlines between):
  - **Subscriptions**: every provider Shepherd's pi can sign in to with an account, in this
    order: Anthropic ("Claude Pro or Max"), OpenAI Codex ("ChatGPT Plus or Pro"), GitHub Copilot
    ("Copilot Pro or Business"), xAI ("Grok subscription"), Kimi ("Kimi For Coding"), Radius
    ("pi’s model gateway") (`PiSignInCatalog.subscriptions`). The board's Google row is left out
    (departures).
  - **API keys**: each provider with a key in Shepherd's pi, then each whose variable the login
    shell sets without one ("From your environment"), by name; last, **Add an API key**, a row
    of its own (`plus` in `running`, "Add an API key" in Geist 13 `running`, then "Groq, Mistral,
    Fireworks, Together and 26 more" in caption `textTertiary`, the providers not listed yet),
    whose menu lists those providers and opens the key sheet for the one picked. Footnote
    "Pasted keys are saved in Shepherd’s pi, readable only by you. Environment variables and
    commands are read each time an agent starts."
  - **Custom providers**, only when Shepherd's pi has some: its models.json's providers, the
    file's path in mono 11 `textTertiary` trailing the group's label (`~/Library/…/pi/models.json`,
    the file Shepherd's pi reads; the board's `~/.pi/agent/models.json` is where it came from).
    The provider's id is its title, in mono 13/600.
- **`NWProviderRow`** (`ProviderRow(provider, auth)`): 12pt above and below, 16 at the sides, 12
  between parts. A 30pt monogram tile (`NWProviderBadge`: radius 8, `bgRaised` in a `lineStrong`
  line, the provider's two letters in Geist 11/600 `textSecondary`: "An", "Cx", "Gh", "xA",
  "Ki", "Ra"; a custom provider's first two letters). The name in Geist 13.5/500 over, 3pt under
  it, the status line in 12.5, one line that truncates at its end: a 7pt dot, then the state
  word, then the details, each after a "·" in `textTertiary`:

  | State (`ProviderAuth`) | Dot | Word, then | Trailing |
  | --- | --- | --- | --- |
  | signed in | `done`, filled | "Signed in" in `textPrimary` · the plan in `textSecondary` | Sign out (ghost, small) |
  | expired | `lantern`, filled | "Expired · sign in again" in `lanternText` · the plan | Sign in again (primary, small) |
  | not signed in | hollow `textTertiary` ring | "Not signed in" in `textSecondary` · the plan | Sign in (secondary, small) |
  | signing in | a `running` ring with a dot, its words shimmering | "Signing in…" in `textPrimary` · the plan | Cancel (ghost, small) |
  | key | `done`, filled | "API key" · the masked key in mono 12 `textPrimary` · its `NWKeySourceLabel` | Change key (secondary, small) |
  | from your environment | `done`, filled | "From your environment" · `$NAME` in mono 11.5 `textSecondary` · "in your login shell" in `textTertiary` | Change key |
  | no key needed | hollow ring | "No key needed" · the base URL in mono 11.5, all `textTertiary` | none |

  The plan is what the provider sells ("Claude Pro or Max"): pi keeps no account name or plan
  with a sign-in, so the row never shows an address (departures). Then the ⋯ button
  (`NWProviderMenuButton`: 26pt circle, `ellipsis` 13pt `textSecondary`, "More for Anthropic";
  while its menu is open it takes a `lineStrong` line and `bgHover`) for every row with a
  sign-in or a key. A row with a problem (a sign-out that failed) shows it inline
  (`NWInlineProblem`) under its status line.
- **Masking** (`PiKeyMask`): a key shows as its prefix (the leading letters-and-hyphens word
  groups, at most 8 characters: "sk-proj-", "sk-") and "••••" and its last 4
  ("sk-proj-••••3kQz"); a key shorter than 12 characters shows "••••" alone. Nothing else of a
  key's value is ever drawn, logged or put in a tooltip.
- **`NWKeySourceLabel`** after a key: "copied from pi" (`textTertiary`; its key is the one
  the import copied), "reads `$NAME`" (the key is a `$NAME` reference, read from the login shell
  when an agent starts), "runs a command `op read …`" (a `!command`: pi runs it when the key is
  first needed; a custom provider's command in mono 11 `textSecondary`, truncated in the middle,
  its whole text the tooltip; one in auth.json says "runs a command" alone, since such a command
  may carry a secret inline). A key pasted into Shepherd has no label.
- **`NWSharedLoginNote`**: under Anthropic, OpenAI Codex, Kimi and Radius (the providers whose
  refresh tokens rotate), whatever the row's state: an `arrow.triangle.2.circlepath` 11pt and
  "Signing in here and in your terminal pi can sign one of them out." in Geist 11.5
  `textTertiary`, 3pt under the status line.
- **The provider menu** (the native menu, `NWOptionsMenu`'s anatomy):
  - a subscription: Sign in again · Re-import from pi (with its freshness as the item's
    second line; disabled when your pi has no sign-in for it) · a divider · Sign out, in
    `failed`. Sign out removes it from Shepherd's pi only: its entry in the home's `auth.json`,
    through pi's own `logout`; the user's pi keeps theirs.
  - a key: Change key… · Re-import from pi (freshness) · a divider · Remove key, in `failed`.
  - "same as here", "newer in your pi", "changed here" (`PiFreshness`) compare Shepherd's
    copy with theirs by a digest taken at the copy (never the values).
- **The page never waits on a network**: rows come from the two files, read off the main thread
  when the page opens and again after every sign-in, sign-out or Re-import.

## Optional CLIProxyAPI connection

Settings ▸ Pi ▸ Sign-in has a CLIProxyAPI group between API keys and Custom providers.
It is off until the user connects. The existing Settings rows hold Server address and a secure
API key field, followed by Connect. A bare hostname uses HTTPS; an explicit HTTP address is
allowed for a trusted network. A root address uses `/v1`; an explicit path is kept.

Connect checks `/models` before saving. A successful connection shows the number of models and
when discovery last succeeded, with Save connection, Refresh models, Turn off and Forget.
An empty key keeps the saved key only for the same address. Discovery failures appear inline
and keep the last successful connection and catalog. Redirects are refused rather than forwarding
the key. HTTP is unencrypted, which the address row explains. Forget asks for confirmation and
removes the saved address, key and catalog. Turn off retains them without exposing models.

Shepherd owns this connection in its private pi home. Nothing installs or runs a proxy, copies
credentials from the terminal, or changes the user's `cpa` provider. Managed models use the
separate `cliproxyapi` provider. A bundled provider extension also loads in children and drafts;
it is inert without configuration. Existing agents adopt changes at an idle boundary, without
interrupting an active turn. An old selected model is not silently sent to a disabled connection.
Host setup is local to the Mac running the agents; remote model pickers use the host's catalog.

## Pi ▸ From pi (SettingsPiFromPi, SettingsPiExtensions)

A section of the Pi page, under its heading "From pi": "What Shepherd brought over from the pi in
your terminal. Shepherd keeps its own copy, so nothing here changes your pi."

- A card of two `SettingsActionRow`s, no label:
  - **Source**: "Source" over `~/.pi/agent` in mono 12.5, "The pi in your terminal, found through
    your login shell." in caption `textSecondary`; Show in Finder (secondary, small). A file of
    theirs that couldn't be read shows inline as its problem.
  - **Last brought over**: "Today at 9:41 AM, on first launch. Nothing is synced after that."
    (relative day and time of `copiedAt`); Re-import all (secondary, small), which copies every
    item below again, in order.
- **Brought over**, a group of `NWReimportRow`s (footnote "Copies. Re-import replaces
  Shepherd’s copy with your pi’s; your pi is never written to."):
  - a sub-label in the card, "Logins" (Geist 11/600 caps `textTertiary`, 16pt in, 10 above),
    then one row per provider your pi has a login for: its badge, name, and "Subscription ·
    Claude Pro or Max" or "API key · sk-••••91c2";
  - "Settings", then Custom providers ("`models.json` · northwind-gateway, ollama"), Default
    model (`claude-opus`, and "here" in `textTertiary` when Shepherd's differs, with a second line
    "Your pi now uses `gpt-5.3-codex`."), Trusted folders ("4 folders · `~/code/shepherd` and 3
    more").
  - **`NWReimportRow`**: the freshness word trailing in caption: "Same as your pi"
    (`textTertiary`), "Newer in your pi" (`lanternText`, with the why as a second line: "Your pi's
    sign-in changed on Sep 24."), "Changed here" (`textSecondary`), "Re-importing…" (shimmering),
    "Re-imported just now" (`done`); then Re-import, a quiet ghost button when the two are the
    same and a secondary one when they differ. A failure is the row's inline problem.
- **Copied** (footnote "Copied into Shepherd’s pi. Edits in your pi reach Shepherd only when you
  Re-import."): Instructions ("`~/.pi/agent/AGENTS.md` · 38 lines · no `APPEND_SYSTEM.md`"; Show
  in Finder, at Shepherd's copy: Settings ▸ Instructions edits other files, departures), Skills
  ("12 skills, listed with the rest in Skills."; Show in Finder, at Shepherd's copies), Prompts (their names as `NWTag`s in
  mono, "/review", at most six and "+3"; Show in Finder), Themes the same way when there are
  any; each with Re-import.
- **Imported extensions**, with "4 in `~/.pi/agent/extensions`" trailing (footnote "Code, so each
  one came over switched off. Shepherd's bundled extensions are on Extensions.", where
  "Extensions" is a link that opens that page):
  one **`NWExtensionRow`** each: its name in mono 13/500, its path in mono 11.5 `textTertiary`,
  its package.json description in caption `textSecondary`, the switch trailing:
  - off: nothing more;
  - on: the full-access note under it ("Runs with full access to your files, shell and network,
    like it does in your terminal. New agents load it; running ones on /reload.",
    `exclamationmark.shield` 11pt, caption `textTertiary`), no dialog;
  - failed: the switch stays on; "Didn’t load:" in `failed` and pi's reason in mono 11.5
    (`Cannot find module 'turndown' · web-search/index.ts:4`), then Try again (secondary, small)
    and Show log (ghost, small), which discloses the lines pi wrote as it failed.
  - Last, Copy again, as before: "Copies your extensions again, keeping each one's switch."
- With no pi of yours, the page is one card: "No pi found", "Shepherd found no pi of yours to
  copy. Sign in on Sign-in."

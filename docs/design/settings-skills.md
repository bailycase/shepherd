# Settings: Skills

> Read when you change Settings ▸ Skills, Browse skills.sh or Add from repo.

## Skills (SettingsSkills, SkillsStates)

The page (`SettingsSkills.swift`, `ClientSkills`) manages the agent skills each host's own pi
reads from its home, `<support>/pi/skills` (docs/skills.md): folders of instructions and scripts the agent picks up
when a task calls for them. A deferred change with an unknown result pauses its host's queue;
its error offers Resolve… on Mac and iOS. After checking the host, the user may confirm Continue
without retrying: only that missing receipt is abandoned, no mutation is replayed or undone,
and later queued changes continue. Dismissing the error alone never resolves it.
Skills are global: with Same skills on every host on, every install,
update, switch and removal goes to every host, and a host that is offline catches up when it's
back. The page sits between Instructions and Remote in the nav, with `graduationcap`.

- **Header:** "Skills", then "Instructions and scripts the agent picks up when a task calls for
  them. Installed skills are global: every thread and automation on every host gets the same set."
  (capped at
  700pt), and trailing, bottom-aligned: Add from repo… (secondary, `plus`) and Browse skills.sh
  (primary, a glass). Both open sheets (below). The blocks are 18pt apart, the list and the 280pt
  rail 28pt apart.
- **Toolbar:** a 240pt `NWSearchField` ("Filter skills", names and descriptions, and a package's name), then
  All · On · Updates with their counts ("All 8", "On 7", "Updates 2", an `NWSegmentedPicker`), a
  spacer, "Checked 2h ago" in 12 `textTertiary` (when the first host last looked for updates:
  "Checked just now", "Not checked yet"; it ages by the minute), and Update N (small secondary,
  `arrow.down.to.line`) while any skill has a newer commit.
- **The list** (a card at radius 10, `bgWindow`, a `lineSubtle` line): a 30pt header row on
  `bgSunken` with section labels (Skill, Source, Use, Updated), then groups, each under a 34pt
  title row (`SkillsGroupTitle`: 12/600 `textSecondary`, its count in mono `textTertiary`, its
  folder trailing in mono): **Installed** (the folder, "~/Library/Application
  Support/Shepherd/pi/skills"), then, from a remote host running an older Shepherd, the read-only
  groups below. Rows are at least 54pt, with 16pt column gaps and sides, hairlines between
  (`SkillsListRow`, Equatable, lazy). An Installed row:
  - the switch (a 30pt column): on or off on every host. Off moves the skill out of the folder pi
    reads, without deleting it.
  - the name in mono 13/600 (`textSecondary` while off) over its description in 12.5
    `textSecondary`, one line each; both come from SKILL.md's frontmatter.
  - Source (176pt): the repository in mono 11.5 `textSecondary`, truncating in the middle; From
    your pi with an arrow-in glyph (`textTertiary`) for a skill copied from the user's pi, its
    tooltip naming where from ("Copied from ~/.pi/agent/skills/pdf. Re-import in Settings ▸ Pi.");
    or Local with a folder glyph (`textTertiary`) for a folder copied in by hand ("It never
    updates.").
  - Use (84pt): "Auto" in a bordered 20pt tag, or "/skill only" in mono on `bgSelected`.
  - Updated (60pt): the day it last changed ("Sep 18", mono 11.5 `textTertiary`); the Update pill
    (`NWUpdatePill`, 22pt, `lanternText` on `lanternTint`) while a newer commit waits, which
    installs it; "Updating" shimmering while it goes (nothing spins).
  - a chevron: a click anywhere on the row opens its detail in place, below it, one row at a time
    (`bgHover` while open or hovered).
  - "not used" (`NWTag`) after the name when pi uses a same-named skill from the user's pi setup
    instead; its tooltip names where ("Not used: pi uses the one in ~/.pi/agent/skills.").
  - Empty: "No skills yet. Browse skills.sh, or add them from a repo.", "No skill matches “…”.",
    "No skill is on.", "Every skill is up to date.", or "Reading skills…". Filtered, an Installed
    group left empty hides while another group keeps a row.
- **The read-only groups** (the user's decision of 2026-09-26, "Show all, read-only"; departures
  above), only from a remote first host running a Shepherd from before its pi read skills only
  from its home. This Mac reports none: every skill its pi loads is Installed. Same skills on
  every host never touches them:
  - **From your pi setup:** the user's own pi's `skills/` and the `skills` paths in its
    settings, read as plain files (and what Shepherd's own pi home adds, asked of Shepherd's pi). Its title has a lock in the switch column, "~/.pi/agent/skills" and Show folder
    (small ghost; This Mac only).
  - **From pi packages:** the skills the packages in pi's settings bring, each naming its package.
  - A row (`PiSkillsListRow`, Equatable, lazy): no switch, the name in mono 13/600 over its
    description, Source (the package, or the folder holding it: "~/.pi/agent/skills",
    "~/code/team-skills"), Use as above, no Updated, no chevron. One pi passes over for a
    same-named skill that comes first reads "not used", its description replaced by "Not used:
    pi uses the one in ~/.agents/skills.". On This Mac its menu offers Open SKILL.md and Show in
    Finder.
  - Pi couldn't be asked: the group's title over the reason (`NWInlineProblem`: "Couldn’t find
    pi, so the skills from your pi setup aren’t listed.", "…node…", "This pi is too old…", "pi
    took too long…"). A remote first host too old to report them says so in the note row.
  - Last, on `bgSunken`: "A repository’s own skills (.shepherd/skills, .agents/skills) load only in
    that repository’s threads, so they aren’t listed here." (Settings is global.)
  - Skills an extension adds while pi runs aren't known without running it, so they show only
    in a thread's / menu.
- **The detail** (`SkillDetail`, on `bgSunken` under a hairline, 62pt in, 14pt apart): three
  columns 28pt apart under section labels:
  - **Use it:** two radio options (`NWRadioOption`): Automatically, "The agent reads it when a
    task calls for it. Its description sits in every prompt, about 90 tokens." (the estimate is
    the skill's own), and "Only when I type /skill:pdf", "Stays out of the agent’s prompt until
    you call it." A choice rewrites the skill's SKILL.md (`disable-model-invocation`) on every
    host; updates keep it.
  - **Version:** the repository and folder ("anthropics/skills › skills/pdf", mono 12),
    "Installed 3f2a91c · Aug 30", and while a newer commit waits "New 8c04e1d · Sep 22 · 3 files
    changed" in `lanternText` with Update (small primary) and What changed (small ghost, GitHub's
    comparison). A Local skill says "Copied into the skills folder by hand. It never updates."; one
    copied from the user's pi says "Copied from your pi (~/.pi/agent/skills/pdf). It changes only
    when you re-import skills in Settings ▸ Pi."
  - **Hosts:** a row per host (`NWHostStateRow`: a check, a filled dot while it changes there, a
    hollow one while it's away; the name in a 70pt mono column; the state): "installed",
    "updating", "not installed", "offline · updates later", "needs a newer Shepherd".
  - Under a hairline: the top of the skill's folder as chips (`NWSkillFileChip`: "SKILL.md",
    "reference.md", "scripts/ 8" with a code glyph for scripts, a folder glyph for other folders),
    then Open SKILL.md (small secondary) and Show folder (small ghost), which act on This Mac's copy
    and disable when This Mac hasn't got one, and Remove (small danger): it takes the skill off every
    host, with Undo in the toast ("Removed pdf from every host").
- **The rail** (280pt, sections 22pt apart):
  - **How the agent uses them:** "The agent sees the name and description of every automatic
    skill. When a task matches one, it reads that skill’s files and follows them. Type /skill:name
    to use one on purpose." (12.5/1.55, the command in mono `textPrimary`), then the In every prompt
    card (radius 10, `bgWindow`): "In every prompt" with "~610 tokens" (mono), a 6pt bar
    (`NWBudgetBar`) with a segment per skill the agent loads (`running` for an automatic one, a
    rule for a /skill one), and "6 automatic skills. Full files load only when used." They count
    every skill the agent loads, pi's own included, and not one pi passes over. Its tooltip: "The
    context meter counts this as part of the system prompt."
  - **Options**, rows between hairlines, each a title (13/500) over a note (12/1.45) and its
    switch: Skills in the / menu ("List every skill as /skill:name in the composer’s slash menu.";
    off, the slash menu leaves skills out), Same skills on every host ("Installs, updates and
    removals go to all hosts. Offline hosts catch up."; kept per Mac), and Update automatically
    ("Off: new versions wait here with an Update badge."; each host's own, set on every host).
  - **Hosts** with the skills folder trailing its label ("~/.agents/skills", mono), then a row per
    host: "up to date", "2 updates", "offline", "offline · catches up" while it's owed changes,
    "checking", "needs a newer Shepherd", "couldn't read"; then "Skills you copy into that folder
    by hand show up as Local."
- **States:** a change shows at once; one a host refuses springs back, its reason inline over the
  list with Dismiss. Each host checks its skills for newer commits once a day.
- **Not built yet:** per-agent skill sets (SkillsStates' Not yet). A repository's own skills are
  listed nowhere in Settings (the note above); its threads' / menu shows them.

## Browse skills.sh and Add from repo (SettingsSkillsBrowse, SettingsSkillsSearch, SettingsSkillsRepo)

Two sheets (`SkillsSheets.swift`, 1060 × 812, at least 860 × 600, `bgWindow`): a 17/600 title over
a 12.5 `textSecondary` line, the header's trailing action and a 28pt round close button (Esc);
then a list (560pt) beside the selected item's preview, a hairline between.

- **Browse skills.sh:** "The open directory of agent skills. Anything you install goes to all your
  hosts.", with Open skills.sh (small ghost). Search, ranked lists and preview files use
  `https://api.useshepherd.app` without a user API key. Browser links stay on skills.sh.
  - A 38pt search field ("Search skills, repos and owners", a glass, 14pt text, a clear button; a
    `lantern` line while focused), focused when the sheet opens.
  - Without a search: Trending · All time · Hot · Official (`NWSegmentedPicker`), a rule, then
    topics as 26pt capsules (All, React, Next.js, Design & UI, Databases, Testing, Docs & files,
    Agent workflows; the chosen one on `bgSelected`). With one: "9 skills for “postgres”" and
    Sort: Installs or Name.
  - The list: a 30pt header ("Trending · last 24 hours", "Hot · last hour", "React · Trending"; Installs) over
    rows at least 58pt (`SkillResultRow`): the place in a ranked list (mono 11.5), the name in mono
    13/600 with the search's matches in `lanternText` and skills.sh's Official seal
    (`NWOfficialSeal`), the repository in mono 11.5 `textTertiary`, and a 96pt column with the
    installs ("3.6M", mono 12) over Install (small secondary), "1 of 3 hosts" with a 64 × 3 meter
    (a segment per host: `done`, `running`, a rule) while it installs, "Installed" with a check in
    `done`, or the Update pill. The selected row is on `bgSelected`.
  - The preview: the name in mono 18/600, its repository, the seal and "131K installs"; Install
    (primary) with "Use: Automatically" (a menu: Automatically, Only with /skill), or Installed,
    or Update; View on skills.sh. While it installs, a card on `bgSunken`: "Installing · 1 of 3
    hosts" shimmering, Cancel, and each host's step ("installed · ready in new threads", "copying
    files", "offline · installs when it's back"). Then the description, the SKILL.md (a card: a
    34pt header with "SKILL.md" and "~1,900 tokens when used", its lines numbered in a 34pt column,
    mono 13 on 20pt lines with the instructions editor's highlighting, fading out at the bottom;
    240pt tall, 280pt in a search), Files as chips with what its scripts are ("3 scripts the agent
    can run: init_skill.py, package_skill.py, quick_validate.py", "No scripts. Instructions and
    references only."), and More in anthropics/skills: the list's other skills from it as capsules
    (✓ when installed) and Pick from the whole repo…, which opens Add from repo on it.
  - Loading says "Loading skills.sh…"; no match, "No skills match."; service failures show their
    reason. There is no API key field or credential prompt.
- **Add skills from a repo:** "A GitHub owner/repo or URL, or a folder on this Mac. Shepherd copies
  the skills you pick into its own pi's skills on every host."
  - A 38pt field on `bgRaised` (a branch glyph, or a folder's for a path; mono 13.5) with Look up
    (large secondary, Return), and once found "16 skills · main @ 8c04e1d" in it.
  - The picker: a 34pt bar on `bgSunken` with a checkbox for all the new ones, "3 of 13 new skills"
    and Select all new, over rows 34pt tall (`SkillPickRow`): a checkbox, the name in mono 12.5/600
    (168pt), the description, and for one already installed "Installed" (dimmed, ticked, fixed) or
    "Installed · update" (`lanternText`). A click selects a row for the preview beside: the name,
    "anthropics/skills › skills/docx", the description, its SKILL.md (340pt) and files.
  - A 60pt footer on `bgSunken`: "Use them" with Automatically · Only with /skill, where they go
    ("This Mac, build-01 now · horizon when it’s back") or the install's line while it runs, then
    Cancel and "Install 3 skills" (primary). The sheet closes once every host that could take them
    has them. A repository with one new skill installs it at once; a URL that points into a skill's
    folder ticks that skill.
  - A folder on this Mac is read here and copied to each host as its files (up to 640 KB), Local
    there. Look-up failures say why under the field ("acme/skills has no skills: no folder in it
    holds a SKILL.md.").

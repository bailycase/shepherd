# Skills

Settings ▸ Skills manages the agent skills pi reads: folders of instructions and scripts the
agent picks up when a task calls for them. Skills are global. By default every change goes to
every host, so every thread and automation on every host gets the same set. This page is the
design: where a host keeps its skills, how Shepherd installs, updates and turns them off, how
clients change them over the remote protocol, and how skills.sh fits in. DESIGN.md › Settings ›
Skills and the iPhone and iPad sections describe what the pages look like.

## What pi reads

A skill is a folder with a `SKILL.md`. pi discovers them at startup in `~/.agents/skills`,
recursively (it skips hidden folders and `node_modules`, and follows symlinks). The file's YAML
frontmatter names the skill (`name`, else the folder's name) and says what it is for
(`description`). pi lists every automatic skill's name, description and location in the system
prompt, and the agent reads the whole file when a task matches. `/skill:name` in the composer
loads one on purpose. `disable-model-invocation: true` (a YAML boolean; a quoted `"true"` is not
one) keeps a skill out of the prompt, so only `/skill:name` loads it.

Shepherd never writes into `~/.pi/agent`. `~/.agents/skills` is the folder pi and other agents
share for skills, and Settings ▸ Skills is the only thing in Shepherd that changes it.

## On a host

`SkillsStore` (ShepherdSessions) owns a host's skills:

- **The skills folder:** `~/.agents/skills`, or `SHEPHERD_SKILLS_DIR` when set (tests point it at
  a scratch folder). A skill that is on is a folder here.
- **Shepherd's state:** the support directory's `skills/`:
  - `off/`: skills that are off, moved out of pi's sight. Turning one on moves it back.
  - `removed/`: skills just removed, kept a day (`SkillsStore.keepsRemoved`) so Undo can put
    them back where they were, on or off.
  - `repos/`: a partial clone of each repository skills came from, named by a hash of its URL.
  - `staging/`: where an install assembles a skill's files before it swaps them into place.
  - `skills.json`: where each installed skill came from (repository, folder, commit and its
    date), when it was installed, the newer commit a check found, when the host last checked,
    Update automatically, and what `removed/` holds.
- **Local skills:** a folder someone copied into the skills folder by hand has no record. It shows
  as Local and never updates.
- **Read from the files:** a skill's description and how it's used come from its `SKILL.md`
  each time, so a hand edit shows at once. How it's used is written back into the frontmatter
  (`SkillsText.setting`): Only with /skill adds `disable-model-invocation: true`, Automatically
  takes it out.

Every method blocks (git talks to the network). The server calls the store on its own queue
(`SessionServer.skillsQueue`), never the server queue, and the Mac's page calls it off the main
thread (`LocalSkillsClient`). A lock makes each change whole. Fetching and exporting run under a
second lock, outside the first, so the page can still read while an install fetches.

### Installing from a repository

`SkillsGit` runs `/usr/bin/git` against the cache, never checking anything out:

1. **Fetch:** `clone --no-checkout --no-tags --filter=blob:none` the first time, then
   `fetch --prune --no-tags`. The cache holds commits and trees; file contents arrive only when a
   skill needs them. The default branch comes from `origin/HEAD`.
2. **Find the skills:** `ls-tree -r` at the commit. Every folder holding a `SKILL.md` outside
   `node_modules` is a skill (the repository's root can be one).
3. **Export:** the skill's blobs are fetched in one batch when the clone is partial, read with
   `cat-file --batch`, and written into `staging/` with their executable bits. The staged folder
   then swaps into place, so a failed install leaves the old skill whole.

An install names the folders and the commit (a look-up's newest commit, or an update's). A skill
already installed under the same name is replaced where it is, on or off, keeping how it's used
unless the install says otherwise; a new one is on and automatic unless it says. Git never asks
for anything (`GIT_TERMINAL_PROMPT=0`, a no-op askpass, `ssh -o BatchMode=yes`), and a clone or
fetch that stalls for 150 seconds fails.

Add from repo's look-up (`lookUp`) answers the repository's skills with each one's SKILL.md cut
to 16 KB for its preview, and all of them within 600 KB, under the protocol's 1 MiB frame cap.

A folder on a Mac installs as its files (`installFiles`): up to 640 KB (`SkillFile.maxTotalBytes`),
copied to every host, Local on each.

### Updates

`checkUpdates` fetches each repository installed skills came from and compares the newest commit
that touched each skill's folder (`log -1 -- <folder>`) with the installed one. A newer one is
recorded with its date and how many files changed (`diff --name-only`), and the page shows Update.
With Update automatically on, the check installs it instead. A repository that can't be reached
keeps what the last check found, and a skill its repository no longer has has nothing to update to.

The Mac app asks its store to check a minute after launch and then every hour, and the store
checks only when the last check is a day old (`checkUpdatesIfDue`, `SkillsStore.checkInterval`).
Each host checks its own skills that way; a client can ask for a check now (`checkUpdates`).

## Over the remote protocol

`skills.v1` (`RemoteRequest.skills`, `RemoteSkillsRequest`):

| Request | Does | Answers |
| --- | --- | --- |
| `fetch` | reads the host's skills | `skills(SkillsSnapshot)` |
| `lookUp(repo:)` | fetches a repository and lists its skills | `repo(RepoSkills)` |
| `install(repo:paths:commit:invocation:)` | installs skills from a repository | the skills |
| `installFiles(name:files:invocation:)` | installs a folder's files, Local | the skills |
| `setOn(name:on:)`, `setInvocation(name:invocation:)` | turns a skill on or off; how it's used | the skills |
| `remove(name:)`, `restore(name:)` | removes a skill; puts it back within a day | the skills |
| `checkUpdates` | looks for newer commits now | the skills |
| `configure(autoUpdate:)` | Update automatically | the skills |

A refusal is a `rejected` reply with the store's code and words (`no_such_skill`, `conflict`,
`not_a_repository`, `no_skills`, `no_such_path`, `invalid`, `git_failed`, `write_failed`). The
server runs each request on its skills queue and answers on the server queue. A change (anything
but `fetch` and `lookUp`) is announced to the host's own Settings page (`onSkillsChanged`), so a
change from a phone shows on the Mac at once. A client long-waits `lookUp`, `install` and
`checkUpdates` (three minutes), since they fetch.

## Clients

`ClientSkills` (ShepherdRemote) is the one model the Mac, the iPhone and the iPad draw. It reads
each host through a `SkillsClient`: a host's `RemoteHostClient`, or on the Mac its own store.

- **The list** is every host's skills by name, each as the first host that has it holds it. The
  detail says where each host is with it: installed, updating, not installed, offline, or
  offline with a change waiting.
- **Same skills on every host** (on by default, kept per device) sends each change to every host.
  Off, a change goes to the first host alone.
- **Offline hosts are owed changes.** A change for a host that isn't connected is kept, in order,
  in the device's defaults (`shepherd.skills.owed`), and sent when the host connects, before the
  page reads it again. A later change replaces an earlier one it makes moot (a second switch of the
  same skill; a removal drops the skill's owed switches; Undo cancels an owed removal).
- **A change shows at once.** The switch, how it's used and Remove change the page first; a host
  that refuses puts its own skills back, and the page says why.
- **Installs go one host at a time,** each host's step shown (waiting, copying files, installed,
  offline, or why it failed). Cancel stops before the hosts not reached yet and drops what offline
  hosts were owed. An install from skills.sh looks the skill's repository up on the first host to
  find its folder, then installs that folder everywhere at the commit the look-up saw.
- **Remove has Undo:** the page offers it until the next removal (`restore` on the hosts the
  skill came off).

The phone and the iPad follow Same skills on every host as it's kept on the device (on), and have
no switch for it.

## skills.sh

skills.sh is the open directory of agent skills. `SkillsDirectory` (ShepherdRemote) reads it over
HTTPS, as the `skills` CLI does:

- **Search** needs no key: `GET /api/search?q=&limit=` answers each skill's id (its name in its
  repository), name, repository and installs.
- **A skill's files** need no key: `GET /api/download/<owner>/<repo>/<skill>` answers every file's
  path (relative to the skill's folder) and contents, for the preview.
- **The ranked lists** (Trending, All time, Hot: `GET /api/v1/skills?view=`; Official:
  `/api/v1/skills/curated`) need an API key, sent as a bearer token. The Mac keeps one in Settings
  (`shepherd.skills.directoryKey`), and Reset settings keeps it: it's a credential, not a
  preference. Without one, Browse says so and search still works. The phone and the iPad only
  search.

Installing never downloads from skills.sh: a host installs the skill from its git repository.

## What a skill costs

`SkillsText.promptTokens` estimates what the automatic skills add to every prompt: pi's fixed
preamble and one block per skill (its name, description and location), at about four characters
a token. The Mac's page shows the total and a segment per skill that is on; a skill only /skill
loads costs nothing until it's called. Its full files cost what they hold, and only when read.

## Tests

- `SkillsStoreTests` (integration, real git): install, replace, on and off, how it's used,
  remove and restore, updates and Update automatically, against a scratch repository.
- `RemoteSkillsTests` (integration): a remote client's requests through a real listener, the
  GUI hearing each change and not reads.
- `ClientSkillsTests`, `SkillsTextTests`, `SkillsDirectoryTests` (unit): the shared model, the
  frontmatter and token rules, skills.sh's answers, and the pages' words.
- `SettingsPreviewTests.settingsSkillsInstalled`, `ListPerformanceTests` (one skill changing
  redraws only its row), and the iOS fixture screens `settings-skills`, `settings-skill`,
  `settings-skills-repo` and `settings-pad-skills`.

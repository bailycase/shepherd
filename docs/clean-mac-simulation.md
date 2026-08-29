# Simulating a "clean Mac" to test the Worktree Finalize setup wizard

Goal: make each prerequisite probed by `WorktreeSetupModel` fail on this machine, verify the
wizard's guided remedies and the re-check verification pass, then restore everything.

**This machine's reality (captured 2026-08-29):** nix-darwin managed.

| Tool | Where it lives | Consequence |
| --- | --- | --- |
| `git` | `/etc/profiles/per-user/joshhartzell/bin/git` (nix per-user profile) | Read-only nix store — cannot uninstall casually; **mask via PATH shim** |
| `gh` | `/etc/profiles/per-user/joshhartzell/bin/gh` (nix per-user profile) | Same — **mask via PATH shim** |
| CLT / Xcode | `/Applications/Xcode-26.4.0.app` selected | CLT-missing case not reachable here — VM only (Tier C) |
| git identity | `~/.gitconfig`: `Josh Hartzell` / `joshuahartzell@gmail.com` | Unset the two keys, restore after |
| gh auth | keyring, account `jhartzell` | `gh auth logout`, re-login after |

The wizard probes through `zsh -l -c`, so anything visible to a login shell is visible to the
wizard. Shims prepended in `~/.zprofile` therefore shadow the nix binaries for Shepherd *and*
for every new terminal you open while the simulation is active — plan a test window, then
restore.

> **Safe by construction:** `GitWorktree` (create/remove worktrees, unreconciled-work probe)
> calls `/usr/bin/git` by absolute path and is untouched by the shims. Only the wizard probes
> and the finalize pipeline resolve through the login shell. So you can still create the test
> worktree while "git" reads as missing in the wizard.

---

## Tier A — 5-minute reversible simulation (this machine)

Exercises 4 of the 5 failure rows and every remedy except the CLT installer.

### 1. Set up the shim directory (breaks `git installed` and `GitHub CLI` rows)

```sh
mkdir -p ~/.shepherd-clean-sim/bin
printf '#!/bin/sh\nexit 127\n' > ~/.shepherd-clean-sim/bin/git
printf '#!/bin/sh\nexit 127\n' > ~/.shepherd-clean-sim/bin/gh
chmod +x ~/.shepherd-clean-sim/bin/git ~/.shepherd-clean-sim/bin/gh
# Prepend for login shells (what the wizard uses). Marker comment for clean removal.
echo 'export PATH="$HOME/.shepherd-clean-sim/bin:$PATH" # shepherd-clean-sim' >> ~/.zprofile
```

Verify the mask works exactly the way the wizard will see it:

```sh
zsh -l -c 'git --version; echo git-exit=$?; gh --version; echo gh-exit=$?'
# expect both exits = 127
```

To break **only** gh (test rows independently): create only the `gh` stub.

### 2. Break `git identity`

```sh
git config --global --unset user.name
git config --global --unset user.email
```

### 3. Break `gh authenticated` (do this *before* step 1's gh shim, or temporarily
remove the shim — the logout needs the real gh)

```sh
gh auth logout --hostname github.com
```

### 4. Break `origin reachable` — use a scratch repo, never your real checkouts

```sh
mkdir -p ~/tmp/clean-sim-repo && cd ~/tmp/clean-sim-repo
git init -q . && git commit -q --allow-empty -m init   # no origin remote on purpose
```

Add `~/tmp/clean-sim-repo` as a Space in Shepherd (Dev build), create a worktree agent on it,
then open Finalize — the `origin reachable` row must fail with "origin remote missing or
unreachable". For the *credential-failure* variant (remote exists, auth doesn't):

```sh
git remote add origin https://github.com/jhartzell/definitely-private-nonexistent.git
```

### 5. Restart the Dev build

Login-shell environment is captured per spawned process — quit and relaunch Shepherd (Dev)
after changing shims so probes and shells see the simulated world.

---

## Test matrix — what the wizard must show

Open a worktree agent's context menu → **Finalize Worktree…** with everything broken:

| Row | Expected failure text | Remedy shown | Remedy verification |
| --- | --- | --- | --- |
| git installed | "git not found on PATH" | "install command line tools…" button | Button fires `xcode-select --install` (Apple GUI appears; cancel it — CLT is already present here) |
| git identity | "git user.name / user.email are not set" | inline name/email fields + apply | Fill both, apply → row re-probes and turns green with `name · email` |
| origin reachable | "origin remote missing or unreachable" (or the git stderr tail) | explanation text | `git remote add origin <real repo>` in the scratch repo, Re-run Checks → green |
| GitHub CLI | "GitHub CLI not installed" | `brew install gh` + copy button | Copy puts the command on the clipboard (on this machine, restore = remove shim instead) |
| gh authenticated | "not authenticated — run gh auth login" | "open login shell…" | Opens a Shepherd shell named `gh login` with `gh auth login` pre-typed; complete it (needs the shim removed so real gh resolves), come back, Re-run Checks → green |

Then the **verification pass**: with everything repaired, "Re-run Checks" must animate every
row pending → checking → green, show "✓ all set — ready to finalize", and enable **Continue**.
Continue must land on the input phase with base pre-filled from `origin/HEAD` (or `main`).

Finally run one real finalize against a scratch **GitHub** repo (create a throwaway repo,
push the scratch repo to it) and confirm: commit → push → PR URL captured → worktree gone →
local branch gone → agent retired on Done → PR visible on GitHub with the remote branch
still present.

---

## Restore (undo everything)

```sh
# 1. Remove the shims + PATH line
rm -rf ~/.shepherd-clean-sim
sed -i '' '/# shepherd-clean-sim/d' ~/.zprofile

# 2. Restore identity
git config --global user.name  'Josh Hartzell'
git config --global user.email 'joshuahartzell@gmail.com'

# 3. Re-authenticate gh
gh auth login          # account jhartzell, github.com, HTTPS

# 4. Delete the scratch repo (and its worktrees, if any leaked)
rm -rf ~/tmp/clean-sim-repo ~/tmp/clean-sim-repo-*

# 5. Verify the real world is back — the same probes the wizard runs:
zsh -l -c 'git --version && git config --get user.name && git config --get user.email \
  && gh --version | head -1 && gh auth status --hostname github.com'
```

Restart Shepherd (Dev) once more and confirm the wizard skips straight to the input phase.

---

## Tier B — fresh macOS user account (higher fidelity, ~15 min)

System Settings → Users & Groups → add a Standard user → log in as them.

What you get genuinely clean: no `~/.gitconfig` (identity fails), no gh auth, **no per-user
nix profile** — so `gh` is truly absent, exercising the real not-installed path with no shims.
`/usr/bin/git` resolves against the machine-wide Xcode/CLT install, so the git row passes —
which is also the realistic new-user state. Run the Dev build from your DerivedData path (it
is world-readable) with a per-account support dir.

Caveats: Homebrew at `/opt/homebrew` may or may not be on the new user's PATH depending on
their shell files — the `brew install gh` remedy is realistic there. Nothing in your real
account is touched; delete the account afterwards.

## Tier C — macOS VM (gold standard, exercises the CLT row)

The only way to see the "Apple's Command Line Tools are not installed" failure and honestly
test its installer button: a macOS VM with no Xcode/CLT (UTM or `tart`, macOS guest).
`/usr/bin/git` exists as Apple's stub there, `xcode-select -p` fails → the wizard's exit-2
branch fires. Everything in Tiers A/B also reproduces in the VM. This is the closest thing to
a true first-run customer machine; do one full wizard + finalize pass here before shipping
the feature.

---

## Known deltas to keep in mind while testing

- The gh remedy text says `brew install gh`; on nix-darwin machines the real fix is
  `home.packages`/`environment.systemPackages`. Acceptable for v1 (brew is the mainstream
  path); revisit if wizard telemetry ever matters.
- The CLT remedy button cannot be meaningfully verified on this machine (CLT present) — VM
  only.
- Shims leak into every login shell while active (your own terminals included). Keep the
  simulation window short and always run the Restore section.

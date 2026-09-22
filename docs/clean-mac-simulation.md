# Simulating a clean Mac for the Finalize setup checks

This procedure makes each prerequisite that `WorktreeSetupModel` probes fail on a development
Mac. You then check each failure text and remedy, run the re-check pass, and restore
everything. [worktrees.md](worktrees.md) describes the flow under test.

## How the checks see your machine

The setup probes run through `/bin/zsh -l -c`, so they see whatever a login shell sees. A shim
prepended to `PATH` in `~/.zprofile` therefore hides a tool from Shepherd. It also hides it from
every new terminal you open while the simulation is active, so keep the test window short and
always run the Restore section.

`GitWorktree` is unaffected by the shims. It creates and removes worktrees and probes for
unreconciled work, and it calls `/usr/bin/git` by absolute path. You can still create a test
worktree while "git" reads as missing in the setup checks. The finalize pipeline, the
commit-count preview, and PR descriptions all resolve through the login shell, so they *do* see
the shims.

Before you start, write down what you will need to restore:

```sh
git config --global --get user.name
git config --global --get user.email
gh auth status --hostname github.com   # which account, and how it signed in
command -v git gh                      # where the real binaries live
```

If a package manager like nix-darwin owns `git` and `gh`, you cannot uninstall them casually.
Mask them with a `PATH` shim (step 1) instead.

## Tier A: reversible simulation on this Mac (about 5 minutes)

This tier exercises four of the five rows and every remedy except the Command Line Tools
installer.

### 1. Add a git shim (breaks "Git installed")

```sh
mkdir -p ~/.shepherd-clean-sim/bin
printf '#!/bin/sh\nexit 127\n' > ~/.shepherd-clean-sim/bin/git
chmod +x ~/.shepherd-clean-sim/bin/git
# Prepend for login shells; the marker comment makes removal exact.
echo 'export PATH="$HOME/.shepherd-clean-sim/bin:$PATH" # shepherd-clean-sim' >> ~/.zprofile
zsh -l -c 'git --version; echo git-exit=$?'   # expect 127
```

While the git shim is active, "Git identity" and "Origin reachable" also fail, because they run
git. To test those rows on their own, remove the git shim and use steps 2 and 4.

A stub `gh` does **not** break the "GitHub CLI" row. The probe is
`command -v gh && gh --version | head -1`, and the pipeline's exit status is `head`'s, so a stub
that exits 127 still passes with an empty detail. It does break "GitHub CLI signed in". To see
the real not-installed failure, use Tier B, where `gh` is genuinely absent.

### 2. Break "Git identity"

```sh
git config --global --unset user.name
git config --global --unset user.email
```

### 3. Break "GitHub CLI signed in"

```sh
gh auth logout --hostname github.com
```

### 4. Break "Origin reachable" in a scratch repo (never a real checkout)

```sh
mkdir -p ~/tmp/clean-sim-repo && cd ~/tmp/clean-sim-repo
git init -q . && git commit -q --allow-empty -m init   # no origin remote on purpose
```

Add `~/tmp/clean-sim-repo` as a space in the `Shepherd (Dev)` build. Create a worktree agent on
it (New Worktree…; the base falls back to the current branch because there is no origin). Then
open Finalize Worktree….

- **Without the git shim:** the row shows the last line of `git ls-remote`'s stderr, for
  example "Please make sure you have the correct access rights and the repository exists."
- **With the shim:** stderr is empty, so the row shows "origin remote missing or unreachable".

For the credential-failure variant, where the remote exists but auth doesn't, run:

```sh
git remote add origin https://github.com/<you>/definitely-private-nonexistent.git
```

### 5. Relaunch the Dev build

Each process captures the login-shell environment when it spawns. Quit and relaunch
`Shepherd (Dev)` after changing shims, so the probes and new terminal panes see the simulated
machine.

## What the setup checks must show

Open the worktree agent's context menu and choose **Finalize Worktree…**:

| Row | Expected failure | Remedy shown | Verify the remedy |
| --- | --- | --- | --- |
| Git installed | "git not found on PATH" | "Install command line tools…" | Runs `xcode-select --install`. Apple's installer appears; cancel it if the tools are already installed |
| Git identity | "git user.name / user.email are not set" | Name and email fields, then Apply | Fill both and apply. The row re-checks and shows `name · email` |
| Origin reachable | git's last stderr line, or "origin remote missing or unreachable" | Text asking for a pushable `origin` | Run `git remote add origin <real repo>` in the scratch repo, then Re-run checks. The row passes |
| GitHub CLI | "GitHub CLI not installed" (Tier B only) | `brew install gh` with Copy | Copy puts the command on the clipboard |
| GitHub CLI signed in | "not authenticated — run gh auth login" | "Open a terminal for gh login…" | Closes the sheet and opens a terminal pane beside the agent's thread with `gh auth login` typed in. Finish the login (the real `gh` must resolve), reopen Finalize, then Re-run checks. The row passes |

Then run the verification pass. With everything repaired, "Re-run checks" moves every row
through checking to passing. It shows "All set — ready to finalize" and enables **Continue**.
Continue lands on the input phase. The PR base is pre-filled from the agent's recorded base
(`origin/` stripped); without one it falls back to `origin/HEAD`'s branch, then `main`.

Finally, run one real finalize against a throwaway GitHub repository (push the scratch repo to
it). Confirm, in order:

1. The commit is made.
2. The branch is pushed.
3. The PR URL is captured.
4. The worktree is removed.
5. The local branch is deleted.
6. The agent is retired on Done.
7. The PR is visible on GitHub, and the remote branch still exists.

## Restore

```sh
# 1. Remove the shims and the PATH line
rm -rf ~/.shepherd-clean-sim
sed -i '' '/# shepherd-clean-sim/d' ~/.zprofile

# 2. Restore your identity (the values you wrote down)
git config --global user.name  '<your name>'
git config --global user.email '<your email>'

# 3. Sign gh back in
gh auth login

# 4. Delete the scratch repo and any worktrees it leaked
rm -rf ~/tmp/clean-sim-repo ~/tmp/clean-sim-repo-*

# 5. Run the same probes the setup checks run
zsh -l -c 'git --version && git config --get user.name && git config --get user.email \
  && gh --version | head -1 && gh auth status --hostname github.com'
```

Relaunch `Shepherd (Dev)` and confirm Finalize skips straight to the input phase.

## Tier B: a fresh macOS user account (about 15 minutes)

In System Settings → Users & Groups, add a Standard user and log in as that user.

That account is genuinely clean:

- There is no `~/.gitconfig`, so "Git identity" fails.
- `gh` is not authenticated.
- If `gh` came from your own user's package profile, it is absent, which exercises the real
  "GitHub CLI not installed" path.

`/usr/bin/git` resolves against the machine-wide Xcode or Command Line Tools install, so the git
row passes, which is also what a real new user sees.

Run the Dev build from your DerivedData path (it is world-readable). Give it the account's own
support directory with `SHEPHERD_SUPPORT_DIR`. Homebrew at `/opt/homebrew` may or may not be on
the new user's `PATH`, so the `brew install gh` remedy is realistic there. Nothing in your own
account is touched. Delete the account afterwards.

## Tier C: a macOS VM (the only way to exercise the CLT row)

The "Apple's Command Line Tools are not installed" failure needs a machine without Xcode or the
Command Line Tools: a macOS guest in UTM or `tart`. There, `/usr/bin/git` is Apple's stub and
`xcode-select -p` fails, so the probe's exit-2 branch fires. Everything in Tiers A and B also
reproduces in the VM. Do one full setup-and-finalize pass here before shipping changes to this
flow.

## Known gaps

- The `gh` remedy says `brew install gh`. On a nix-managed Mac the real fix is the nix
  configuration.
- The Command Line Tools installer button can only be verified meaningfully in Tier C.
- A stub cannot fail the "GitHub CLI" row (see step 1).

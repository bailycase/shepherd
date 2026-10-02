#!/usr/bin/env python3
"""Decide what CI runs for a change: which lane, which Swift suites, how many shards.

    ci_impact.py --event pull_request --base nightly --files-from changed.txt [--labels full-ci] …

The plan job runs it and the workflow reads its outputs. A pull request into `nightly` gets the
fast lane: every unit test (they take seconds), a small smoke set, and the integration suites
the changed paths can affect, from the explicit map below. A path the map does not know, or a
change to something every test shares, runs everything. Pushes, pull requests into `master`, the
daily run and the `full-ci` label get the full lane. The summary says what ran and why.

The map is conservative: when in doubt it names more. Tests/Release/test_ci_impact.py checks
that every suite pattern matches a real suite and every path pattern a real path, so a rename
that would silently narrow a rule fails there. Standard library only.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import math
import os
import re
import sys
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ci_shards import DEFAULT_TIMES, UNKNOWN_SECONDS, read_times  # noqa: E402
from ci_testlog import types_declared_in  # noqa: E402

FULL_SHARDS = 4
# The fast lane's shards each hold about this many seconds of tests at most (a shard also
# pays a build of about five minutes, so more shards only help while the tests are longer),
# and never more than the full lane's.
FAST_SHARD_SECONDS = 200
FLAKE_HUNT_PASSES = 3

APP = r"^ShepherdAppIntegrationTests\."
SES = r"^ShepherdSessionsIntegrationTests\."
DKI = r"^DesignSurfaceKitIntegrationTests\."
PRV = r"^ShepherdPreviewTests\."
INTEGRATION_MODULES = ("ShepherdAppIntegrationTests", "ShepherdSessionsIntegrationTests",
                       "DesignSurfaceKitIntegrationTests", "ShepherdPreviewTests")

# A short end-to-end set every Swift run includes, so a regression the map does not foresee
# still has a chance to show: server start-up and mutations, the extension identity check,
# the remote listener, a thread over RPC, the app's lifecycle and composer, a terminal store.
SMOKE = [
    "ShepherdSessionsIntegrationTests.StartupTests",
    "ShepherdSessionsIntegrationTests.StateMutationTests",
    "ShepherdSessionsIntegrationTests.ExtensionIdentityTests",
    "ShepherdSessionsIntegrationTests.RemoteListenerTests",
    "ShepherdSessionsIntegrationTests.ThreadStartupTests",
    "ShepherdSessionsIntegrationTests.NativeThreadTests",
    "ShepherdAppIntegrationTests.AgentLifecycleTests",
    "ShepherdAppIntegrationTests.ExtensionIdentityFlowTests",
    "ShepherdAppIntegrationTests.NewThreadComposerTests",
    "ShepherdAppIntegrationTests.SidebarListTests",
    "ShepherdAppIntegrationTests.ThreadInputTests",
    "ShepherdAppIntegrationTests.TerminalSessionStoreTests",
    "DesignSurfaceKitIntegrationTests.DesignBoardViewTests",
]

# Areas: the integration suites that exercise one part of the app. A path in several areas
# runs the union of them.
AREAS: dict[str, list[str]] = {
    "thread": [
        APP + r"(Thread|Composer|QueueStack|QuestionDock|ProseImage|NewThread|MotionProbe|ServiceTier|ControlMotion|"
              r"ModelCatalog|ListPerformance|HiddenAgents|SubagentMotion)",
        PRV + r"ThreadPreviewTests",
    ],
    "browser": [
        APP + r"(Browser|RemoteBrowser)",
        SES + r"(Browser|MCPRelay)",
    ],
    "design": [
        APP + r"(Design|RemoteDesignFlow)",
        SES + r"(Design|RemoteDesign)",
        DKI,
        PRV + r"DesignPreviewTests",
    ],
    "review": [
        APP + r"(Review|DiffDrawing|GitDiff|GitWorktree|FinalizeWorktree|RemoteWorktree|WorktreeAgent|"
              r"WorktreeBaseOffline|CheckoutMonitor)",
        SES + r"Changes",
        PRV + r"(ChangesPreviewTests|ReviewPreviewTests)",
    ],
    "terminal": [
        APP + r"(Terminal|ShellTerminalMotion|PaneControl|PaneLayout|LoginShell|ShellIntegration)",
    ],
    "shell": [
        APP + r"(Sidebar|Workspace|ShellMotion|RightPaneMotion|PaletteMotion|SettingsMotion|Space|AgentStartup|"
              r"AgentLifecycle|AgentLaunch|AgentPeerDeletion|AgentStartProblem|IdleCost|ListPerformance|HiddenAgents|"
              r"InstructionsEditor|ServerStartupRefusal)",
        PRV + r"(PreviewTests|AgentsPreviewTests)",
    ],
    "settings": [
        APP + r"(MCP|PiSignIn|PiHomeLaunch|YourPi|SettingsReset|SettingsMotion|InstructionsEditor|ModelCatalog)",
        SES + r"(MCP|PiLauncher|PiSignIn|YourPi|Skills|Suggestions|CLIProxyAPI|RemoteSkills|RemoteInstructions|"
              r"RemoteHostSettings|StartProblem)",
        PRV + r"SettingsPreviewTests",
    ],
    "automations": [
        APP + r"(Automations|LocalAutomation|RemoteAutomations|RemoteHost|RemotePaneStream|RemoteThreadMount)",
        SES + r"(Automation|RemoteAutomation|RemoteListener|RemoteSession|RemoteControl)",
    ],
}

# Effects of a path. NONE: nothing in Swift. UNIT: the unit tier and smoke set only. FULL: everything.
NONE, UNIT, FULL = "none", "unit", "full"


def area(*names: str):
    return ("areas", names)


def module(*names: str):
    return ("module", names)


# The first rule a path matches decides it; a path no rule matches runs everything.
# `**` crosses folders, `*` does not. Rules are checked top to bottom.
RULES: list[tuple[str, object, str]] = [
    # What nobody tests in CI.
    ("docs/**", NONE, "documentation"),
    ("**/*.md", NONE, "documentation"),
    ("LICENSE", NONE, "documentation"),
    (".github/ISSUE_TEMPLATE/**", NONE, "templates"),
    (".github/pull_request_template.md", NONE, "templates"),
    (".github/workflows/ci.yml", FULL, "CI itself"),
    (".github/actions/**", FULL, "CI itself"),
    (".github/workflows/*.yml", NONE, "another workflow (Tests/Release reads the release one)"),
    ("App/iOS/**", NONE, "the iOS client (CI builds no iOS target)"),
    ("Tests/ShepherdIOSChecks/**", NONE, "the iOS client's scripts"),
    ("App/Info.plist", NONE, "the Mac app's plist (Tests/Release reads it)"),
    ("App/*.icon/**", NONE, "app icons"),
    ("App/*.entitlements", NONE, "entitlements (Tests/Release reads them)"),
    ("App/ShepherdLauncher.swift", NONE, "the Xcode app shim (SwiftPM does not build it)"),
    # Python and Node: their own jobs.
    ("Extensions/**", NONE, "canonical extensions (node tests, and the embedded-copy rule in Tests/Release)"),
    ("Tests/Extensions/native-thread-wire.json", UNIT, "a golden file the unit tier reads"),
    ("Tests/Extensions/service-tier-support.json", UNIT, "a golden file the unit tier reads"),
    ("Tests/Extensions/**", NONE, "node extension tests"),
    ("Tests/Release/**", NONE, "release rules"),
    ("scripts/ci_*.py", FULL, "the CI helpers themselves"),
    ("scripts/pi-engine-pin.json", FULL, "the pinned pi engine (everything that talks to pi)"),
    ("scripts/**", NONE, "release and engine scripts (Tests/Release)"),
    # Everything the CI and the tests share.
    (".github/**", FULL, "CI itself"),
    ("Tests/ci-suite-times.json", FULL, "the shard balance"),
    ("Package.swift", FULL, "the package"),
    ("Package.resolved", FULL, "pinned dependencies"),
    ("Shepherd.xcodeproj/**", FULL, "the Xcode project"),
    ("Vendor/**", FULL, "vendored libraries"),
    ("Tests/ShepherdTestSupport/**", FULL, "shared test support"),
    ("Tests/ShepherdTestKit/**", FULL, "shared test kit"),
    ("Tests/ShepherdTestIsolation/**", FULL, "test isolation"),
    ("Sources/ShepherdCore/**", FULL, "a shared contract (every module depends on it)"),
    ("Sources/ShepherdProtocol/**", FULL, "a shared contract (the wire format)"),
    ("Sources/ShepherdRemote/**", FULL, "a shared contract (the remote client)"),
    ("Sources/ShepherdPTYSpawn/**", FULL, "the PTY spawn code"),
    # Leaf modules: what depends on them is known from Package.swift.
    ("Sources/shepherd-cli/**", UNIT, "the CLI (only its unit tests use it)"),
    ("Sources/TerminalSurfaceKit/**", area("terminal"), "the terminal surface"),
    ("Sources/DesignSurfaceKit/**", area("design"), "the design board renderer"),
    ("Tests/Designs/**", area("design"), "design fixtures"),
    # ShepherdSessions: the files every thread and terminal goes through run everything; the
    # parts with a clear owner run their own suites.
    ("Sources/ShepherdSessions/Changes/**", area("review"), "the Changes engine"),
    ("Sources/ShepherdSessions/Design*.swift", area("design"), "design storage"),
    ("Sources/ShepherdSessions/RemoteDesigns.swift", area("design"), "remote designs"),
    ("Sources/ShepherdSessions/BrowserTunnelHost.swift", area("browser"), "the browser tunnel host"),
    ("Sources/ShepherdSessions/MCPRequest.swift", area("settings"), "MCP requests"),
    ("Sources/ShepherdSessions/Skills*.swift", area("settings"), "skills"),
    ("Sources/ShepherdSessions/Suggestions*.swift", area("settings"), "suggested instructions"),
    ("Sources/ShepherdSessions/Instructions*.swift", area("settings"), "instructions"),
    ("Sources/ShepherdSessions/YourPi*.swift", area("settings"), "importing from your pi"),
    ("Sources/ShepherdSessions/PiSignIn*.swift", area("settings"), "pi sign-in"),
    ("Sources/ShepherdSessions/CLIProxyAPI*.swift", area("settings"), "the CLIProxyAPI provider"),
    ("Sources/ShepherdSessions/AutomationRuns.swift", area("automations"), "automation runs"),
    ("Sources/ShepherdSessions/**", FULL, "server core (SessionServer, RPC, PTY, pi launch)"),
    # ShepherdUI: a component family has its area, shared tokens and controls run the whole app.
    ("Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/**", area("thread"), "thread components"),
    ("Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/**", area("thread"), "composer components"),
    ("Packages/ShepherdUI/Sources/ShepherdUI/Components/Browser/**", area("browser"), "browser components"),
    ("Packages/ShepherdUI/Sources/ShepherdUI/Components/DesignTool/**", area("design"), "design components"),
    ("Packages/ShepherdUI/Sources/ShepherdUI/Components/Review/**", area("review"), "review components"),
    ("Packages/ShepherdUI/Sources/ShepherdUI/Components/Terminal/**", area("terminal"), "terminal components"),
    ("Packages/ShepherdUI/Sources/ShepherdUI/Components/Automations/**", area("automations"), "automation components"),
    ("Packages/ShepherdUI/Sources/ShepherdUI/Components/Settings/**", area("settings"), "settings components"),
    ("Packages/ShepherdUI/Sources/ShepherdUI/Components/Skills/**", area("settings"), "skills components"),
    ("Packages/ShepherdUI/Sources/ShepherdUI/Components/PiSignIn/**", area("settings"), "sign-in components"),
    ("Packages/ShepherdUI/Sources/ShepherdUI/Previews/**", NONE, "component previews for Xcode's canvas"),
    ("Packages/ShepherdUI/**", module("ShepherdAppIntegrationTests", "ShepherdPreviewTests"),
     "shared UI (tokens, controls, containers): every app suite draws it"),
    # ShepherdApp, by feature; what no feature claims runs the app's whole integration tier
    # (the other modules' integration tests cannot depend on it).
    ("Sources/ShepherdApp/MCPExtension.swift", area("settings"), "the embedded MCP client (MCPEndToEndTests runs it)"),
    ("Sources/ShepherdApp/*Extension.swift", UNIT, "an embedded extension (the byte-identity unit test)"),
    ("Sources/ShepherdApp/Thread/**", area("thread"), "the thread and composer"),
    ("Sources/ShepherdApp/ThreadHeader.swift", area("thread"), "the thread header"),
    ("Sources/ShepherdApp/NativeThreadStores*.swift", area("thread"), "thread stores"),
    ("Sources/ShepherdApp/NewThread*.swift", area("thread"), "the New thread page"),
    ("Sources/ShepherdApp/AgentBanners.swift", area("thread"), "agent banners"),
    ("Sources/ShepherdApp/Browser*.swift", area("browser"), "the Browser"),
    ("Sources/ShepherdApp/ShepherdViewModel+Browser*.swift", area("browser"), "the Browser"),
    ("Sources/ShepherdApp/Design*.swift", area("design"), "the Design tool"),
    ("Sources/ShepherdApp/NewDesignPage.swift", area("design"), "the Design tool"),
    ("Sources/ShepherdApp/NightWatchSystem.swift", area("design"), "Night Watch as a design system"),
    ("Sources/ShepherdApp/ImplementSheet.swift", area("design"), "the Design tool"),
    ("Sources/ShepherdApp/RemoteDesigns.swift", area("design"), "remote designs"),
    ("Sources/ShepherdApp/ShepherdViewModel+Design*.swift", area("design"), "the Design tool"),
    ("Sources/ShepherdApp/DiffReview*.swift", area("review"), "review"),
    ("Sources/ShepherdApp/Changes*.swift", area("review"), "the Changes pane"),
    ("Sources/ShepherdApp/GitDiff.swift", area("review"), "diffs"),
    ("Sources/ShepherdApp/CodeHighlight.swift", area("review"), "diff highlighting"),
    ("Sources/ShepherdApp/SplitDiffWheelReader.swift", area("review"), "diffs"),
    ("Sources/ShepherdApp/ReviewCommit*.swift", area("review"), "commit from review"),
    ("Sources/ShepherdApp/ShepherdViewModel+Review*.swift", area("review"), "review"),
    ("Sources/ShepherdApp/*Worktree*.swift", area("review"), "worktrees"),
    ("Sources/ShepherdApp/ChecklistStatus.swift", area("review"), "finalize checklist"),
    ("Sources/ShepherdApp/CheckoutMonitor.swift", area("review"), "checkout monitor"),
    ("Sources/ShepherdApp/Terminal*.swift", area("terminal"), "terminals"),
    ("Sources/ShepherdApp/PaneControl.swift", area("terminal"), "terminal control"),
    ("Sources/ShepherdApp/PaneFocusMemory.swift", area("terminal"), "terminal focus"),
    ("Sources/ShepherdApp/ShellIntegration.swift", area("terminal"), "shell integration"),
    ("Sources/ShepherdApp/ShepherdViewModel+Terminal.swift", area("terminal"), "terminals"),
    ("Sources/ShepherdApp/Sidebar*.swift", area("shell"), "the sidebar"),
    ("Sources/ShepherdApp/Workspace*.swift", area("shell"), "workspace selection"),
    ("Sources/ShepherdApp/Pages/**", area("automations", "shell"), "the sidebar's pages"),
    ("Sources/ShepherdApp/Settings*.swift", area("settings"), "Settings"),
    ("Sources/ShepherdApp/MCP/**", area("settings"), "MCP servers"),
    ("Sources/ShepherdApp/Pi*.swift", area("settings"), "pi sign-in and sessions"),
    ("Sources/ShepherdApp/YourPi*.swift", area("settings"), "your pi"),
    ("Sources/ShepherdApp/Instructions*.swift", area("settings"), "instructions"),
    ("Sources/ShepherdApp/Suggestions*.swift", area("settings"), "suggested instructions"),
    ("Sources/ShepherdApp/Skills*.swift", area("settings"), "skills"),
    ("Sources/ShepherdApp/RemoteHostStore.swift", area("automations"), "remote hosts"),
    ("Sources/ShepherdApp/Remote*.swift", area("automations"), "remote hosts"),
    ("Sources/ShepherdApp/ShepherdViewModel+Automations.swift", area("automations"), "automations"),
    ("Sources/ShepherdApp/ShepherdViewModel+Remote*.swift", area("automations"), "remote actions"),
    ("Sources/ShepherdApp/**", module("ShepherdAppIntegrationTests", "ShepherdPreviewTests"),
     "the app (no feature owns this file)"),
]


@dataclass
class Plan:
    """What a run does."""

    lane: str                      # "fast" or "full"
    swift: bool
    scope: str                     # "none", "subset" or "all"
    selection: dict
    shards: int
    estimated_seconds: float
    reasons: list[str] = field(default_factory=list)
    repeat: int = 1
    shared_build: bool = False     # one job builds, the shards restore it
    save_cache: bool = False       # without one, the last shard saves its build for the next run
    report: bool = False
    clean: bool = False
    checkout_ref: str = ""

    def outputs(self) -> dict[str, str]:
        ids = [f"{i}/{self.shards}" for i in range(1, self.shards + 1)] if self.swift else ["1/1"]
        shards = [{"id": s, "slug": s.replace("/", "of"), "save": self.save_cache and i == len(ids)}
                  for i, s in enumerate(ids, 1)]
        return {
            "lane": self.lane,
            "swift": str(self.swift).lower(),
            "scope": self.scope,
            "selection": json.dumps(self.selection, separators=(",", ":")),
            "shards": json.dumps(shards, separators=(",", ":")),
            "repeat": str(self.repeat),
            "shared_build": str(self.shared_build).lower(),
            "report": str(self.report).lower(),
            "clean": str(self.clean).lower(),
            "checkout_ref": self.checkout_ref,
        }


def glob_regex(pattern: str) -> re.Pattern:
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif pattern.startswith("**", i):
            out += ".*"
            i += 2
        elif pattern[i] == "*":
            out += "[^/]*"
            i += 1
        elif pattern[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile("^" + out + "$")


_COMPILED = [(glob_regex(g), g, effect, why) for g, effect, why in RULES]


def effect_of(path: str):
    """(effect, the rule's glob, why) for one changed path; no rule means FULL."""
    for regex, glob, effect, why in _COMPILED:
        if regex.match(path):
            return effect, glob, why
    return FULL, "", "a path the impact map does not know"


def test_file_effect(path: str, root: str):
    """What a changed file under Tests/<target>/ runs, or None when it is not in a test target.

    A unit target's file runs the unit tier (which always runs). An integration or preview
    test file runs the suites it declares; a helper that declares none, and a fixture, run the
    whole target.
    """
    parts = path.split("/")
    if len(parts) < 3 or parts[0] != "Tests":
        return None
    target = parts[1]
    if target.endswith("UnitTests"):
        return UNIT, "a unit test target (the unit tier always runs)"
    if target not in INTEGRATION_MODULES:
        return None
    if not path.endswith(".swift"):
        return module(target), "a fixture (its whole target runs)"
    full = os.path.join(root, path)
    if not os.path.exists(full):
        return UNIT, "a deleted test file (the build proves the rest)"
    suites = sorted(f"{target}.{t}" for t in types_declared_in(full)
                    if re.search(r"(Tests?|Report|Check|Benchmarks)$", t))
    if suites:
        return ("suites", suites), "the suites this test file declares"
    return module(target), "a test helper (its whole target runs)"


def describe(effect) -> str:
    if isinstance(effect, str):
        return {NONE: "no Swift tests", UNIT: "unit tests and smoke", FULL: "everything"}[effect]
    kind, names = effect
    if kind == "areas":
        return "the " + " and ".join(names) + " suites"
    if kind == "module":
        return "all of " + ", ".join(names)
    return ", ".join(n.split(".", 1)[1] for n in names)


def merge_selection(selection: dict, effect) -> None:
    kind = effect[0]
    if kind == "areas":
        for name in effect[1]:
            for regex in AREAS[name]:
                if regex not in selection["regexes"]:
                    selection["regexes"].append(regex)
    elif kind == "module":
        for name in effect[1]:
            regex = f"^{re.escape(name)}\\."
            if regex not in selection["regexes"]:
                selection["regexes"].append(regex)
    elif kind == "suites":
        for sid in effect[1]:
            if sid not in selection["suites"]:
                selection["suites"].append(sid)


def estimate(selection: dict, times: dict[str, float]) -> float:
    """Seconds of tests the selection holds, by the times file (suites it has not seen cost the default)."""
    if selection.get("all"):
        return sum(times.values())
    patterns = [re.compile(r) for r in selection["regexes"]]
    exact = set(selection["smoke"]) | set(selection["suites"])
    total = 0.0
    for suite, seconds in times.items():
        if suite in exact or any(p.search(suite) for p in patterns) or (
                selection["unit"] and suite.split(".", 1)[0].endswith("UnitTests")):
            total += seconds
    return total + UNKNOWN_SECONDS * len([s for s in exact if s not in times])


def fast_shards(seconds: float) -> int:
    return max(1, min(FULL_SHARDS, math.ceil(seconds / FAST_SHARD_SECONDS)))


def full_plan(lane_reason: str, **extra) -> Plan:
    plan = Plan("full", True, "all", {"all": True}, FULL_SHARDS, 0.0, [lane_reason], **extra)
    return plan


def plan_for(
    *,
    event: str,
    base_ref: str = "",
    ref: str = "",
    labels: tuple[str, ...] = (),
    dispatch_lane: str = "auto",
    files: list[str] | None = None,
    root: str = ".",
    times: dict[str, float] | None = None,
    clean: bool = False,
    clean_due: bool = False,
    shared_build: bool | None = None,
) -> Plan:
    """The plan for one workflow run.

    A full run outside a pull request builds incrementally on the last build, in every shard,
    and its last shard saves the build for the next run; measured, that beats a build job the
    shards wait for by over a minute. The first run of each UTC day (`clean_due`), a `clean` run
    and the daily run build from scratch, once, in a job of their own that every shard restores.
    """
    times = times or {}
    on_branch = ref in ("refs/heads/nightly", "refs/heads/master")
    if event == "schedule":
        plan = full_plan("the daily run: the full lane, three passes to find flaky tests", repeat=FLAKE_HUNT_PASSES)
        plan.shared_build, plan.report, plan.clean, plan.checkout_ref = True, True, True, "nightly"
        plan.estimated_seconds = sum(times.values())
        return plan
    forced = ""
    if event == "pull_request":
        if base_ref == "master":
            forced = "a pull request into master runs the full lane"
        elif "full-ci" in labels:
            forced = "the full-ci label asks for the full lane"
    elif event == "workflow_dispatch":
        if dispatch_lane == "flake-hunt":
            plan = full_plan("a manual flake hunt: the full lane, three passes", repeat=FLAKE_HUNT_PASSES)
            plan.clean = clean or clean_due
            plan.shared_build = plan.clean if shared_build is None else shared_build
            plan.save_cache, plan.report = not plan.shared_build, on_branch
            plan.estimated_seconds = sum(times.values())
            return plan
        if dispatch_lane in ("auto", "full") or files is None:
            forced = "a manual run takes the full lane"
    else:  # push
        forced = f"a push to {ref.removeprefix('refs/heads/')} runs the full lane"
    if forced:
        plan = full_plan(forced)
        plan.estimated_seconds = sum(times.values())
        outside_pr = event != "pull_request"
        plan.clean = outside_pr and (clean or clean_due)
        plan.shared_build = outside_pr and (plan.clean if shared_build is None else shared_build)
        plan.save_cache = outside_pr and not plan.shared_build
        plan.report = event in ("push", "workflow_dispatch") and on_branch
        return plan

    # The fast lane.
    selection = {"all": False, "unit": True, "regexes": [], "smoke": list(SMOKE), "suites": []}
    reasons: list[str] = []
    swift = False
    run_everything = ""
    for path in files or []:
        effect, glob, why = effect_of(path)
        if not glob:
            found = test_file_effect(path, root)
            if found is not None:
                effect, why = found
        reasons.append(f"`{path}`: {describe(effect)} ({why})")
        if effect == NONE:
            continue
        swift = True
        if effect == FULL:
            run_everything = run_everything or f"`{path}` is {why}"
        elif effect != UNIT:
            merge_selection(selection, effect)
    if not swift:
        return Plan("fast", False, "none", selection, 0, 0.0, reasons or ["no files changed"])
    if run_everything:
        plan = full_plan(f"{run_everything}: everything runs")
        plan.reasons += reasons
        plan.estimated_seconds = sum(times.values())
        return plan
    seconds = estimate(selection, times)
    return Plan("fast", True, "subset", selection, fast_shards(seconds), seconds, reasons)


def summary(plan: Plan, times: dict[str, float]) -> str:
    lines = [f"### CI plan: {plan.lane} lane"]
    if not plan.swift:
        lines.append("No Swift tests: nothing this change touches is built or run by them. "
                     "The extension tests and release rules still run.")
    elif plan.scope == "all":
        lines.append(f"**Everything runs**, in {plan.shards} shards, about {plan.estimated_seconds:.0f} s of tests "
                     f"in all (build and retries not included).")
    else:
        lines.append(f"**A subset runs**, in {plan.shards} shard{'s' if plan.shards != 1 else ''}: every unit test, "
                     f"{len(plan.selection['smoke'])} smoke suites and the suites below, about "
                     f"{plan.estimated_seconds:.0f} s of tests. Add the `full-ci` label to the pull request to run everything.")
    if plan.repeat > 1:
        lines.append(f"Each shard runs its tests {plan.repeat} times; a test that fails some passes and passes others is flaky.")
    if plan.reasons:
        lines += ["", "<details><summary>Why (one line per changed path)</summary>", ""]
        lines += [f"- {r}" for r in plan.reasons[:200]]
        if len(plan.reasons) > 200:
            lines.append(f"- … and {len(plan.reasons) - 200} more")
        lines += ["", "</details>"]
    if plan.scope == "subset":
        lines += ["", "Suite patterns: " + (", ".join(f"`{r}`" for r in plan.selection["regexes"]) or "none (unit and smoke only)")]
        if plan.selection["suites"]:
            lines.append("Test files' suites: " + ", ".join(f"`{s}`" for s in plan.selection["suites"]))
    return "\n".join(lines) + "\n"


def changed_files(path: str) -> list[str]:
    with open(path, encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip()]


def write_outputs(plan: Plan) -> None:
    out = os.environ.get("GITHUB_OUTPUT")
    pairs = plan.outputs()
    if out:
        with open(out, "a", encoding="utf-8") as f:
            for key, value in pairs.items():
                f.write(f"{key}={value}\n")
    else:
        for key, value in pairs.items():
            print(f"{key}={value}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--event", required=True)
    parser.add_argument("--base", default="", help="the pull request's base branch")
    parser.add_argument("--ref", default="", help="GITHUB_REF")
    parser.add_argument("--labels", default="", help="comma-separated pull request labels")
    parser.add_argument("--lane", default="auto", help="workflow_dispatch's lane: auto, fast, full or flake-hunt")
    parser.add_argument("--files-from", help="a file with one changed path per line; omit for a full run")
    parser.add_argument("--times", default=DEFAULT_TIMES)
    parser.add_argument("--root", default=".")
    parser.add_argument("--clean", action="store_true")
    parser.add_argument("--clean-due", action="store_true", help="no clean build has been made today (UTC)")
    parser.add_argument("--shared-build", choices=("true", "false", ""), default="")
    parser.add_argument("--report", action="store_true", help="file the tracking issue even off nightly and master")
    args = parser.parse_args(argv)
    times = read_times(args.times)
    plan = plan_for(
        event=args.event, base_ref=args.base, ref=args.ref,
        labels=tuple(x for x in args.labels.split(",") if x), dispatch_lane=args.lane,
        files=changed_files(args.files_from) if args.files_from else None,
        root=args.root, times=times, clean=args.clean, clean_due=args.clean_due,
        shared_build=None if not args.shared_build else args.shared_build == "true",
    )
    if args.report and plan.lane == "full":
        plan.report = True
    text = summary(plan, times)
    print(text)
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target:
        with open(target, "a", encoding="utf-8") as f:
            f.write(text)
    write_outputs(plan)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

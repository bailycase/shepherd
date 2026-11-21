#!/usr/bin/env python3
"""Run a named local Shepherd check and keep its evidence in .build/validation/."""

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
LOG = "mac/run.log"
TOOLBAR = "the narrow toolbar in Sources/ShepherdApp/DiffReviewView.swift"
SCROLL_CASE = "scroll-stability"
SCROLL_SCENARIOS = {
    "slow-scroll-streaming": ("fixture.stickyChunk", "fixture.streamChunk", "fixture.scrollInput"),
    "flick-and-stop": ("fixture.scrollInput", "fixture.phase.interacting", "fixture.phase.decelerating", "fixture.phase.idle"),
    "mid-history-new-turn": ("fixture.newTurn", "fixture.scrollInput"),
    "page-older-history": ("fixture.scrollInput", "fixture.pageRequested", "fixture.pageReply"),
    "window-resize": ("fixture.windowResize",),
    "switch-away-back": ("fixture.switchAway", "fixture.switchBack"),
}
SCROLL_EXPECTED_WRITERS = {
    "slow-scroll-streaming": {"L7"},
    "page-older-history": {"M5", "M6", "L6"},
    "window-resize": {"L4", "L12"},
    "switch-away-back": {"L14"},
}
SCROLL_COMPLETION = "six Dev scroll scenarios finished"


@dataclass(frozen=True)
class Case:
    test: str
    steps: set[tuple[str, str | None]]
    completion: str
    scope: str
    appearances: str = ""
    golden: str | None = None
    scenario: str | None = None


CASES = {
    SCROLL_CASE: Case("Shepherd (Dev) / ThreadScrollValidation", {(scenario, None) for scenario in SCROLL_SCENARIOS},
                      SCROLL_COMPLETION, "offscreen Dev app", scenario="Sources/ShepherdApp/Thread/ThreadView.swift"),
    "changes-review": Case(
        "ReviewFlowTests/opensCommitSheetWithoutChangingGit",
        {(step, appearance)
         for step in ("load-changes", "open-commit-sheet", "commit-sheet-files", "close-commit-sheet", "git-unchanged")
         for appearance in ("light", "dark")},
        "light and dark scenarios finished", "narrow", ", light and dark",
        scenario="Tests/ShepherdAppIntegrationTests/ReviewFlowTests.swift",
    ),
    "seeded-thread-rename": Case(
        "ThreadRenameTests/seededThreadRenameSurvivesHostRestart",
        {("compare-golden", None)}, "rename, restart and sidebar matched the golden", "local host",
        golden="Tests/Fixtures/seeded-thread-rename.json",
        scenario="Tests/ShepherdAppIntegrationTests/ThreadRenameTests.swift",
    ),
    "c-state": Case(
        "StateStoreTests/historicalFilesLoadAndRewriteAsRecorded",
        {("compare-golden", None)}, "persisted file shapes matched the golden", "scratch files",
        golden="Tests/Fixtures/c-state.json",
        scenario="Tests/ShepherdSessionsUnitTests/StateStoreTests+Golden.swift",
    ),
    "c-auth": Case(
        "RefusalCorpusTests/refusalCorpusMatchesGolden",
        {("compare-golden", None)}, "refusal corpus matched the golden", "host sockets",
        golden="Tests/Fixtures/c-auth.json",
        scenario="Tests/ShepherdAppIntegrationTests/RefusalCorpusTests.swift",
    ),
    "c-settings": Case(
        "SettingsWritePathTests/everySettingsWritePathMatchesTheGolden",
        {("compare-golden", None)}, "every settings write path matched the golden", "local host",
        golden="Tests/Fixtures/settings-write-paths.json",
        scenario="Tests/ShepherdAppIntegrationTests/SettingsWritePathTests.swift",
    ),
    "c-wire": Case(
        "WireRequestSequenceTests/wireMatchesGolden|WireCodecTests/wireMatchesGolden",
        {("codec-golden", None), ("compare-golden", None)}, "scratch-host request sequences matched the golden", "wire",
        golden="Tests/Fixtures/c-wire.json",
    ),
}


def source_identity():
    def git(*args):
        return subprocess.check_output(["git", "--no-optional-locks", *args], cwd=ROOT, stderr=subprocess.STDOUT)

    revision = git("rev-parse", "HEAD").decode().strip()
    changes = git("status", "--porcelain=v1", "--untracked-files=all")
    dirty = hashlib.sha256(changes)
    dirty.update(git("diff", "--binary", "--no-ext-diff", "--no-textconv", "HEAD"))
    for name in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0"):
        if not name:
            continue
        path = ROOT / os.fsdecode(name)
        content = hashlib.sha256()
        if path.is_symlink():
            content.update(os.fsencode(os.readlink(path)))
        elif path.is_file():
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(65536), b""):
                    content.update(chunk)
        dirty.update(content.digest())
    return {"revision": revision, "dirty_paths": changes.decode(errors="replace").splitlines(),
            "dirty_sha256": dirty.hexdigest() if changes else None}


def read_steps(run, required_steps):
    records, problems = {}, []
    for path in sorted((run / "mac/steps").glob("*.json")):
        try:
            step = json.loads(path.read_text(encoding="utf-8"))
            name, appearance = step["step"], step.get("appearance")
            if ((name, appearance) not in required_steps or step["status"] not in ("passed", "failed")
                    or (name, appearance) in records
                    or not all(isinstance(step[key], str) and step[key] for key in ("expected", "actual"))
                    or not isinstance(step["evidence"], list)
                    or not all(isinstance(p, str) and p.startswith("mac/") and ".." not in Path(p).parts
                               and (run / p).is_file() for p in step["evidence"])):
                raise ValueError("invalid or duplicate step record")
            records[name, appearance] = step
        except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
            problems.append(f"{path.name}: {error}")
    return records, problems


def log_diagnostic(path):
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    errors = [line.strip() for line in lines if "error:" in line.lower() or "issue" in line.lower()]
    return "\n".join(errors[-5:] or lines[-5:]) or "swift test produced no output"


def native_scroll_path(event):
    stack = event.get("stack", [])
    # Skip the bounds notification itself and name the code driving the write.
    start = next((i for i, line in enumerate(stack) if " _postBoundsChangeNotification]" in line), -1)
    stack = stack[start + 1:]
    for symbol, label in (
        (" _reflectDocumentViewFrameChange]", "AppKit.NSClipView._reflectDocumentViewFrameChange"),
        ("HostingScrollViewC13updateContext", "SwiftUI.HostingScrollView.updateContext"),
    ):
        if any(symbol in line for line in stack):
            return label
    if event.get("detail") == "fixture.clip.scroll":
        return "fixture.clip.scroll"
    for line in stack:
        fields = line.split(maxsplit=3)
        if len(fields) == 4 and fields[1] == "AppKit":
            return f"AppKit {fields[3].rsplit(' + ', 1)[0]}"
    return "NSClipView.bounds (native caller unavailable)"


def scroll_paths(previous, frame, events):
    writes = [event["caller"] for _, event in events
              if event["caller"].startswith("Thread") or event.get("kind") == "write"]
    native = [native_scroll_path(event) for _, event in events if event["caller"] == "NSClipView.bounds"]
    if not native:
        native = ["SwiftUI row layout (clip offset unchanged)" if frame.get("offset") == previous.get("offset")
                  else "unattributed clip offset change"]
    # A requested write isn't necessarily the cause of the native change. Keep both.
    return list(dict.fromkeys(writes + native))


def check_scroll_actions(name, frames, required):
    if (len(frames) < 2 or any(a["timestamp"] >= b["timestamp"] for a, b in zip(frames, frames[1:]))
            or any(f["refreshInterval"] <= 0 for f in frames)):
        raise ValueError(f"{name}: missing or unordered display frames")
    if not frames[0].get("first") or frames[0]["hidden"]:
        raise ValueError(f"{name}: no initial visible row")

    actions = [(i, event["caller"]) for i, frame in enumerate(frames) for event in frame["events"]
               if event["caller"] in required]
    callers = {caller for _, caller in actions}
    if missing := set(required) - callers:
        raise ValueError(f"{name}: missing actions {sorted(missing)}")
    if "fixture.scrollInput" in required and not any(
            e["scrollDelta"] for f in frames for e in f["events"] if e["caller"] == "fixture.scrollInput"):
        raise ValueError(f"{name}: no scripted clip movement")
    # Require a sampled baseline and a wall-clock settle after the last action, not one quiet frame.
    if actions[0][0] == 0 or frames[-1]["timestamp"] - frames[actions[-1][0]]["timestamp"] < 0.75:
        raise ValueError(f"{name}: missing pre-action or settle samples")
    if name == "switch-away-back":
        away = next(i for i, caller in actions if caller == "fixture.switchAway")
        back = next(i for i, caller in actions if caller == "fixture.switchBack")
        if not any(f["hidden"] for f in frames[away:back]) or frames[-1]["hidden"]:
            raise ValueError(f"{name}: deck did not hide and reveal the thread")

    geometry_actions = {
        "fixture.stickyChunk": ("documentHeight", 1), "fixture.streamChunk": ("documentHeight", 16),
        "fixture.newTurn": ("documentHeight", 1), "fixture.pageReply": ("documentHeight", 1),
        "fixture.windowResize": ("clipSize", 3),
    }
    first_chunk = next((i for i, caller in actions if caller == "fixture.streamChunk"), None)
    if first_chunk is not None and frames[first_chunk - 1]["following"]:
        raise ValueError(f"{name}: first streaming chunk did not start detached")

    for caller in set(required) & geometry_actions.keys():
        key, count = geometry_actions[caller]
        if sum(action == caller for _, action in actions) != count:
            raise ValueError(f"{name}: expected {count} {caller} actions")
        for j, (i, action) in enumerate(actions):
            if action != caller:
                continue
            before = frames[i - 1]
            stop = actions[j + 1][0] if j + 1 < len(actions) else len(frames)
            samples = frames[i:stop]
            if caller in ("fixture.stickyChunk", "fixture.streamChunk"):
                if caller == "fixture.stickyChunk" and not before["following"]:
                    raise ValueError(f"{name}: sticky control did not start following")
                height = before["streamingRowHeight"]
                changed = any(frame[key] != before[key] and frame.get("streamingRowHeight", 0) > height
                              for frame in samples)
            else:
                changed = any(frame[key] != before[key] for frame in samples)
            if not changed:
                raise ValueError(f"{name}: {caller} did not change {key}")


def measure_scroll(frames):
    jumps, drift, anchor_losses, sticky_follows, in_band_inputs = [], [], [], [], []
    previous = frames[0]
    anchor = previous["first"]
    baseline = previous["rows"][anchor]
    pending, lost, excursion = [], None, None
    compared, settled_frames = 0, 0
    streaming = False
    for i, frame in enumerate(frames[1:], 1):
        pending.extend((i, event) for event in frame["events"])
        if frame["hidden"]:
            continue  # Compare with the last visible frame when the same thread returns.
        inputs = [e["scrollDelta"] for _, e in pending if e["caller"] == "fixture.scrollInput"]
        scripted_delta = sum(inputs)
        streaming |= any(e["caller"] in ("fixture.stickyChunk", "fixture.streamChunk") for _, e in pending)

        row = previous["first"] if inputs else anchor
        observation = {"frame": i, "row": row, "scripted_clip_delta_pt": scripted_delta,
                       "first_after": frame.get("first"), "paths": scroll_paths(previous, frame, pending),
                       "following_before": previous["following"], "following": frame["following"],
                       "distance_before": previous["distance"], "distance": frame["distance"],
                       "events": pending.copy()}
        if frame.get("first") and row in frame["rows"]:
            delta = frame["rows"][row] - previous["rows"][row] + scripted_delta
            measured = "row"
        elif frame.get("first") and inputs:
            # Large scripted moves can evict the old row. Still check the clip for extra motion.
            delta = previous["offset"] - frame["offset"] + scripted_delta
            measured = "clip offset"
        else:
            # Keep the original anchor across a transient swap. Its return is not a second loss.
            if lost is None:
                lost = {**observation, "row": anchor}
                anchor_losses.append(lost)
            settled_frames = 0
            continue
        if lost is not None:
            if anchor in frame["rows"]:
                lost["restored_frame"] = i
                lost["restore_paths"] = scroll_paths(previous, frame, pending)
            lost = None
        compared += 1
        settled_frames = settled_frames + 1 if not inputs else 0
        growth = frame.get("streamingRowHeight", 0) - previous.get("streamingRowHeight", 0)
        observation.update(delta_pt=round(delta, 3), measured=measured)
        # NativeScrollFollower.threshold is 80 pt. A detached reader reattaching is not expected follow.
        sticky_in_band = streaming and previous["following"] and frame["following"] and previous["distance"] <= 80
        if (sticky_in_band and not inputs and frame["documentHeight"] != previous["documentHeight"]
                and growth > 2 and abs(delta + growth) <= 2):
            sticky_follows.append(observation)
            baseline -= growth
        elif abs(delta) > 2:
            # Only separate an upward-input residual that matches a return from inside the band to the tail.
            if (sticky_in_band and scripted_delta < 0 and previous["distance"] >= 0 and abs(frame["distance"]) <= 2
                    and abs(delta - (scripted_delta - previous["distance"] - growth)) <= 2):
                in_band_inputs.append(observation)
            else:
                jumps.append(observation)

        if inputs:
            anchor, excursion = frame["first"], None
            baseline = frame["rows"][anchor]
        elif anchor in frame["rows"]:
            displacement = frame["rows"][anchor] - baseline
            if abs(displacement) <= 2:
                excursion = None
            elif excursion is None:
                excursion = {**observation, "row": anchor, "delta_pt": round(displacement, 3)}
                drift.append(excursion)
            elif abs(displacement) > abs(excursion["delta_pt"]):
                excursion["delta_pt"] = round(displacement, 3)
        previous, pending = frame, []

    if lost is not None:
        # An anchor that never returns can hide a jump. Report it without guessing the displacement.
        jumps.append({**lost, "delta_pt": None, "measured": "unrestored anchor loss"})
    return {"frames": len(frames), "compared_frames": compared, "final_comparable_frames": settled_frames,
            "jumps": jumps, "drift": drift, "anchor_losses": anchor_losses, "sticky_follows": sticky_follows,
            "in_band_inputs": in_band_inputs}


def scroll_ledger(frames, summary=None):
    """Capture-only. Never use this ledger to grade the existing stability case."""
    from collections import Counter
    from itertools import combinations
    from statistics import median

    entries = [[event for event in frame["events"] if event["caller"].startswith("thread.write.")
                and event.get("kind") != "fixture"] for frame in frames]
    counts = Counter(event["caller"] for events in entries for event in events)
    samples = []
    for i, frame in enumerate(frames):
        sample = {"frame": i, "motion": frame.get("motion"), "row": frame.get("first"),
                  "writes": entries[i]}
        if i:
            previous = frames[i - 1]
            row = previous.get("first")
            if row is not None and row in frame["rows"] and frame.get("first") is not None:
                reader_delta = sum(event.get("scrollDelta", 0) for event in frame["events"])
                delta = frame["rows"][row] - previous["rows"][row] + reader_delta
                sample.update(row=row, delta_pt=round(delta, 3))
                if delta:
                    # Commands can land a display frame after they were issued. These are
                    # observations of co-occurrence, not proof that both commands moved the view.
                    actors = sorted({event["caller"] for events in entries[i - 1:i + 1] for event in events
                                     if event.get("kind") == "write"})
                    sample["writer_pairs"] = list(combinations(actors, 2))
            elif row != frame.get("first"):
                sample["handoff"] = {"from": row, "to": frame.get("first")}
        samples.append(sample)

    if summary is not None:
        for observation in (summary["jumps"] + summary["drift"] + summary["anchor_losses"]):
            i = observation["frame"]
            related = entries[max(0, i - 1)] + [event for _, event in observation["events"]]
            observation["writer_candidates"] = list(dict.fromkeys(event["caller"] for event in related
                                                                  if event.get("kind") in {"write", "binding"}))
            observation["layout_changes"] = list(dict.fromkeys(event["caller"] for event in related
                                                               if event.get("kind") == "layout"))
            if any(event["caller"] == "NSClipView.bounds" for _, event in observation["events"]):
                observation["observed_offset_writers"] = list(dict.fromkeys(
                    native_scroll_path(event) for _, event in observation["events"]
                    if event["caller"] == "NSClipView.bounds"))
            elif "SwiftUI row layout (clip offset unchanged)" in observation["paths"]:
                observation["observed_offset_writers"] = []  # F8: a row moved, not the viewport.
    return {"hz": round(1 / median(frame["refreshInterval"] for frame in frames), 2),
            "writer_counts": dict(sorted(counts.items())), "frames": samples}


def scroll_evidence(scenarios):
    if set(scenarios) != set(SCROLL_SCENARIOS):
        raise ValueError("expected all six scroll scenarios")
    summaries = {}
    for name, required in SCROLL_SCENARIOS.items():
        frames = scenarios[name]
        check_scroll_actions(name, frames, required)
        summary = measure_scroll(frames)
        if summary["final_comparable_frames"] < 8 and not summary["anchor_losses"]:
            raise ValueError(f"{name}: too few comparable settle frames")
        ledger = scroll_ledger(frames, summary)
        expected = {f"thread.write.{writer}" for writer in SCROLL_EXPECTED_WRITERS.get(name, ())}
        if missing := expected - ledger["writer_counts"].keys():
            raise ValueError(f"{name}: missing writer probes {sorted(missing)}")
        summary["ledger"] = ledger
        summary["hz"] = ledger.pop("hz")
        summaries[name] = summary
    return summaries


def run_scroll_case(mac, command, wrapper, log, anchor_off=None, ios_frames=None):
    pin = ROOT / ".build/pi-engine/pin.json"
    if not pin.is_file() or pin.read_bytes() != (ROOT / "scripts/pi-engine-pin.json").read_bytes():
        subprocess.run([*wrapper, sys.executable, "scripts/pi_engine.py", "stage"], cwd=ROOT,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    scratch = mac / "scratch"
    scratch.mkdir(mode=0o700)
    (scratch / "tmp").mkdir()
    trace = mac / "frames.json"
    env = {"HOME": str(scratch), "CFFIXED_USER_HOME": str(scratch), "TMPDIR": str(scratch / "tmp"),
           "SHEPHERD_SUPPORT_DIR": str(scratch / "support"), "SHEPHERD_SCROLL_TRACE": str(trace),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    if anchor_off:
        env["SHEPHERD_SCROLL_ANCHOR_OFF"] = anchor_off
    app = ROOT / ".build/scroll-dev/Build/Products/Debug/Shepherd.app/Contents/MacOS/Shepherd"
    subprocess.run([app, "--validate-scroll-stability"], cwd=scratch, env=env,
                   stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
    scenarios = json.loads(trace.read_text(encoding="utf-8"))
    summaries = scroll_evidence(scenarios)
    if anchor_off:
        for summary in summaries.values():
            summary["native_anchor_disabled"] = anchor_off
    (mac / "scroll-jumps.json").write_text(json.dumps(summaries, indent=2) + "\n", encoding="utf-8")
    if ios_frames:
        mobile = json.loads(ios_frames.read_text(encoding="utf-8"))
        (mac.parent / "ios-scroll-ledger.json").write_text(
            json.dumps({name: scroll_ledger(frames) for name, frames in mobile.items()}, indent=2) + "\n", encoding="utf-8")
    steps = mac / "steps"
    steps.mkdir()

    def record(step, status, expected, actual):
        (steps / f"{step}.json").write_text(json.dumps(dict(step=step, status=status, expected=expected,
            actual=actual, evidence=["mac/frames.json", "mac/scroll-jumps.json"])), encoding="utf-8")

    for name, summary in summaries.items():
        jumps, drift, losses = summary["jumps"], summary["drift"], summary["anchor_losses"]
        actual = (f"{len(jumps)} jumps, {len(drift)} drift excursions, {len(losses)} anchor swaps/losses, "
                  f"{len(summary['sticky_follows'])} expected sticky follows, "
                  f"{len(summary['in_band_inputs'])} in-band input residuals across {summary['frames']} frames")
        if any(jump["delta_pt"] is None for jump in jumps):
            actual += "\nUnrestored anchor loss counted as a jump of unknown magnitude."
        if name == "page-older-history" and any(e["caller"] == "fixture.historyVisibilityFallback"
                                                 for f in scenarios[name] for e in f["events"]):
            actual += "\nfixture.historyVisibilityFallback used; sentinel delivery not verified."
        print(f"{name}: {actual}")
        for label, observations in (("Jump paths", jumps), ("Drift paths", drift), ("Anchor swap/loss paths", losses)):
            if observations:
                paths = sorted({path for observation in observations for path in observation["paths"]})
                actual += f"\n{label}: {', '.join(paths)}"
        record(name, "failed" if jumps or drift or losses else "passed", "0 jumps or drift >2 pt and no anchor swaps/losses", actual)
    record("complete", "passed", SCROLL_COMPLETION, SCROLL_COMPLETION)
    return 0


def run_case(name, anchor_off=None, ios_frames=None):
    case = CASES[name]
    parent = ROOT / ".build/validation"
    if parent.resolve() != parent:
        raise OSError(f"refusing to write validation artifacts through a symlink: {parent}")
    parent.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix=f"{name}-", dir=parent))
    mac = run / "mac"
    mac.mkdir()
    scroll = name == SCROLL_CASE
    wrapper = [path] if (path := os.environ.get("SHEPHERD_BUILD_WRAPPER")) else []
    command = wrapper + (["xcodebuild", "-project",
                "Shepherd.xcodeproj", "-scheme", "Shepherd (Dev)", "-destination", "platform=macOS",
                "-derivedDataPath", str(ROOT / ".build/scroll-dev"), "-onlyUsePackageVersionsFromResolvedFile",
                "-jobs", "4", "build"] if scroll else ["swift", "test", "-j", "4", "--filter", case.test])
    result = {"case": f"mac/{name}", "selected_checks": [case.test], "command": command,
              "log": LOG, "source": None, "toolchain": None, "exit_status": None, "build_test_seconds": None}
    env = {**os.environ, "SHEPHERD_VALIDATION_DIR": str(mac)}
    env.pop("SHEPHERD_LIVE_MODEL", None)
    setup_error = None
    start = None
    with (run / LOG).open("w", encoding="utf-8") as log:
        try:
            result["source"] = source_identity()
            if sys.platform != "darwin":
                setup_error = f"{name} requires macOS and AppKit"
                print(setup_error, file=log)
            else:
                version = subprocess.check_output(["xcodebuild", "-version"] if scroll else ["swift", "--version"],
                                                  cwd=ROOT, env=env, stderr=subprocess.STDOUT)
                result["toolchain"] = version.decode(errors="replace").strip()
                start = time.monotonic()
                if scroll:
                    result["exit_status"] = run_scroll_case(mac, command, wrapper, log, anchor_off, ios_frames)
                else:
                    result["exit_status"] = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            setup_error = str(error)
            print(setup_error, file=log)
            if isinstance(error, subprocess.CalledProcessError):
                if scroll and start is not None:
                    result["exit_status"] = error.returncode
                if error.output:
                    print(error.output.decode(errors="replace").strip(), file=log)
        finally:
            if start is not None:
                result["build_test_seconds"] = round(time.monotonic() - start, 2)

    required_steps = case.steps | {("complete", None)}
    records, problems = read_steps(run, required_steps)
    failed = [step for step in records.values() if step["status"] == "failed"]
    for step in failed:
        step["look_first"] = (TOOLBAR if step["step"] == "open-commit-sheet"
                              else case.golden or case.scenario or case.test)
    completion = records.get(("complete", None), {})
    missing = sorted(required_steps - records.keys())
    if failed:
        status, reason = "assertion_failed", None
    elif setup_error:
        status = "build_or_setup_failed" if scroll and start is not None else "not_run"
        reason = log_diagnostic(run / LOG)
    elif result["exit_status"] and not records and not problems:
        status, reason = "build_or_setup_failed", log_diagnostic(run / LOG)
    elif (result["exit_status"] != 0 or missing or problems or completion.get("actual") != case.completion
          or completion.get("expected") != case.completion):
        status, reason = "incomplete", ("no valid completion evidence (requires every step and a zero Dev app exit)"
                                        if scroll else "no valid completion evidence (requires every step and a zero Swift exit)")
        result.update(missing_steps=missing, log_diagnostic=log_diagnostic(run / LOG))
    else:
        status, reason = "passed", None

    result.update(status=status, reason=reason, steps=list(records.values()), evidence_errors=problems)
    report = run / "result.json"
    report.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    def evidence_path(path):
        return str((run / path).relative_to(ROOT))

    for step in failed:
        scope = f"{case.scope}, {step['appearance']}" if step.get("appearance") else case.scope
        print(f"FAIL mac/{name}/{step['step']} [{scope}]")
        for prefix, label, value in (("-", "Expected: ", step["expected"]), ("+", "Actual:   ", step["actual"])):
            for line in (label + value).splitlines():
                print(f"{prefix} {line}")
        print(f"Look first: {step['look_first']}.")
        print(f"Evidence: {', '.join(evidence_path(path) for path in [LOG, *step['evidence']])}")
    if status == "passed":
        print(f"PASS mac/{name} [{case.scope}{case.appearances}] ({result['build_test_seconds']:.2f}s build/test)")
    elif reason:
        print(f"{'NOT RUN' if status == 'not_run' else 'FAIL'} mac/{name} [{status}]: {reason}")
        if status == "incomplete":
            if missing:
                print("Missing steps: " + ", ".join(f"{step} [{appearance}]" if appearance else step
                                                   for step, appearance in missing))
            print(result["log_diagnostic"])
        print(f"Evidence: {evidence_path(LOG)}")
    for problem in problems:
        print(f"Evidence error: {problem}")
    print(f"Report: {report.relative_to(ROOT)}")
    return 0 if status == "passed" else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=CASES)
    parser.add_argument("--scroll-anchor-off", choices=("M2", "M3", "M4", "M13"), help="fixture-only A/B arm")
    parser.add_argument("--ios-scroll-frames", type=Path, help="also summarize a simulator fixture's scroll-frames.json")
    args = parser.parse_args(argv)
    name = args.case
    if (args.scroll_anchor_off or args.ios_scroll_frames) and name != SCROLL_CASE:
        parser.error("scroll options require --case scroll-stability")
    if name is None:
        print("selection not implemented", file=sys.stderr)
        return 1
    try:
        return run_case(name, args.scroll_anchor_off, args.ios_scroll_frames)
    except OSError as error:
        print(f"NOT RUN mac/{name}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

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
    "slow-scroll-streaming": ("fixture.streamChunk", "fixture.scrollInput"),
    "flick-and-stop": ("fixture.scrollInput",),
    "mid-history-new-turn": ("fixture.newTurn", "fixture.scrollInput"),
    "page-older-history": ("fixture.pageRequested", "fixture.pageReply"),
    "window-resize": ("fixture.windowResize",),
    "switch-away-back": ("fixture.switchAway", "fixture.switchBack"),
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
    for line in stack:
        fields = line.split(maxsplit=3)
        if len(fields) == 4 and fields[1] == "AppKit":
            return f"AppKit {fields[3].rsplit(' + ', 1)[0]}"
    return "NSClipView.bounds (native caller unavailable)"


def scroll_paths(previous, frame, events):
    writes = [event["caller"] for _, event in events if event["caller"].startswith("Thread")]
    native = [native_scroll_path(event) for _, event in events if event["caller"] == "NSClipView.bounds"]
    if not native:
        native = ["SwiftUI row layout (clip offset unchanged)" if frame.get("offset") == previous.get("offset")
                  else "unattributed clip offset change"]
    # A requested write isn't necessarily the cause of the native change. Keep both.
    return list(dict.fromkeys(writes + native))


def scroll_evidence(scenarios):
    if set(scenarios) != set(SCROLL_SCENARIOS):
        raise ValueError("expected all six scroll scenarios")
    summaries = {}
    for name, required in SCROLL_SCENARIOS.items():
        frames = scenarios[name]
        if len(frames) < 2 or any(a["timestamp"] >= b["timestamp"] for a, b in zip(frames, frames[1:])):
            raise ValueError(f"{name}: missing or unordered display frames")
        callers = {event["caller"] for frame in frames for event in frame["events"]}
        if not callers.issuperset(required):
            raise ValueError(f"{name}: missing actions {sorted(set(required) - callers)}")
        jumps, anchor_losses = [], []
        previous, pending = None, []
        compared = 0
        for i, frame in enumerate(frames):
            pending.extend((i, event) for event in frame["events"])
            if frame["hidden"]:
                continue  # Compare with the last visible frame when the same thread returns.
            if previous is not None and not any(e["caller"] == "fixture.scrollInput" for _, e in pending):
                anchor, origin = previous["first"], previous["rows"][previous["first"]]
                if anchor not in frame["rows"]:
                    anchor_losses.append({"frame": i, "row": anchor, "first_after": frame.get("first"),
                                          "paths": scroll_paths(previous, frame, pending), "events": pending})
                else:
                    compared += 1
                    delta = frame["rows"][anchor] - origin
                    if abs(delta) > 2:
                        jumps.append({"frame": i, "row": anchor, "delta_pt": round(delta, 3), "first_after": frame.get("first"),
                                      "paths": scroll_paths(previous, frame, pending), "events": pending})
            previous = frame if frame.get("first") else None
            pending = []
        if not compared:
            raise ValueError(f"{name}: no comparable non-input frames")
        summaries[name] = {"frames": len(frames), "compared_frames": compared,
                           "jumps": jumps, "anchor_losses": anchor_losses}
    return summaries


def run_scroll_case(mac, command, log):
    pin = ROOT / ".build/pi-engine/pin.json"
    if not pin.is_file() or pin.read_bytes() != (ROOT / "scripts/pi-engine-pin.json").read_bytes():
        subprocess.run([command[0], sys.executable, "scripts/pi_engine.py", "stage"], cwd=ROOT,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    scratch = mac / "scratch"
    scratch.mkdir(mode=0o700)
    (scratch / "tmp").mkdir()
    trace = mac / "frames.json"
    env = {"HOME": str(scratch), "CFFIXED_USER_HOME": str(scratch), "TMPDIR": str(scratch / "tmp"),
           "SHEPHERD_SUPPORT_DIR": str(scratch / "support"), "SHEPHERD_SCROLL_TRACE": str(trace),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    app = ROOT / ".build/scroll-dev/Build/Products/Debug/Shepherd.app/Contents/MacOS/Shepherd"
    subprocess.run([app, "--validate-scroll-stability"], cwd=scratch, env=env,
                   stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
    summaries = scroll_evidence(json.loads(trace.read_text(encoding="utf-8")))
    (mac / "scroll-jumps.json").write_text(json.dumps(summaries, indent=2) + "\n", encoding="utf-8")
    steps = mac / "steps"
    steps.mkdir()

    def record(step, status, expected, actual):
        (steps / f"{step}.json").write_text(json.dumps(dict(step=step, status=status, expected=expected,
            actual=actual, evidence=["mac/frames.json", "mac/scroll-jumps.json"])), encoding="utf-8")

    for name, summary in summaries.items():
        jumps, losses = summary["jumps"], summary["anchor_losses"]
        actual = f"{len(jumps)} jumps, {len(losses)} anchor losses across {summary['frames']} frames"
        print(f"{name}: {actual}")
        for label, observations in (("Jump paths", jumps), ("Anchor loss paths", losses)):
            if observations:
                paths = sorted({path for observation in observations for path in observation["paths"]})
                actual += f"\n{label}: {', '.join(paths)}"
        record(name, "failed" if jumps or losses else "passed", "0 jumps >2 pt and no lost anchors", actual)
    record("complete", "passed", SCROLL_COMPLETION, SCROLL_COMPLETION)
    return 0


def run_case(name):
    case = CASES[name]
    parent = ROOT / ".build/validation"
    if parent.resolve() != parent:
        raise OSError(f"refusing to write validation artifacts through a symlink: {parent}")
    parent.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix=f"{name}-", dir=parent))
    mac = run / "mac"
    mac.mkdir()
    scroll = name == SCROLL_CASE
    command = ([str(Path.home() / "Developer/Shepherd-worktrees/bin/gated"), "xcodebuild", "-project",
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
                    result["exit_status"] = run_scroll_case(mac, command, log)
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
    name = parser.parse_args(argv).case
    if name is None:
        print("selection not implemented", file=sys.stderr)
        return 1
    try:
        return run_case(name)
    except OSError as error:
        print(f"NOT RUN mac/{name}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

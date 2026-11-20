#!/usr/bin/env python3
"""Run a named local Shepherd check and keep its evidence in .build/validation/."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CASE = "changes-review"
TEST = "ReviewFlowTests/opensCommitSheetWithoutChangingGit"
STEPS = {"load-changes", "open-commit-sheet", "commit-sheet-files", "close-commit-sheet", "git-unchanged"}
APPEARANCES = ("light", "dark")
COMPLETE = "light and dark scenarios finished"
TOOLBAR = "the narrow toolbar in Sources/ShepherdApp/DiffReviewView.swift"
SCENARIO = "Tests/ShepherdAppIntegrationTests/ReviewFlowTests.swift"
LOG = "mac/run.log"


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


def read_steps(run):
    records, problems = {}, []
    for path in sorted((run / "mac/steps").glob("*.json")):
        try:
            step = json.loads(path.read_text(encoding="utf-8"))
            name, appearance = step["step"], step.get("appearance")
            valid_name = (name == "complete" and appearance is None) or (name in STEPS and appearance in APPEARANCES)
            if (not valid_name or step["status"] not in ("passed", "failed") or (name, appearance) in records
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


def run_case():
    parent = ROOT / ".build/validation"
    if parent.resolve() != parent:
        raise OSError(f"refusing to write validation artifacts through a symlink: {parent}")
    parent.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix=f"{CASE}-", dir=parent))
    mac = run / "mac"
    mac.mkdir()
    command = ["swift", "test", "-j", "4", "--filter", TEST]
    result = {"case": f"mac/{CASE}", "selected_checks": [TEST], "command": command,
              "log": LOG, "source": None, "toolchain": None, "exit_status": None, "build_test_seconds": None}
    env = {**os.environ, "SHEPHERD_VALIDATION_DIR": str(mac)}
    env.pop("SHEPHERD_LIVE_MODEL", None)
    setup_error = None
    with (run / LOG).open("w", encoding="utf-8") as log:
        try:
            result["source"] = source_identity()
            if sys.platform != "darwin":
                setup_error = "changes-review requires macOS and AppKit"
                print(setup_error, file=log)
            else:
                version = subprocess.check_output(["swift", "--version"], cwd=ROOT, env=env, stderr=subprocess.STDOUT)
                result["toolchain"] = version.decode(errors="replace").strip()
                start = time.monotonic()
                result["exit_status"] = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
                result["build_test_seconds"] = round(time.monotonic() - start, 2)
        except (OSError, subprocess.CalledProcessError) as error:
            setup_error = str(error)
            print(setup_error, file=log)
            if isinstance(error, subprocess.CalledProcessError) and error.output:
                print(error.output.decode(errors="replace").strip(), file=log)

    records, problems = read_steps(run)
    failed = [step for step in records.values() if step["status"] == "failed"]
    for step in failed:
        step["look_first"] = TOOLBAR if step["step"] == "open-commit-sheet" else SCENARIO
    completion = records.get(("complete", None), {})
    missing = sorted({(name, appearance) for name in STEPS for appearance in APPEARANCES} - records.keys())
    if failed:
        status, reason = "assertion_failed", None
    elif setup_error:
        status, reason = "not_run", log_diagnostic(run / LOG)
    elif result["exit_status"] and not records and not problems:
        status, reason = "build_or_setup_failed", log_diagnostic(run / LOG)
    elif (result["exit_status"] != 0 or missing or problems or completion.get("actual") != COMPLETE
          or completion.get("expected") != COMPLETE):
        status, reason = "incomplete", "no valid completion evidence (requires all checks in light and dark and a zero Swift exit)"
    else:
        status, reason = "passed", None

    result.update(status=status, reason=reason, steps=list(records.values()), evidence_errors=problems)
    report = run / "result.json"
    report.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for step in failed:
        print(f"FAIL mac/{CASE}/{step['step']} [narrow, {step['appearance']}]")
        print(f"- Expected: {step['expected']}\n+ Actual:   {step['actual']}")
        print(f"Look first: {step['look_first']}.")
        print(f"Evidence: {', '.join([LOG, *step['evidence']])}")
    if status == "passed":
        print(f"PASS mac/{CASE} [narrow, light and dark] ({result['build_test_seconds']:.2f}s build/test)")
    elif reason:
        print(f"{'NOT RUN' if status == 'not_run' else 'FAIL'} mac/{CASE} [{status}]: {reason}")
        print(f"Evidence: {LOG}")
    print(f"Report: {report.relative_to(ROOT)}")
    return 0 if status == "passed" else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=[CASE])
    if parser.parse_args(argv).case is None:
        print("selection not implemented", file=sys.stderr)
        return 1
    try:
        return run_case()
    except OSError as error:
        print(f"NOT RUN mac/{CASE}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

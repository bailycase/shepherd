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


@dataclass(frozen=True)
class Case:
    test: str
    steps: set[tuple[str, str | None]]
    completion: str
    scope: str
    appearances: str = ""

    @property
    def scenario(self):
        return f"Tests/ShepherdAppIntegrationTests/{self.test.split('/')[0]}.swift"


CASES = {
    "changes-review": Case(
        "ReviewFlowTests/opensCommitSheetWithoutChangingGit",
        {(step, appearance)
         for step in ("load-changes", "open-commit-sheet", "commit-sheet-files", "close-commit-sheet", "git-unchanged")
         for appearance in ("light", "dark")},
        "light and dark scenarios finished", "narrow", ", light and dark",
    ),
    "seeded-thread-rename": Case(
        "ThreadRenameTests/seededThreadRenameSurvivesHostRestart",
        {("compare-golden", None)}, "rename, restart and sidebar matched the golden", "local host",
    ),
    "c-wire": Case(
        "WireRequestSequenceTests/wireMatchesGolden|WireCodecTests/wireMatchesGolden",
        {("codec-golden", None), ("compare-golden", None)}, "scratch-host request sequences matched the golden", "wire",
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


def run_case(name):
    case = CASES[name]
    parent = ROOT / ".build/validation"
    if parent.resolve() != parent:
        raise OSError(f"refusing to write validation artifacts through a symlink: {parent}")
    parent.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix=f"{name}-", dir=parent))
    mac = run / "mac"
    mac.mkdir()
    command = ["swift", "test", "-j", "4", "--filter", case.test]
    result = {"case": f"mac/{name}", "selected_checks": [case.test], "command": command,
              "log": LOG, "source": None, "toolchain": None, "exit_status": None, "build_test_seconds": None}
    env = {**os.environ, "SHEPHERD_VALIDATION_DIR": str(mac)}
    env.pop("SHEPHERD_LIVE_MODEL", None)
    setup_error = None
    with (run / LOG).open("w", encoding="utf-8") as log:
        try:
            result["source"] = source_identity()
            if sys.platform != "darwin":
                setup_error = f"{name} requires macOS and AppKit"
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

    required_steps = case.steps | {("complete", None)}
    records, problems = read_steps(run, required_steps)
    failed = [step for step in records.values() if step["status"] == "failed"]
    for step in failed:
        step["look_first"] = TOOLBAR if step["step"] == "open-commit-sheet" else case.scenario
    completion = records.get(("complete", None), {})
    missing = sorted(required_steps - records.keys())
    if failed:
        status, reason = "assertion_failed", None
    elif setup_error:
        status, reason = "not_run", log_diagnostic(run / LOG)
    elif result["exit_status"] and not records and not problems:
        status, reason = "build_or_setup_failed", log_diagnostic(run / LOG)
    elif (result["exit_status"] != 0 or missing or problems or completion.get("actual") != case.completion
          or completion.get("expected") != case.completion):
        status, reason = "incomplete", "no valid completion evidence (requires every step and a zero Swift exit)"
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
        print(f"- Expected: {step['expected']}\n+ Actual:   {step['actual']}")
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

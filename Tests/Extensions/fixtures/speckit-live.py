"""Opt-in acceptance workflow. Uses upstream Spec Kit dispatch, not a replacement executor."""
import json
from pathlib import Path
import subprocess
import sys
import time

from specify_cli.extensions import HookExecutor
from specify_cli.workflows.base import StepContext, StepStatus
from specify_cli.workflows.step.command import CommandStep

root = Path(sys.argv[1]).resolve()
model = sys.argv[2]
report = root / "live-report.json"
results = []
started = time.monotonic()
common = " Work non-interactively in this disposable repository. No commits, dependencies, network, UI, or extra features. Make reasonable choices consistent with the explicit requirements; no human approval is needed. Keep generated documents concise."
steps = [
    ("constitution", "Create version 1.0.0 of the constitution for a tiny Python standard-library duration parser. Principles: one small pure function, explicit input validation, unittest regression tests, no third-party dependencies. Governance: amend with the change, simplest correct solution first. All dates are 2026-10-24."),
    ("specify", "Implement duration.parse_duration(text: str) -> int seconds. Accept exactly 1 to 6 ASCII digits followed by one lowercase unit s, m, or h. Leading zeroes are allowed. Examples: 0s=0, 15m=900, 2h=7200, 001m=60. Reject whitespace, signs, decimals, Unicode digits, compound durations, missing units, uppercase units, empty strings and more than 6 digits with ValueError. Reject non-string inputs with TypeError. Support 999999h without overflow. No CLI or UI. Public API is one Python function. Use only the Python standard library; unittest tests must run with python3 -m unittest discover -v."),
    ("clarify", "All behavior is explicit in the specification: exact case-sensitive full-string ASCII format, 1-6 digits, leading zeroes accepted, no whitespace, non-string TypeError, malformed strings ValueError, units converted to seconds, maximum valid input 999999h. No product choices remain. Record any necessary clarifications using these answers; if nothing material is ambiguous report no further clarification needed."),
    ("plan", "Use Python 3.11+ and only its standard library. Implementation: duration.py with parse_duration; test_duration.py using unittest. A fullmatch of ([0-9]{1,6})([smh]) plus unit conversion suffices. Validate the string type. No packaging, CLI, services, persistence, concurrency, or extra abstraction. Include useful valid, boundary, and invalid-input tests."),
    ("tasks", "Generate the minimal dependency-ordered tasks for this one-function implementation and its unittest tests. No scaffolding beyond the approved plan."),
    ("analyze", "Analyze the spec, plan, constitution, and tasks for correctness and consistency. This step is read-only; report any issues in the response."),
    ("implement", "Implement all approved tasks, run python3 -m unittest discover -v, and mark completed tasks. Stay within duration.py and test_duration.py plus the Spec Kit task/checklist bookkeeping. Do not commit."),
]
context = StepContext(project_root=str(root), default_integration="pi", default_model=model)

try:
    for name, arguments in steps:
        if time.monotonic() - started >= 25 * 60:
            raise RuntimeError("Acceptance workflow reached its 25-minute execution limit")
        result = CommandStep().execute({"id": name, "command": f"speckit.{name}", "input": {"args": arguments + common}, "capture": True, "timeout": 360}, context)
        output = result.output or {}
        (root / f"live-{name}.txt").write_text(str(output.get("stdout", "")) + str(output.get("stderr", "")))
        results.append({"step": name, "status": result.status.value, "exit_code": output.get("exit_code"), "seconds": round(time.monotonic() - started, 1)})
        report.write_text(json.dumps({"steps": results, "complete": False}, indent=2))
        if result.status != StepStatus.COMPLETED or output.get("exit_code") != 0:
            raise RuntimeError(f"Spec Kit step {name} failed: {result.error}")
        if name == "tasks":
            # The tasks prompt can run the mandatory hook inline. Dispatch it independently
            # as well to cover the upstream extension-to-subprocess path, not only model prose.
            hooks = HookExecutor(root).check_hooks_for_event("after_tasks")
            for hook in hooks["hooks"]:
                invocation = HookExecutor(root).execute_hook(hook)
                hooked = CommandStep().execute({"id": "after_tasks", "command": invocation["invocation"].lstrip("/"), "capture": True, "timeout": 120}, context)
                (root / "live-hook.txt").write_text(str((hooked.output or {}).get("stdout", "")))
                if hooked.status != StepStatus.COMPLETED:
                    raise RuntimeError("Registered extension hook dispatch failed")
    verified = subprocess.run([sys.executable, "-m", "unittest", "discover", "-v"], cwd=root, capture_output=True, text=True, timeout=30)
    (root / "live-tests.txt").write_text(verified.stdout + verified.stderr)
    if verified.returncode:
        raise RuntimeError("Generated unittest suite failed")
    # Independent acceptance assertions do not trust the generated tests or model prose.
    acceptance = '''from duration import parse_duration
assert [parse_duration(x) for x in ['0s','15m','2h','001m','999999h']] == [0,900,7200,60,3599996400]
for value in ['', '1', '1S', ' 1s', '1s ', '-1s', '+1s', '1.5h', '1h30m', '1234567s', '\\u0661s', '1 s']:
    try: parse_duration(value)
    except ValueError: pass
    else: raise AssertionError(repr(value))
for value in [None, 1, True, b'1s']:
    try: parse_duration(value)
    except TypeError: pass
    else: raise AssertionError(repr(value))
'''
    subprocess.run([sys.executable, "-c", acceptance], cwd=root, check=True, capture_output=True, text=True, timeout=10)
    specs = list((root / "specs").glob("*/spec.md"))
    assert len(specs) == 1, "Expected one generated feature specification"
    feature = specs[0].parent
    for file in [root / ".specify/memory/constitution.md", feature / "plan.md", feature / "tasks.md", root / "duration.py", root / "test_duration.py"]:
        assert file.is_file(), f"Missing artifact {file.name}"
    assert "- [ ]" not in (feature / "tasks.md").read_text(), "Implementation left unfinished tasks"
    assert (root / "upstream-hooks.txt").is_file(), "Registered extension hook did not run"
    report.write_text(json.dumps({"steps": results, "complete": True, "acceptance": "passed", "feature": str(feature.relative_to(root))}, indent=2))
    print("SPECKIT_LIVE_ACCEPTANCE_PASSED")
except Exception as error:
    report.write_text(json.dumps({"steps": results, "complete": False, "error": str(error)}, indent=2))
    raise

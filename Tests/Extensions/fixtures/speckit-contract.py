"""Opt-in checks against an installed upstream specify-cli, with local fixtures only."""
import json
import os
from pathlib import Path
import subprocess
import sys

from specify_cli.extensions import HookExecutor
from specify_cli.integrations.pi import PiIntegration
from specify_cli.workflows.base import StepContext, StepStatus
from specify_cli.workflows.step.command import CommandStep

root = Path(sys.argv[2]).resolve()

if sys.argv[1] == "setup":
    specify = str(Path(sys.executable).with_name("specify"))
    subprocess.run([specify, "init", str(root), "--integration", "pi", "--ignore-agent-tools", "--non-interactive", "--force"], check=True, timeout=20, capture_output=True)
    source = root.parent / "fixture-extension"
    (source / "commands").mkdir(parents=True)
    (source / "commands/record.md").write_text("---\ndescription: Local hook fixture\n---\nSPECKIT_REGISTERED_HOOK\n$ARGUMENTS\nRecord completion in upstream-hooks.txt using bash.\n")
    manifest = {
        "schema_version": "1.0",
        "extension": {"id": "fixture", "name": "Local fixture", "version": "1.0.0", "description": "Local compatibility check", "author": "fixture", "repository": "https://fixture.invalid", "license": "MIT"},
        "requires": {"speckit_version": ">=0.1.0"},
        "provides": {"commands": [{"name": "speckit.fixture.record", "file": "commands/record.md", "description": "Record hook completion"}]},
        "hooks": {"after_tasks": {"command": "speckit.fixture.record", "optional": False}},
    }
    (source / "extension.yml").write_text(json.dumps(manifest))
    subprocess.run([specify, "extension", "add", str(source), "--dev"], cwd=root, check=True, timeout=20, capture_output=True)
    assert (root / ".pi/prompts/speckit.fixture.record.md").is_file()
    hooks = HookExecutor(root).check_hooks_for_event("after_tasks")
    assert hooks["has_hooks"] and hooks["hooks"][0]["command"] == "speckit.fixture.record"
else:
    executor = HookExecutor(root)
    config = executor.get_project_config()
    base = {"extension": "fixture", "command": "speckit.fixture.record", "optional": False}
    config["hooks"]["before_tasks"] = [
        base,
        {**base, "command": "speckit.fixture.optional", "optional": True},
        {**base, "command": "speckit.fixture.disabled", "enabled": False},
        {**base, "command": "speckit.fixture.allowed", "condition": "env.SPECKIT_FIXTURE_CONDITION == 'yes'"},
        {**base, "command": "speckit.fixture.denied", "condition": "env.SPECKIT_FIXTURE_CONDITION == 'no'"},
    ]
    executor.save_project_config(config)
    os.environ["SPECKIT_FIXTURE_CONDITION"] = "yes"
    checked = executor.check_hooks_for_event("before_tasks")
    assert [h["command"] for h in checked["hooks"]] == ["speckit.fixture.record", "speckit.fixture.optional", "speckit.fixture.allowed"]
    hook = executor.execute_hook(checked["hooks"][0])
    assert hook["invocation"] == "/speckit.fixture.record"
    assert not (root / "upstream-hooks.txt").exists(), "HookExecutor returns metadata, not execution"
    assert os.environ.get("SPECKIT_INTEGRATION_PI_EXECUTABLE") is None
    assert Path(subprocess.check_output(["/bin/sh", "-c", "command -v pi"], text=True).strip()).name == "pi"
    integration = PiIntegration()
    result = integration.dispatch_command(hook["command"], "raw-json", project_root=root, model="fixture/fixture", stream=False, output_json=True, timeout=20)
    assert result["exit_code"] == 0, result
    events = [json.loads(line) for line in result["stdout"].splitlines() if line.startswith("{")]
    assert any(event.get("type") == "agent_end" for event in events), result
    step = CommandStep().execute(
        {"id": "hook", "command": executor.check_hooks_for_event("after_tasks")["hooks"][0]["command"], "capture": True, "timeout": 20},
        StepContext(project_root=str(root), default_integration="pi", default_model="fixture/fixture"),
    )
    assert step.status == StepStatus.COMPLETED, step
    assert step.output["exit_code"] == 0, step
    print(json.dumps({"hooks": "checked", "json_dispatch": "completed", "workflow": step.status.value}))

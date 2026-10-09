"""Self-hosted selection against explicit fake API states; no tokens, runner, or network."""
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import release
import release_runner as runner
from test_ci_runner import select as select_expression
from test_ci_workflow import jobs, run_script

SHA = "a" * 40
PLAN = release.plan("refs/heads/nightly", "202610010000")
PARENT = {"path": ".github/workflows/release.yml", "event": "push", "status": "in_progress",
          "run_attempt": 1, "head_sha": SHA, "run_number": 42, "head_branch": "nightly"}


class API:
    def __init__(self, states, acknowledgement=("completed",), discover=True, artifacts=True):
        self.states = list(states)
        self.acknowledgement = list(acknowledgement)
        self.discover = discover
        self.artifacts = artifacts
        self.calls = []
        self.cancelled = False
        self.current = ("queued", None)
        self.parent = dict(PARENT)
        self.duplicate = False
        self.error = None
        self.selecting = True
        self.cancel_conflict = None
        self.cancel_status = 409

    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        if self.error and self.error in path:
            raise runner.RunnerError("fixture API outage")
        if path == "/actions/runs/10":
            return dict(self.parent)
        if path.startswith("/actions/runs/10/jobs?"):
            return {"jobs": [{"name": "Prefer Self-hosted for Nightly", "status": "in_progress"}] if self.selecting else []}
        if path.endswith("/dispatches"):
            self.dispatch = body
            return {}
        if path.startswith("/actions/workflows/release-build.yml/runs?"):
            matches = [{"id": 20, "display_title": "Self-hosted release 10-1"}] if self.discover else []
            return {"workflow_runs": matches * (2 if self.duplicate else 1)}
        if path == "/actions/runs/20/cancel":
            if self.cancel_conflict is not None:
                self.states = [self.cancel_conflict]
                raise runner.RunnerError("fixture cancellation conflict", status=self.cancel_status)
            self.cancelled = True
            return {}
        if path == "/actions/runs/20":
            if self.cancelled:
                status = self.acknowledgement[0]
                if len(self.acknowledgement) > 1:
                    self.acknowledgement.pop(0)
                self.current = (status, "cancelled" if status == "completed" else None)
            else:
                self.current = self.states[0]
                if len(self.states) > 1:
                    self.states.pop(0)
            return {"status": self.current[0], "conclusion": self.current[1], "run_attempt": 1}
        if path.startswith("/actions/runs/20/jobs?"):
            status, conclusion = self.current
            return {"jobs": [{"name": runner.BUILD_JOB, "status": status, "conclusion": conclusion}]}
        if path.startswith("/actions/runs/20/artifacts?"):
            return {"artifacts": [{"name": runner.artifact_name(10, 1), "expired": False}] if self.artifacts else []}
        raise AssertionError((method, path, body))


class Clock:
    def __init__(self):
        self.now = 0

    def __call__(self):
        return self.now

    def sleep(self, duration):
        self.now += duration


class SelectionTests(unittest.TestCase):
    def select(self, api, **kwargs):
        self.clock = Clock()
        self.outputs = {}
        runner.select_local(api, 10, 1, SHA, 42, PLAN, self.outputs.__setitem__,
                            clock=self.clock, sleep=self.clock.sleep, **kwargs)

    def test_success_uses_exact_parent_identity_and_only_local_artifact(self):
        api = API([("in_progress", None), ("completed", "success")])
        self.select(api)
        self.assertEqual(self.outputs, {"worker_run": "20", "package_run": "20", "fallback": "false"})
        self.assertEqual(api.dispatch["ref"], "nightly")
        self.assertEqual(api.dispatch["inputs"]["source_sha"], SHA)
        self.assertEqual(api.dispatch["inputs"]["build_number"], "42")
        self.assertFalse(api.cancelled)

    def test_queue_deadline_waits_for_delayed_cancel_ack_before_fallback(self):
        api = API([("queued", None)], acknowledgement=("in_progress", "completed"))
        self.select(api)
        self.assertEqual(self.clock.now, runner.QUEUE + runner.INTERVAL)
        self.assertEqual(self.outputs["fallback"], "true")
        self.assertTrue(api.cancelled)
        self.assertNotIn("package_run", self.outputs)
        self.assertEqual(sum(path.endswith("/dispatches") for _, path, _ in api.calls), 1)

    def test_execution_limit_is_separate_from_queue_deadline(self):
        api = API([("queued", None), ("in_progress", None)])
        self.select(api)
        self.assertEqual(self.clock.now, runner.INTERVAL + runner.EXECUTION)
        self.assertEqual(self.outputs["fallback"], "true")

    def test_known_build_failure_or_timeout_falls_back_without_cancellation(self):
        for conclusion in ("failure", "timed_out"):
            with self.subTest(conclusion=conclusion):
                api = API([("completed", conclusion)])
                self.select(api)
                self.assertEqual(self.outputs["fallback"], "true")
                self.assertFalse(api.cancelled)

    def test_uncertain_dispatch_state_or_artifacts_never_authorizes_fallback(self):
        scenarios = [API([("queued", None)], discover=False),
                     API([("queued", None)], acknowledgement=("in_progress",)),
                     API([("completed", "cancelled")]),
                     API([("completed", "success")], artifacts=False)]
        duplicate = API([("queued", None)])
        duplicate.duplicate = True
        scenarios.append(duplicate)
        outage = API([("queued", None)])
        outage.error = "/actions/runs/20/jobs?"
        scenarios.append(outage)
        for api in scenarios:
            with self.subTest(api=api):
                with self.assertRaises(runner.RunnerError):
                    self.select(api)
                self.assertNotIn("fallback", self.outputs)
                self.assertLessEqual(self.clock.now, runner.QUEUE + runner.CANCEL)
                self.assertEqual(sum(path.endswith("/dispatches") for _, path, _ in api.calls), 1)

    def test_stop_or_mismatched_parent_prevents_dispatch(self):
        for change in ({"status": "completed"}, {"run_attempt": 2}, {"head_sha": "b" * 40},
                       {"run_number": 43}, {"head_branch": "feature"}, {"event": "pull_request"},
                       {"path": ".github/workflows/ci.yml"}):
            with self.subTest(change=change):
                api = API([("queued", None)])
                api.parent.update(change)
                with self.assertRaises(runner.RunnerError):
                    self.select(api)
                self.assertFalse(any(path.endswith("/dispatches") for _, path, _ in api.calls))

    def test_a_manual_worker_cannot_sign_for_a_parent_that_is_not_selecting_selfhosted(self):
        api = API([("queued", None)])
        api.selecting = False
        with self.assertRaises(runner.RunnerError):
            self.select(api)
        self.assertFalse(any(path.endswith("/dispatches") for _, path, _ in api.calls))

    def test_parent_stop_after_build_failure_does_not_launch_fallback(self):
        api = API([("completed", "failure")])
        request = api.request
        def stop(method, path, body=None):
            if path.startswith("/actions/runs/20/jobs?"):
                api.parent["status"] = "completed"
            return request(method, path, body)
        api.request = stop
        with self.assertRaises(runner.RunnerError):
            self.select(api)
        self.assertNotIn("fallback", self.outputs)

    def test_cancel_ack_success_race_still_prefers_local_package(self):
        api = API([("queued", None)])
        request = api.request
        def success(method, path, body=None):
            result = request(method, path, body)
            if path == "/actions/runs/20" and api.cancelled:
                result["status"] = "completed"
                result["conclusion"] = "success"
                api.current = ("completed", "success")
            return result
        api.request = success
        self.select(api)
        self.assertEqual(self.outputs["fallback"], "false")
        self.assertEqual(self.outputs["package_run"], "20")

    def test_rejected_cancel_reconciles_completion_between_get_and_post(self):
        for conclusion, fallback in (("success", "false"), ("failure", "true"), ("timed_out", "true")):
            with self.subTest(conclusion=conclusion):
                api = API([("queued", None)])
                api.cancel_conflict = ("completed", conclusion)
                self.select(api)
                self.assertEqual(self.outputs["fallback"], fallback)
                self.assertEqual(self.outputs.get("package_run"), "20" if conclusion == "success" else None)
                self.assertEqual(self.clock.now, runner.QUEUE)
                self.assertEqual(sum(path.endswith("/cancel") for _, path, _ in api.calls), 1)

    def test_rejected_cancel_still_requires_known_terminal_state_and_valid_package(self):
        for state, artifacts, status in ((("in_progress", None), True, 409),
                                         (("completed", "unknown"), True, 409),
                                         (("completed", "cancelled"), True, 409),
                                         (("completed", "success"), False, 409),
                                         (("completed", "success"), True, 403)):
            with self.subTest(state=state, artifacts=artifacts, status=status):
                api = API([("queued", None)], artifacts=artifacts)
                api.cancel_conflict = state
                api.cancel_status = status
                with self.assertRaises(runner.RunnerError):
                    self.select(api)
                self.assertNotIn("fallback", self.outputs)

    def test_explicit_cancel_is_not_a_build_failure_even_if_the_job_failed(self):
        api = API([("completed", "cancelled")])
        request = api.request
        def failed_job(method, path, body=None):
            result = request(method, path, body)
            if "/jobs?" in path:
                result["jobs"][0]["conclusion"] = "failure"
            return result
        api.request = failed_job
        with self.assertRaises(runner.RunnerError):
            self.select(api)
        self.assertNotIn("fallback", self.outputs)

    def test_plan_is_checked_not_treated_as_authority(self):
        for field, value in (("scheme", "arbitrary"), ("dmg", "../../secret"), ("notes", "forged")):
            with self.subTest(field=field):
                forged = {**PLAN, field: value}
                with self.assertRaises(runner.RunnerError):
                    runner.validate_parent(API([]), 10, 1, SHA, 42, forged, local=True)

    def test_stable_and_beta_hosted_builds_retain_release_plan_guards(self):
        for tag in ("v1.2.3", "v1.3.0-beta.1"):
            api = API([])
            api.parent["head_branch"] = tag
            plan = release.plan("refs/tags/" + tag, "202610010000")
            runner.validate_parent(api, 10, 1, SHA, 42, plan, ref="refs/tags/" + tag)
            with self.assertRaises(runner.RunnerError):
                runner.validate_parent(api, 10, 1, SHA, 42, plan, ref="refs/heads/" + tag)


class CancellationTests(unittest.TestCase):
    def test_http_error_retains_status_without_response_body_or_token(self):
        for status in (409, 403):
            with self.subTest(status=status):
                body = io.BytesIO(b"fixture private response")
                def reject(request, timeout):
                    raise urllib.error.HTTPError(request.full_url, status, "private reason", {}, body)
                client = runner.GitHub("fixture/shepherd", "fixture private token", opener=reject)
                with self.assertRaises(runner.RunnerError) as raised:
                    client.request("POST", "/actions/runs/20/cancel")
                self.assertEqual(raised.exception.status, status)
                self.assertNotIn("private", str(raised.exception))
                self.assertTrue(body.closed)

    def test_cleanup_reconciles_rejected_cancel_after_worker_completes(self):
        for conclusion in ("success", "failure", "timed_out", "cancelled"):
            with self.subTest(conclusion=conclusion):
                api = API([("in_progress", None)])
                api.cancel_conflict = ("completed", conclusion)
                with patch.object(runner, "GitHub", return_value=api), \
                     patch.dict(os.environ, {"GITHUB_REPOSITORY": "fixture/shepherd", "WORKER_RUN": "20"}), \
                     patch.object(sys, "argv", ["release_runner.py", "cancel"]):
                    self.assertEqual(runner.main(), 0)
                self.assertEqual([path for _, path, _ in api.calls],
                                 ["/actions/runs/20", "/actions/runs/20/cancel", "/actions/runs/20"])

    def test_cleanup_conflict_with_nonterminal_unknown_or_unreadable_state_fails_closed(self):
        for state in (("in_progress", None), ("completed", "unknown")):
            with self.subTest(state=state):
                api = API([("in_progress", None)])
                api.cancel_conflict = state
                with self.assertRaises(runner.RunnerError):
                    runner.cancel_run(api, 20)
        api = API([("in_progress", None)])
        api.cancel_conflict = ("completed", "success")
        request = api.request
        def unreadable(method, path, body=None):
            if method == "GET":
                raise runner.RunnerError("fixture API outage")
            return request(method, path, body)
        api.request = unreadable
        with self.assertRaises(runner.RunnerError):
            runner.cancel_run(api, 20)


class PackageTests(unittest.TestCase):
    def test_real_package_producer_preserves_signing_eligibility(self):
        workflow = (ROOT / ".github/workflows/release-build.yml").read_text()
        block = workflow.split("      - name: Record package provenance\n")[1].split("      - name:")[0]
        shell = "set -euo pipefail\n" + "\n".join(
            line[10:] for line in block.split("        run: |\n")[1].splitlines())
        for identity, eligible in (("-", False), ("", False), ("Developer ID Application: Fixture", True)):
            with self.subTest(identity=identity), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
                (root / PLAN["dmg"]).write_bytes(b"fixture")
                result = subprocess.run(["bash", "-c", shell], cwd=root, capture_output=True, text=True,
                    env={**os.environ, "GITHUB_REPOSITORY": "fixture/shepherd", "PARENT_RUN": "10",
                         "PARENT_ATTEMPT": "1", "SOURCE_SHA": SHA, "BUILD_NUMBER": "42",
                         "RELEASE_PLAN": json.dumps(PLAN), "SIGNING_IDENTITY": identity, "TAG": PLAN["tag"]}, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads((root / "shepherd-appcast.json").read_text()),
                                 {"version": 1, "tag": PLAN["tag"], "eligible": eligible})
                runner.manifest(directory, 10, 1, SHA, 42, PLAN, verify=True)

    def test_package_is_bound_to_parent_attempt_source_build_and_required_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / PLAN["dmg"]).write_bytes(b"signed archive fixture")
            policy = root / "shepherd-appcast.json"
            policy.write_text(json.dumps({"version": 1, "tag": PLAN["tag"], "eligible": True}))
            runner.manifest(directory, 10, 1, SHA, 42, PLAN)
            runner.manifest(directory, 10, 1, SHA, 42, PLAN, verify=True)
            for parent, attempt, sha, build in ((11, 1, SHA, 42), (10, 2, SHA, 42),
                                              (10, 1, "b" * 40, 42), (10, 1, SHA, 43)):
                with self.assertRaises(runner.RunnerError):
                    runner.manifest(directory, parent, attempt, sha, build, PLAN, verify=True)
            (root / PLAN["dmg"]).write_bytes(b"corrupt archive")
            with self.assertRaises(runner.RunnerError):
                runner.manifest(directory, 10, 1, SHA, 42, PLAN, verify=True)
            policy.write_text(json.dumps({"version": 1, "tag": "wrong", "eligible": True}))
            with self.assertRaises(runner.RunnerError):
                runner.manifest(directory, 10, 1, SHA, 42, PLAN)
            (root / PLAN["dmg"]).unlink()
            with self.assertRaises(runner.RunnerError):
                runner.manifest(directory, 10, 1, SHA, 42, PLAN)


class WorkflowTests(unittest.TestCase):
    def test_only_build_failure_can_enable_fallback_and_no_build_can_publish(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        build = (ROOT / ".github/workflows/release-build.yml").read_text()
        hosted = workflow.split("  hosted-build:\n")[1].split("  release:\n")[0]
        self.assertIn("needs.selfhosted.result == 'success'", hosted)
        self.assertIn("needs.selfhosted.outputs.fallback == 'true'", hosted)
        self.assertNotIn("needs.release", hosted)
        self.assertIn("!cancelled()", hosted)
        for mutation in ("git push", "gh release", "SPARKLE_PRIVATE_KEY", "contents: write", "pull_request:"):
            self.assertNotIn(mutation, build)
        self.assertIn("!inputs.hosted && 'shepherd-release' || 'macos-26'", build)
        self.assertIn('CURRENT_PROJECT_VERSION="$BUILD_NUMBER"', build)
        self.assertIn("ref: ${{ inputs.source_sha }}", build)
        self.assertIn("persist-credentials: false", build)
        self.assertIn("needs: guard", build)
        self.assertIn("timeout-minutes: 60", build)
        self.assertIn("run: python3 scripts/release_runner.py verify", workflow)
        self.assertIn("actions: write", workflow.split("  selfhosted:\n")[1].split("  hosted-build:\n")[0])

    def test_disabled_or_unset_selfhosted_selection_never_dispatches_or_waits(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        selector = jobs(workflow)["selfhosted"]
        self.assertIn("SELFHOSTED_ENABLED: ${{ vars.SHEPHERD_SELFHOSTED_ENABLED }}", selector)
        code = run_script(selector)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            python = root / "python3"
            python.write_text('#!/bin/sh\nprintf "%s\\n" "$*" > "$DISPATCH_LOG"\necho fallback=false >> "$GITHUB_OUTPUT"\n')
            python.chmod(0o700)
            for flag in (None, "", "false", "TRUE", "yes", "true"):
                with self.subTest(flag=flag):
                    output, log = root / "output", root / "dispatch"
                    output.write_text("")
                    log.unlink(missing_ok=True)
                    env = {"PATH": str(root), "GITHUB_OUTPUT": str(output), "DISPATCH_LOG": str(log)}
                    if flag is not None:
                        env["SELFHOSTED_ENABLED"] = flag
                    result = subprocess.run(["/bin/bash", "-e", "-c", code], env=env,
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(log.exists(), flag == "true")
                    self.assertEqual(output.read_text(), "fallback=false\n" if flag == "true" else "fallback=true\n")
                    if log.exists():
                        self.assertEqual(log.read_text(), "scripts/release_runner.py select\n")

    def test_disabled_local_workers_never_reach_the_mac_but_hosted_builds_still_can(self):
        build = jobs((ROOT / ".github/workflows/release-build.yml").read_text())
        for name in ("guard", "build"):
            condition = next(line.removeprefix("    if: ") for line in build[name].splitlines()
                             if line.startswith("    if: "))
            for flag in (None, "", "false", "true"):
                for hosted in (False, True):
                    for event in ("workflow_dispatch", "workflow_call", "pull_request"):
                        for ref in ("refs/heads/nightly", "refs/heads/master"):
                            with self.subTest(job=name, flag=flag, hosted=hosted, event=event, ref=ref):
                                expected = event != "pull_request" and (hosted or (flag == "true" and ref == "refs/heads/nightly"))
                                self.assertEqual(select_expression(condition, {
                                    "vars.SHEPHERD_SELFHOSTED_ENABLED": flag, "inputs.hosted": hosted,
                                    "github.event_name": event, "github.ref": ref,
                                }), expected)

    def test_public_labels_are_generic_and_machine_name_is_masked_before_steps(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        build = (ROOT / ".github/workflows/release-build.yml").read_text()
        self.assertIn("name: Prefer Self-hosted for Nightly", workflow)
        self.assertIn("run-name: Self-hosted release", build)
        self.assertIn("SELFHOSTED_HOSTNAME: ${{ secrets.SELFHOSTED_HOSTNAME }}", workflow)
        job_environment = build.split("    env:\n")[2].split("    steps:\n")[0]
        self.assertIn("SELFHOSTED_LOG_MASK: ${{ secrets.SELFHOSTED_HOSTNAME }}", job_environment)

    def test_cleanup_restores_exact_keychain_list_and_removes_credentials_even_on_restore_failure(self):
        build = (ROOT / ".github/workflows/release-build.yml").read_text()
        cleanup = build.split("      - name: Restore keychains and remove signing credentials\n")[1]
        self.assertIn("if: always()", cleanup)
        code = cleanup.split("          python3 - <<'PYTHON'\n")[1].split("          PYTHON")[0]
        code = "\n".join(line[10:] for line in code.splitlines())
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name in ("cert.p12", "notary.p8", "release-build.keychain-db"):
                    (root / name).write_text("fixture")
                old = ['login keychain', '/fixture/other.keychain-db']
                import shlex
                (root / "release-keychains.txt").write_text(shlex.join(old))
                log = root / "log"
                security = root / "security"
                security.write_text('#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ["LOG"],"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\nif sys.argv[1]=="list-keychains" and os.environ["FAIL"]=="1": sys.exit(23)\n')
                security.chmod(0o700)
                result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                    env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                         "RUNNER_TEMP": directory, "LOG": str(log), "FAIL": str(int(fail))}, timeout=5)
                self.assertEqual(result.returncode == 0, not fail, result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual(calls[0], ["list-keychains", "-d", "user", "-s", *old])
                self.assertEqual(calls[1], ["delete-keychain", str(root / "release-build.keychain-db")])
                for name in ("cert.p12", "notary.p8", "release-keychains.txt"):
                    self.assertFalse((root / name).exists())


if __name__ == "__main__":
    unittest.main()

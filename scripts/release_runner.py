#!/usr/bin/env python3
"""Bounded Self-hosted build selection. Publication is deliberately not part of this script."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import release

# A queued local build is usually waiting behind a pull request's CI on the same runner, so the
# window covers one such run; an offline runner costs this long once before the hosted fallback.
QUEUE = 900
EXECUTION = 3600
CANCEL = 120
INTERVAL = 15
WORKFLOW = "release-build.yml"
BUILD_JOB = "build package"


class RunnerError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


class GitHub:
    def __init__(self, repository, token, api="https://api.github.com", opener=None):
        self.base = api.rstrip("/") + "/repos/" + repository
        self.token = token
        self.open = opener or urllib.request.build_opener(release._NoRedirect).open

    def request(self, method, path, body=None):
        if not path.startswith("/") or path.startswith("//"):
            raise RunnerError("invalid GitHub API path")
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.base + path, data=data, method=method, headers={
            "Authorization": "Bearer " + self.token, "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "Content-Type": "application/json"})
        try:
            with self.open(request, timeout=10) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
            raise RunnerError(f"GitHub {method} {path.split('?')[0]} failed (HTTP {status})", status=status) from None
        except (urllib.error.URLError, OSError, ValueError) as error:
            # Never print API bodies or credential-bearing request objects.
            raise RunnerError(f"GitHub {method} {path.split('?')[0]} failed ({type(error).__name__})") from None


def cancel_run(client, worker):
    """Return true only when a rejected cancellation is reconciled as already terminal."""
    try:
        client.request("POST", f"/actions/runs/{worker}/cancel")
    except RunnerError as error:
        if error.status != 409:
            raise
        run = client.request("GET", f"/actions/runs/{worker}")
        if (run.get("status") != "completed"
                or run.get("conclusion") not in ("success", "failure", "timed_out", "cancelled")):
            raise RunnerError("Self-hosted cancellation conflict is not a known terminal state") from None
        return True
    return False


def artifact_name(parent, attempt):
    return f"release-package-{parent}-{attempt}"


def validate_parent(client, parent, attempt, sha, build, plan, local=False, ref=None):
    run = client.request("GET", f"/actions/runs/{parent}")
    if (run.get("path", "").split("@", 1)[0] != ".github/workflows/release.yml"
            or run.get("event") not in ("push", "workflow_dispatch")
            or run.get("status") != "in_progress"
            or run.get("run_attempt") != attempt or run.get("head_sha") != sha
            or run.get("run_number") != build):
        raise RunnerError("parent Release attempt is not active or does not match the build")
    if local:
        if run.get("head_branch") != "nightly" or plan.get("channel") != "nightly":
            raise RunnerError("Self-hosted builds only Nightly releases")
        jobs = client.request("GET", f"/actions/runs/{parent}/jobs?filter=latest&per_page=100")["jobs"]
        if not any(job.get("name") == "Prefer Self-hosted for Nightly" and job.get("status") == "in_progress"
                   for job in jobs):
            raise RunnerError("parent has no active Self-hosted selection job")
    if plan.get("channel") == "nightly":
        expected_ref = release.NIGHTLY_BRANCH
        stamp = plan.get("tag", "").removeprefix("nightly-")
        if run.get("head_branch") != "nightly":
            raise RunnerError("Nightly source is not the nightly branch")
    else:
        expected_ref = "refs/tags/" + plan.get("tag", "")
        stamp = "200001010000"
    if ref is not None and ref != expected_ref:
        raise RunnerError("workflow ref is not the planned release ref")
    if release.plan(expected_ref, stamp) != plan or not plan.get("build"):
        raise RunnerError("build plan does not match the release rules")
    return run


def select_local(client, parent, attempt, sha, build, plan, output, clock=time.monotonic,
                 sleep=time.sleep, queue=QUEUE, execution=EXECUTION, cancel=CANCEL, interval=INTERVAL):
    """One dispatch, one local attempt, at most one hosted fallback. Unknown state fails closed."""
    validate_parent(client, parent, attempt, sha, build, plan, local=True)
    title = f"Self-hosted release {parent}-{attempt}"
    deadline = clock() + queue
    client.request("POST", f"/actions/workflows/{WORKFLOW}/dispatches", {
        "ref": "nightly", "inputs": {"parent_run": str(parent), "parent_attempt": str(attempt),
        "source_sha": sha, "build_number": str(build), "plan": json.dumps(plan, sort_keys=True)}})
    child = None
    completed = False
    started = None
    try:
        while child is None:
            runs = client.request("GET", f"/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=100")["workflow_runs"]
            matches = [r for r in runs if r.get("display_title") == title]
            if len(matches) > 1:
                raise RunnerError("ambiguous Self-hosted dispatch; no fallback")
            if matches:
                child = matches[0]["id"]
                output("worker_run", str(child))
                break
            if clock() >= deadline:
                raise RunnerError("Self-hosted dispatch not discovered; no fallback")
            sleep(min(interval, max(0, deadline - clock())))

        while True:
            run = client.request("GET", f"/actions/runs/{child}")
            if run.get("run_attempt") != 1:
                raise RunnerError("Self-hosted attempt was rerun; no fallback")
            jobs = client.request("GET", f"/actions/runs/{child}/jobs?filter=latest&per_page=100")["jobs"]
            job = next((j for j in jobs if j.get("name") == BUILD_JOB), None)
            if run.get("status") == "completed":
                completed = True
                if run.get("conclusion") == "success" and job and job.get("conclusion") == "success":
                    artifacts = client.request("GET", f"/actions/runs/{child}/artifacts?per_page=100")["artifacts"]
                    packages = [a for a in artifacts if a.get("name") == artifact_name(parent, attempt) and not a.get("expired")]
                    if len(packages) != 1:
                        raise RunnerError("successful Self-hosted build has no unique package; no fallback")
                    validate_parent(client, parent, attempt, sha, build, plan, local=True)
                    output("package_run", str(child))
                    output("fallback", "false")
                    return
                if (run.get("conclusion") not in ("failure", "timed_out")
                        or not job or job.get("conclusion") not in ("failure", "timed_out")):
                    raise RunnerError("Self-hosted was cancelled or failed before building; no fallback")
                break
            if job and job.get("status") == "in_progress" and started is None:
                started = clock()
            limit = deadline if started is None else started + execution
            if clock() >= limit:
                if cancel_run(client, child):
                    completed = True
                    continue  # Reconcile success/failure through the normal package/build guards.
                acknowledgement = clock() + cancel
                while True:
                    run = client.request("GET", f"/actions/runs/{child}")
                    if run.get("status") == "completed":
                        completed = True
                        break
                    if clock() >= acknowledgement:
                        raise RunnerError("Self-hosted cancellation not acknowledged; no fallback")
                    sleep(min(interval, max(0, acknowledgement - clock())))
                if run.get("conclusion") == "success":
                    continue  # Success raced cancellation: prefer its complete local package.
                if run.get("conclusion") not in ("cancelled", "failure", "timed_out"):
                    raise RunnerError("unexpected terminal Self-hosted state; no fallback")
                break
            sleep(min(interval, max(0, limit - clock())))
        validate_parent(client, parent, attempt, sha, build, plan, local=True)
        output("fallback", "true")
    finally:
        if child is not None and not completed:
            try:
                cancel_run(client, child)
            except RunnerError:
                pass  # Fail closed; a late queued worker also fences itself on its parent.


def manifest(directory, parent, attempt, sha, build, plan, verify=False):
    root = Path(directory)
    archive = root / plan["dmg"]
    if archive.name != plan["dmg"] or not archive.is_file():
        raise RunnerError("required release archive is missing")
    digest = hashlib.sha256()
    with archive.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    digest = digest.hexdigest()
    expected = {"parent_run": parent, "parent_attempt": attempt, "source_sha": sha,
                "build_number": build, "tag": plan["tag"], "version": plan["version"],
                "dmg": plan["dmg"], "sha256": digest}
    record = root / "release-package.json"
    policy = json.loads((root / "shepherd-appcast.json").read_text())
    if (type(policy.get("version")) is not int or policy["version"] != 1
            or policy.get("tag") != plan["tag"] or type(policy.get("eligible")) is not bool):
        raise RunnerError("invalid package eligibility metadata")
    if verify:
        if json.loads(record.read_text()) != expected:
            raise RunnerError("release package provenance or checksum mismatch")
    else:
        record.write_text(json.dumps(expected, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("select", "validate", "manifest", "verify", "cancel"))
    parser.add_argument("--local", action="store_true")
    parser.add_argument("--directory", default=".")
    args = parser.parse_args()
    env = os.environ
    def output(key, value):
        with open(env["GITHUB_OUTPUT"], "a") as file:
            file.write(f"{key}={value}\n")
    try:
        client = GitHub(env["GITHUB_REPOSITORY"], env.get("GH_TOKEN", ""))
        if args.command == "cancel":
            worker = env.get("WORKER_RUN", "")
            if worker:
                if not worker.isdigit():
                    raise RunnerError("invalid worker run")
                run = client.request("GET", f"/actions/runs/{worker}")
                if run.get("status") != "completed":
                    cancel_run(client, worker)
            return 0
        parent, attempt, build = (int(env[k]) for k in ("PARENT_RUN", "PARENT_ATTEMPT", "BUILD_NUMBER"))
        sha, plan = env["SOURCE_SHA"], json.loads(env["RELEASE_PLAN"])
        if not re.fullmatch(r"[0-9a-f]{40}", sha) or min(parent, attempt, build) < 1:
            raise RunnerError("invalid build identity")
        if args.command in ("manifest", "verify"):
            manifest(args.directory, parent, attempt, sha, build, plan, args.command == "verify")
        elif args.command == "validate":
            if args.local and (env.get("GITHUB_REF") != release.NIGHTLY_BRANCH
                               or env.get("GITHUB_RUN_ATTEMPT") != "1"):
                raise RunnerError("Self-hosted dispatch must be a first attempt on nightly")
            validate_parent(client, parent, attempt, sha, build, plan, args.local, env.get("GITHUB_REF"))
        else:
            select_local(client, parent, attempt, sha, build, plan, output)
        return 0
    except (RunnerError, ValueError, KeyError, OSError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

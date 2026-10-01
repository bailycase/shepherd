#!/usr/bin/env python3
"""Keep one tracking issue for the health of the full lane on nightly and master.

    ci_report.py --results results/ --result failure|success|cancelled

After a full-lane run on nightly, master, the daily schedule or a manual run, the report job
calls this with every shard's `failures.json` and `flaky.json` (scripts/ci_run_tests.py wrote
them). There is a single issue, labelled `ci-health`, found by title and reused for ever:

* a red run reopens it if it was closed and adds one comment per run: the commit, a link, and
  every failing test with its file and line;
* flaky tests (they failed, then passed on retry, or failed some passes of the daily flake hunt)
  are counted in a table in the issue's body, kept across runs in a hidden JSON block in that body;
* a green run after a red one adds one comment saying so. The issue is never closed from here:
  closing it is the person's decision, and the next red run reopens it.

The GitHub calls go through one function, so Tests/Release/test_ci_report.py runs the whole flow
against a fake. Standard library; the `gh` CLI does the talking, authenticated by GH_TOKEN.
"""
from __future__ import annotations

import argparse
import datetime
import glob
import json
import os
import subprocess
import sys

TITLE = "CI health: nightly failures and flaky tests"
LABEL = "ci-health"
STATE_OPEN, STATE_CLOSE = "<!-- ci-health-state", "-->"
MAX_FLAKY_ROWS = 40
MAX_COMMENT_FAILURES = 25


def gh(*args: str, stdin: str | None = None) -> str:
    done = subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])} failed: {done.stderr.strip()}")
    return done.stdout


def collect(results_dir: str) -> dict:
    """Every shard's failures, flaky tests and errors from the downloaded result artifacts."""
    out = {"failures": [], "flaky": [], "errors": []}
    for path in sorted(glob.glob(os.path.join(results_dir, "**", "failures.json"), recursive=True)):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        label = f"{data.get('kind', '')} {data.get('shard', '')}".strip()
        out["failures"] += [dict(t, where=label) for t in data.get("tests", [])]
        out["errors"] += [{"where": label, "message": e} for e in data.get("errors", [])]
    for path in sorted(glob.glob(os.path.join(results_dir, "**", "flaky.json"), recursive=True)):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        label = f"{data.get('kind', '')} {data.get('shard', '')}".strip()
        out["flaky"] += [dict(t, where=label) for t in data.get("tests", [])]
    return out


def parse_state(body: str) -> dict:
    start = body.find(STATE_OPEN)
    if start < 0:
        return fresh_state()
    end = body.find(STATE_CLOSE, start + len(STATE_OPEN))
    try:
        state = json.loads(body[start + len(STATE_OPEN):end])
    except ValueError:
        return fresh_state()
    for key, value in fresh_state().items():
        state.setdefault(key, value)
    return state


def fresh_state() -> dict:
    return {"flaky": {}, "last_red": None, "runs_seen": 0, "last_counted": ""}


def merge_flaky(state: dict, flaky: list[dict], run: str, today: str) -> dict:
    """Add one run's flaky tests to the running counts: how often each failed, in how many passes."""
    if state["last_counted"] != run:
        state["runs_seen"] += 1
        state["last_counted"] = run
    seen = state["flaky"]
    for item in flaky:
        entry = seen.setdefault(item["id"], {"failed": 0, "passes": 0, "runs": 0, "first": today,
                                              "file": item.get("file", ""), "line": item.get("line", 0), "message": ""})
        entry["failed"] += int(item.get("failed", 1))
        entry["passes"] += int(item.get("passes", 2))
        entry["runs"] += 1
        entry["last"], entry["last_run"] = today, run
        entry["message"] = item.get("message", "")[:200]
        entry["file"], entry["line"] = item.get("file", entry["file"]), item.get("line", entry["line"])
    return state


def render_body(state: dict, repo: str) -> str:
    lines = [
        "One issue tracks the health of the full test lane on `nightly` and `master`. It is updated by "
        "`scripts/ci_report.py` after every full-lane run there (a push, the daily run, a manual run); "
        "see the Testing docs. Close it when the lane is healthy; the next red run reopens it.",
        "",
    ]
    red = state.get("last_red")
    if red:
        lines += [f"**Last red run:** [{red['sha'][:8]}]({red['url']}) on `{red['ref']}`, {red['when']}: "
                  f"{red['failed']} failing test(s), {red['errors']} error(s).", ""]
    flaky = state["flaky"]
    if flaky:
        rows = sorted(flaky.items(), key=lambda kv: (-kv[1]["failed"], kv[0]))[:MAX_FLAKY_ROWS]
        lines += ["### Flaky tests", "",
                  "A test is flaky when it failed and then passed on retry or failed in some passes of the daily "
                  "three-pass run. Counts are over the runs recorded since this issue was opened; a test that is "
                  "flaky in nearly every run fails on its first attempt almost every time, which points at the test "
                  "(its order, its shared state) before the machine.", "",
                  "| Test | Failed / attempts | Flaky in runs | Last seen | Where | Last message |", "|---|--:|--:|---|---|---|"]
        for test_id, e in rows:
            where = f"{e['file']}:{e['line']}" if e.get("line") else e.get("file", "")
            lines.append(f"| `{test_id}` | {e['failed']} / {e['passes']} | {e['runs']} of {state['runs_seen']} | {e['last']} | {where} | "
                         f"{e['message'].replace('|', chr(92) + '|').replace(chr(10), ' ')} |")
        if len(flaky) > len(rows):
            lines.append(f"\n… and {len(flaky) - len(rows)} more in the state below.")
    else:
        lines += ["No flaky tests recorded yet."]
    lines += ["", f"{STATE_OPEN} {json.dumps(state, separators=(',', ':'), sort_keys=True)} {STATE_CLOSE}"]
    return "\n".join(lines) + "\n"


def render_red_comment(collected: dict, sha: str, ref: str, url: str, event: str) -> str:
    failures, errors = collected["failures"], collected["errors"]
    lines = [f"The full lane is **red** on `{ref}` at {sha[:8]} ({event}): [run]({url}).", ""]
    for e in errors:
        lines.append(f"- {e['where']}: {e['message']}")
    if failures:
        lines += ["", "| Test | Where | What |", "|---|---|---|"]
        for t in failures[:MAX_COMMENT_FAILURES]:
            where = f"{t['file']}:{t['line']}" if t.get("line") else t.get("file", "")
            lines.append(f"| `{t['id']}` | {where} | {t.get('message', '').replace('|', chr(92) + '|')} |")
        if len(failures) > MAX_COMMENT_FAILURES:
            lines.append(f"\n… and {len(failures) - MAX_COMMENT_FAILURES} more in the run's summary.")
    if not failures and not errors:
        lines.append("No failing test was recorded: a job failed before or after the tests. See the run.")
    lines.append(f"\n<!-- ci-health-run:{url.rsplit('/', 1)[-1]} -->")
    return "\n".join(lines) + "\n"


def find_issue(call=gh) -> dict | None:
    found = json.loads(call("issue", "list", "--label", LABEL, "--state", "all", "--limit", "20",
                            "--json", "number,state,title,body") or "[]")
    for issue in found:
        if issue["title"] == TITLE:
            return issue
    return None


def report(*, results: str, result: str, repo: str, run_id: str, sha: str, ref: str, event: str,
           server: str = "https://github.com", today: str | None = None, call=gh) -> list[str]:
    """Update the tracking issue for one run; returns what it did, for the log."""
    today = today or datetime.date.today().isoformat()
    did: list[str] = []
    if result == "cancelled":
        return ["the run was cancelled: nothing to report"]
    collected = collect(results)
    red = result != "success"
    issue = find_issue(call)
    if issue is None and not red and not collected["flaky"]:
        return ["green and nothing flaky: no issue needed"]
    url = f"{server}/{repo}/actions/runs/{run_id}"
    state = parse_state(issue["body"]) if issue else fresh_state()
    was_red = state.get("last_red") is not None and not state["last_red"].get("recovered")
    merge_flaky(state, collected["flaky"], run_id, today)
    if red:
        state["last_red"] = {"sha": sha, "ref": ref, "url": url, "when": today, "recovered": False,
                             "failed": len(collected["failures"]), "errors": len(collected["errors"])}
    elif was_red and state["last_red"]["ref"] == ref:
        state["last_red"]["recovered"] = True
    body = render_body(state, repo)
    if issue is None:
        call("label", "create", LABEL, "--color", "d93f0b", "--description", "CI health tracking", "--force")
        out = call("issue", "create", "--title", TITLE, "--label", LABEL, "--body-file", "-", stdin=body)
        number = out.strip().rsplit("/", 1)[-1]
        did.append(f"created issue #{number}")
        issue = {"number": int(number), "state": "OPEN"}
    else:
        call("issue", "edit", str(issue["number"]), "--body-file", "-", stdin=body)
        did.append(f"updated the body of #{issue['number']}")
        if red and issue["state"].upper() == "CLOSED":
            call("issue", "reopen", str(issue["number"]))
            did.append(f"reopened #{issue['number']}")
    number = str(issue["number"])
    if red:
        existing = call("issue", "view", number, "--json", "comments", "--jq", ".comments[].body")
        if f"ci-health-run:{run_id}" not in existing:
            call("issue", "comment", number, "--body-file", "-", stdin=render_red_comment(collected, sha, ref, url, event))
            did.append(f"commented the red run on #{number}")
    elif was_red and issue.get("state", "OPEN").upper() == "OPEN":
        call("issue", "comment", number, "--body-file", "-",
             stdin=f"The full lane is **green** again on `{ref}` at {sha[:8]}: [run]({url}). "
                   "Close this issue when the failures above are dealt with.\n")
        did.append(f"commented the recovery on #{number}")
    return did


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--results", required=True, help="the downloaded ci-results-* artifacts")
    parser.add_argument("--result", required=True, choices=("success", "failure", "cancelled"))
    parser.add_argument("--sha", default="", help="the commit tested (the scheduled run tests nightly, not master)")
    parser.add_argument("--ref", default="", help="the branch tested")
    args = parser.parse_args(argv)
    env = os.environ
    for line in report(
        results=args.results, result=args.result, repo=env["GITHUB_REPOSITORY"], run_id=env["GITHUB_RUN_ID"],
        sha=args.sha or env["GITHUB_SHA"], ref=args.ref or env.get("GITHUB_REF_NAME", ""),
        event=env.get("GITHUB_EVENT_NAME", ""), server=env.get("GITHUB_SERVER_URL", "https://github.com"),
    ):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

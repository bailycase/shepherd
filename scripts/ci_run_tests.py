#!/usr/bin/env python3
"""Run one shard of the Swift tests, or the node extension tests, the way CI needs them run.

    ci_run_tests.py swift --shard 2/4 --selection '{"all":true}' [--repeat 1] [--out ci-out]
    ci_run_tests.py node [--out ci-out]

For Swift it lists the tests, cuts the selected suites into shards (scripts/ci_shards.py),
checks the cut is a partition, runs this shard's suites serially under a watchdog, and then:

* a run that passes must have run exactly the tests the shard was given;
* a run with a few failing tests, every one of them found in the list, with every issue the
  summary counts accounted for, is retried once, only those tests. A test that passes the
  second time is flaky: a warning, a table in the step summary and an entry in flaky.json. One
  that fails again fails the shard. A build failure, a crash, a hung run, an unattributed
  issue or more than MAX_RETRY failing tests is not a flake and is never retried;
* with `--repeat N` (the daily flake hunt) the whole shard runs N times instead, and a test that
  fails some passes and passes others is recorded as flaky.

The outputs go in `--out`: the logs, `failures.json`, `flaky.json`, `suite-times.json`, and the
step summary and annotations on the Actions page. Standard library only; the logic is tested in
Tests/Release/test_ci_run_tests.py.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ci_shards  # noqa: E402
import ci_testlog as tl  # noqa: E402

# A failing run with more failing tests than this is not a flake: something broke.
MAX_RETRY = 8
# The watchdog ends a run after this many times the shard's recorded seconds, and never sooner than MIN_BUDGET.
BUDGET_FACTOR = 2.5
MIN_BUDGET = 8 * 60
HOST_MARKERS = ("swiftpm-testing", "xctest")
TEST_ID = re.compile(r"^\w+\.\w+/\S")


@dataclass
class Result:
    """What one run of `swift test` (or node) came to."""

    status: str                      # "pass", "fail" or "error"
    tests: int = 0
    failures: list[tl.Failure] = field(default_factory=list)
    unresolved: list[tl.Failure] = field(default_factory=list)
    error: str = ""
    retryable: bool = False


class Runner:
    """Starts processes. Tests replace it with one that writes canned logs."""

    def capture(self, cmd: list[str], env: dict[str, str] | None = None) -> tuple[int, str]:
        proc = subprocess.run(cmd, capture_output=True, encoding="utf-8", errors="replace", env=env)
        return proc.returncode, proc.stdout

    def stream(self, cmd: list[str], log_path: str, budget: float, env: dict[str, str] | None = None) -> tuple[int, bool]:
        """Run `cmd`, copying its output to stdout and `log_path`. Returns (exit code, watchdog fired)."""
        with open(log_path, "w", encoding="utf-8", errors="replace") as log:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding="utf-8", errors="replace",
                bufsize=1, env=env, start_new_session=True,
            )

            def pump() -> None:
                assert proc.stdout is not None
                for line in proc.stdout:
                    log.write(line)
                    sys.stdout.write(line)
                    sys.stdout.flush()

            reader = threading.Thread(target=pump, daemon=True)
            reader.start()
            fired = False
            try:
                proc.wait(timeout=budget)
            except subprocess.TimeoutExpired:
                fired = True
                self.sample_hung_hosts(proc.pid)
                kill_group(proc.pid)
                proc.wait()
            except BaseException:
                # The runner cancelling the job (SIGINT, or SIGTERM turned into an exit): the tests
                # run in a session of their own, so nothing else would stop them.
                kill_group(proc.pid)
                raise
            reader.join(timeout=10)
            if proc.stdout is not None:
                proc.stdout.close()
            return proc.returncode, fired

    def sample_hung_hosts(self, root: int) -> None:
        """A test host still running when the budget ends: print what its threads were doing."""
        print("::group::watchdog: test run stalled, sampling processes", flush=True)
        _code, table = self.capture(["ps", "-axo", "pid=,ppid=,command="])
        for pid, command in descendants(table, root):
            print(pid, command, flush=True)
            if any(m in command for m in HOST_MARKERS):
                path = f"/tmp/sample-{pid}.txt"
                self.capture(["sample", str(pid), "3", "-file", path])
                try:
                    with open(path, encoding="utf-8", errors="replace") as f:
                        print(f.read(), flush=True)
                except OSError:
                    pass
        print("::endgroup::", flush=True)


def kill_group(pid: int) -> None:
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def descendants(ps_table: str, root: int) -> list[tuple[int, str]]:
    """(pid, command) of every process under `root` in `ps -axo pid=,ppid=,command=` output."""
    children: dict[int, list[tuple[int, str]]] = {}
    for line in ps_table.splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
            children.setdefault(int(parts[1]), []).append((int(parts[0]), parts[2] if len(parts) > 2 else ""))
    found: list[tuple[int, str]] = []
    stack = [root]
    while stack:
        for pid, command in children.get(stack.pop(), []):
            found.append((pid, command))
            stack.append(pid)
    return found


def budget_for(group: list[str], times: dict[str, float], passes: int = 1) -> float:
    return max(MIN_BUDGET, BUDGET_FACTOR * ci_shards.shard_seconds(group, times)) * passes


def parse_shard(text: str) -> tuple[int, int]:
    index, _, count = text.partition("/")
    i, n = int(index), int(count)
    if not 1 <= i <= n:
        raise ValueError(f"shard {text!r} is not i/n with 1 <= i <= n")
    return i, n


def evaluate(parsed: tl.Parsed, exit_code: int, timed_out: bool, expected: int | None, ids: list[str],
             root: str, retry_allowed: bool) -> Result:
    """Classify one run from its parsed log."""
    summary = parsed.summary
    if timed_out:
        return Result("error", error="the watchdog ended a run that stopped making progress")
    if summary is None:
        return Result("error", error=f"the run ended (exit {exit_code}) without a summary line: it crashed or was killed")
    if expected is not None and summary.tests != expected:
        return Result("error", tests=summary.tests,
                      error=f"the shard ran {summary.tests} tests but was given {expected}: its filters do not match the list")
    if exit_code == 0:
        if summary.tests == 0:
            return Result("error", error="the shard ran no tests: its filters matched nothing")
        return Result("pass", tests=summary.tests)
    if summary.passed:
        return Result("error", tests=summary.tests, error=f"every test passed but swift test exited {exit_code}")
    resolved, unresolved = tl.resolve_ids(parsed.failures, ids, root)
    unique: dict[str, tl.Failure] = {}
    for failure in resolved:
        first = unique.setdefault(failure.id, failure)
        if first is not failure:
            first.count += failure.count
    attributed = sum(f.count for f in unique.values())
    clean = bool(unique) and attributed == summary.unexpected
    result = Result("fail", tests=summary.tests, failures=list(unique.values()), unresolved=unresolved)
    result.retryable = retry_allowed and clean and len(unique) <= MAX_RETRY
    if not clean:
        result.error = (f"{summary.unexpected} issues failed the run but {attributed} are attributed to tests in "
                        f"the list; nothing is retried")
    elif len(unique) > MAX_RETRY:
        result.error = f"{len(unique)} tests failed (more than {MAX_RETRY}): not a flake, nothing is retried"
    return result


def swift_command(flags: list[str], filter_args: list[str], skip_build: bool = True) -> list[str]:
    cmd = ["swift", "test"]
    if skip_build:
        cmd.append("--skip-build")
    cmd += flags + ["--no-parallel"]
    for f in filter_args:
        cmd += ["--filter", f]
    return cmd


def list_tests(flags: list[str], runner: Runner) -> list[str]:
    code, out = runner.capture(["swift", "test", "list", "--skip-build"] + flags)
    if code != 0:
        raise RuntimeError(f"swift test list failed (exit {code})")
    return [line.strip() for line in out.splitlines() if TEST_ID.match(line.strip())]


@dataclass
class Outcome:
    exit_code: int
    failures: list[tl.Failure] = field(default_factory=list)
    flaky: list[tuple[tl.Failure, int, int]] = field(default_factory=list)   # (failure, failed passes, passes)
    errors: list[str] = field(default_factory=list)
    suite_times: dict[str, float] = field(default_factory=dict)
    info: dict = field(default_factory=dict)
    elapsed: float = 0.0


@dataclass
class ShardPlan:
    flags: list[str]
    ids: list[str]
    mine: list[str]
    expected: int
    filter_args: list[str]
    budget: float
    names: dict[str, list[str]]
    info: dict


def prepare(args, env: dict[str, str], runner: Runner) -> ShardPlan | Outcome:
    """List the tests, choose and cut the suites, and say what this shard runs."""
    index, count = parse_shard(args.shard)
    flags = shlex.split(env.get("SWIFTPM_FLAGS", ""))
    times = ci_shards.read_times(args.times)
    ids = list_tests(flags, runner)
    with open(os.path.join(args.out, "tests.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(ids) + "\n")
    suites = ci_shards.suites_of(ids)
    chosen = ci_shards.select(list(suites), json.loads(args.selection))
    if not chosen:
        return Outcome(1, errors=["the selection matches no suite in `swift test list`"])
    groups = ci_shards.assign(chosen, times, count)
    ci_shards.check_partition(groups, chosen)
    mine = groups[index - 1]
    if not mine:
        return Outcome(1, errors=[f"shard {args.shard} was given no suites ({len(chosen)} suites, {count} shards)"])
    expected = sum(suites[s] for s in mine)
    info = {"suites": len(mine), "chosen": len(chosen), "tests": expected,
            "new": sorted(s for s in mine if s not in times),
            "seconds": ci_shards.shard_seconds(mine, times), "budget": budget_for(mine, times, args.repeat)}
    print(f"shard {args.shard}: {len(mine)} of {len(chosen)} selected suites, {expected} tests, about "
          f"{info['seconds']:.0f} s; {len(info['new'])} not in the times file", flush=True)
    return ShardPlan(flags, ids, mine, expected, ci_shards.filters(mine), info["budget"],
                     tl.suite_names(args.root), info)


def read_log(path: str) -> tl.Parsed:
    with open(path, encoding="utf-8", errors="replace") as f:
        return tl.parse_swift_log(f.read())


def timed(plan: ShardPlan, parsed: tl.Parsed, result: Result) -> dict[str, float]:
    """Suite seconds from a run, leaving out the suites of tests that failed."""
    failed = {tl.suite_of(f.id) for f in result.failures}
    seen = tl.attribute_suite_times(parsed.suite_times, plan.ids, plan.names)
    return {s: t for s, t in seen.items() if s in plan.mine and s not in failed}


def run_swift(args, env: dict[str, str], runner: Runner) -> Outcome:
    os.makedirs(args.out, exist_ok=True)
    plan = prepare(args, env, runner)
    if isinstance(plan, Outcome):
        return plan
    started = time.time()
    outcome = run_repeated(args, plan, runner) if args.repeat > 1 else run_with_retry(args, plan, runner)
    outcome.info, outcome.elapsed = plan.info, time.time() - started
    return outcome


def run_with_retry(args, plan: ShardPlan, runner: Runner) -> Outcome:
    """One pass; if a few tests failed, a second pass of just those."""
    log_path = os.path.join(args.out, "swift-test.log")
    code, fired = runner.stream(swift_command(plan.flags, plan.filter_args), log_path, plan.budget, None)
    parsed = read_log(log_path)
    result = evaluate(parsed, code, fired, plan.expected, plan.ids, args.root, retry_allowed=True)
    outcome = Outcome(0 if result.status == "pass" else 1)
    if result.status == "error":
        outcome.errors.append(result.error)
        return outcome
    outcome.suite_times = timed(plan, parsed, result)
    if result.status == "pass":
        return outcome
    outcome.failures = result.failures
    if result.error:
        outcome.errors.append(result.error)
    if not result.retryable:
        return outcome

    retry_ids = [f.id for f in result.failures]
    print(f"::warning::{len(retry_ids)} failing test(s) will be retried once", flush=True)
    retry_log = os.path.join(args.out, "swift-test-retry.log")
    code2, fired2 = runner.stream(swift_command(plan.flags, [tl.filter_for_test(i) for i in retry_ids]),
                                  retry_log, max(MIN_BUDGET, plan.budget / 2), None)
    second = evaluate(read_log(retry_log), code2, fired2, None, plan.ids, args.root, retry_allowed=False)
    if second.status == "pass":
        outcome.exit_code, outcome.failures, outcome.errors = 0, [], []
        outcome.flaky = [(f, 1, 2) for f in result.failures]
    elif second.status == "fail" and second.error == "":
        again = {f.id for f in second.failures}
        outcome.failures = [f for f in result.failures if f.id in again]
        outcome.flaky = [(f, 1, 2) for f in result.failures if f.id not in again]
        outcome.errors = []
    else:
        outcome.errors.append(f"the retry did not finish cleanly: {second.error}")
    return outcome


def run_repeated(args, plan: ShardPlan, runner: Runner) -> Outcome:
    """The flake hunt: the whole shard `--repeat` times. A test that fails in every pass is a failure,
    one that fails in some is flaky; a pass that errors, or leaves failures unattributed, fails the shard."""
    outcome = Outcome(0)
    failed_in: dict[str, tuple[tl.Failure, int]] = {}
    per_pass = plan.budget / args.repeat
    for n in range(1, args.repeat + 1):
        log_path = os.path.join(args.out, f"swift-test-pass{n}.log")
        code, fired = runner.stream(swift_command(plan.flags, plan.filter_args), log_path, per_pass, None)
        parsed = read_log(log_path)
        result = evaluate(parsed, code, fired, plan.expected, plan.ids, args.root, retry_allowed=False)
        if result.status == "error" or (result.status == "fail" and result.error):
            outcome.exit_code = 1
            outcome.errors.append(f"pass {n}: {result.error}")
        if result.status != "error" and not outcome.suite_times:
            outcome.suite_times = timed(plan, parsed, result)
        for failure in result.failures:
            old = failed_in.get(failure.id)
            failed_in[failure.id] = (old[0] if old else failure, (old[1] if old else 0) + 1)
    for failure, failed in failed_in.values():
        if failed == args.repeat:
            outcome.failures.append(failure)
            outcome.exit_code = 1
        else:
            outcome.flaky.append((failure, failed, args.repeat))
    return outcome


def run_node(args, env: dict[str, str], runner: Runner) -> Outcome:
    os.makedirs(args.out, exist_ok=True)
    files = sorted(glob.glob(os.path.join(args.root, "Tests", "Extensions", "*.test.mjs")))
    if not files:
        return Outcome(1, errors=["no Tests/Extensions/*.test.mjs files"])
    base = ["node", "--test", "--test-reporter=spec"]
    log_path = os.path.join(args.out, "node-test.log")
    code, fired = runner.stream(base + files, log_path, 15 * 60, None)
    with open(log_path, encoding="utf-8", errors="replace") as f:
        counts, failures = tl.parse_node_log(f.read())
    outcome = Outcome(0)
    if fired:
        outcome.exit_code = 1
        outcome.errors.append("the watchdog ended a run that stopped making progress")
    elif code == 0:
        if counts.get("tests", 0) == 0:
            outcome.exit_code = 1
            outcome.errors.append("node ran no tests")
    elif not failures or counts.get("fail", 0) != len(failures) or len(failures) > MAX_RETRY:
        outcome.exit_code = 1
        outcome.failures = failures
        outcome.errors.append(f"node exited {code} with {len(failures)} parsed failures of {counts.get('fail', '?')}: not retried")
    else:
        retry_files = sorted({f.file for f in failures})
        pattern = tl.js_pattern([f.name for f in failures])
        retry_log = os.path.join(args.out, "node-test-retry.log")
        code2, fired2 = runner.stream(base + [f"--test-name-pattern={pattern}"] + retry_files, retry_log, 10 * 60, None)
        with open(retry_log, encoding="utf-8", errors="replace") as f:
            counts2, failures2 = tl.parse_node_log(f.read())
        if code2 == 0 and not fired2 and counts2.get("pass", 0) >= 1:
            outcome.flaky = [(f, 1, 2) for f in failures]
        else:
            again = {f.name for f in failures2}
            outcome.exit_code = 1
            outcome.failures = failures2 or failures
            outcome.flaky = [(f, 1, 2) for f in failures if f.name not in again] if failures2 else []
            outcome.errors.append("a failing test failed again on retry")
    return outcome


# ---- reporting ----------------------------------------------------------------------------------

def report(args, outcome: Outcome, kind: str, files_index: dict[str, list[str]]) -> str:
    """Print annotations, write the JSON files and return the step summary."""
    title_kind = "node extension tests" if kind == "node" else f"Swift tests, shard {args.shard}"
    for failure in outcome.failures:
        print(tl.annotation("error", f"{failure.id or failure.name}: {tl.first_line(failure.message, 400) or 'failed'}",
                            tl.repo_path(failure, files_index), failure.line, failure.col, "Test failed"), flush=True)
    for failure, failed, passes in outcome.flaky:
        what = "failed, then passed on retry" if passes == 2 and args.repeat == 1 else f"failed {failed} of {passes} passes"
        print(tl.annotation("warning", f"{failure.id or failure.name} {what}: {tl.first_line(failure.message, 300)}",
                            tl.repo_path(failure, files_index), failure.line, failure.col, "Flaky test"), flush=True)
    for error in outcome.errors:
        print(tl.annotation("error", error, title=title_kind), flush=True)

    def entry(f: tl.Failure, **extra):
        return {"id": f.id or f.name, "file": tl.repo_path(f, files_index), "line": f.line,
                "message": tl.first_line(f.message, 400), **extra}

    context = {k: os.environ.get(v, "") for k, v in
               (("run", "GITHUB_RUN_ID"), ("sha", "GITHUB_SHA"), ("ref", "GITHUB_REF_NAME"), ("repository", "GITHUB_REPOSITORY"))}
    context.update(kind=kind, shard=getattr(args, "shard", ""), lane=getattr(args, "lane", ""))
    with open(os.path.join(args.out, "failures.json"), "w", encoding="utf-8") as f:
        json.dump({**context, "tests": [entry(x) for x in outcome.failures], "errors": outcome.errors}, f, indent=1)
    with open(os.path.join(args.out, "flaky.json"), "w", encoding="utf-8") as f:
        json.dump({**context, "tests": [entry(x, failed=a, passes=b) for x, a, b in outcome.flaky]}, f, indent=1)
    with open(os.path.join(args.out, "suite-times.json"), "w", encoding="utf-8") as f:
        json.dump({**context, "suites": {k: round(v, 3) for k, v in sorted(outcome.suite_times.items())}}, f, indent=1)

    verdict = "passed" if outcome.exit_code == 0 else "FAILED"
    lines = [f"### {title_kind}: {verdict}"]
    info = outcome.info
    if info:
        lines.append(f"{info['tests']} tests in {info['suites']} suites (of {info['chosen']} selected), "
                     f"{info['seconds']:.0f} s expected, watchdog at {info['budget'] / 60:.0f} min"
                     + (f", {outcome.elapsed / 60:.1f} min taken" if outcome.elapsed else "") + ".")
        if info["new"]:
            lines.append(f"{len(info['new'])} suites are not in `Tests/ci-suite-times.json` and went to the lightest shard: "
                         + ", ".join(f"`{s}`" for s in info["new"][:10]) + (" …" if len(info["new"]) > 10 else "")
                         + ". Regenerate it (docs/testing.md).")
    for error in outcome.errors:
        lines.append(f"**{error}**")
    if outcome.failures:
        lines += ["", "**Failed tests**", "", tl.failures_table(outcome.failures, files_index)]
    if outcome.flaky:
        lines += ["", "**Flaky: failed, then passed**" if args.repeat == 1 else "**Flaky: failed in some passes**", "",
                  "| Test | Where | What | Failed |", "|---|---|---|---|"]
        for f, failed, passes in outcome.flaky:
            where = tl.repo_path(f, files_index) + (f":{f.line}" if f.line else "")
            lines.append(f"| `{tl.markdown_cell(f.id or f.name)}` | {tl.markdown_cell(where)} | "
                         f"{tl.markdown_cell(tl.first_line(f.message))} | {failed} of {passes} |")
    if outcome.suite_times:
        slow = sorted(outcome.suite_times.items(), key=lambda kv: -kv[1])
        lines += ["", "<details><summary>Suites by time</summary>", "", "| Suite | Seconds |", "|---|--:|"]
        lines += [f"| {s} | {t:.1f} |" for s, t in slow]
        lines += ["", "</details>"]
    text = "\n".join(lines) + "\n"
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target:
        with open(target, "a", encoding="utf-8") as f:
            f.write(text)
    return text


def main(argv: list[str], runner: Runner | None = None, env: dict[str, str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="kind", required=True)
    for name in ("swift", "node"):
        p = sub.add_parser(name)
        p.add_argument("--out", default="ci-out")
        p.add_argument("--root", default=".")
        p.add_argument("--lane", default="")
        if name == "swift":
            p.add_argument("--shard", required=True, help="i/n")
            p.add_argument("--selection", default='{"all":true}')
            p.add_argument("--repeat", type=int, default=1)
            p.add_argument("--times", default=ci_shards.DEFAULT_TIMES)
        else:
            p.set_defaults(repeat=1, shard="")
    args = parser.parse_args(argv)
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")   # a C locale would otherwise choke on ✘
    runner = runner or Runner()
    env = dict(os.environ if env is None else env)
    outcome = run_swift(args, env, runner) if args.kind == "swift" else run_node(args, env, runner)
    os.makedirs(args.out, exist_ok=True)
    report(args, outcome, args.kind, tl.index_test_files(args.root))
    return outcome.exit_code


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda _signum, _frame: sys.exit(143))
    sys.exit(main(sys.argv[1:]))

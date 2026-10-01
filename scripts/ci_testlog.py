#!/usr/bin/env python3
"""Read what a test run printed: which tests failed and where, and how long each suite took.

Library for scripts/ci_run_tests.py (Swift Testing's console output and node's spec reporter)
and for Tests/Release, which runs it against logs CI really produced. Standard library only.

Swift Testing prints one line per event, led by a symbol: `✘ Test name recorded an issue at
File.swift:12:5: message`, `✘ Test name failed after 0.5 seconds with 1 issue.`, `✔ Suite "Name"
passed after 1.2 seconds.`, and last of all `✘ Test run with 40 tests in 6 suites failed after 9
seconds with 2 issues.`. A test that quotes such lines in its own output can print them at the start
of a line too, so a failure is only believed when a test of that name exists in `swift test list`.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass, field

FAIL = "✘"
SYMBOLS = "✔✘━◇↳⚠"

ISSUE = re.compile(
    r"^✘ Test (?P<name>.+?) recorded an issue(?: with \d+ arguments? .*?)? "
    r"at (?P<file>[^\s:]+\.swift):(?P<line>\d+):(?P<col>\d+): (?P<message>.*)$"
)
ISSUE_NO_LOCATION = re.compile(r"^✘ Test (?P<name>.+?) recorded an issue(?: with \d+ arguments? [^:]*)?: (?P<message>.*)$")
TEST_FAILED = re.compile(
    r"^✘ Test (?P<name>.+?)(?: with \d+ test cases?)? failed after (?P<seconds>[0-9.]+) seconds?"
    r"(?: with (?P<issues>\d+) issues?)?"
)
SUITE_DONE = re.compile(
    r'^[✔✘━] Suite (?:"(?P<quoted>.+)"|(?P<bare>\S+)) (?P<result>passed|failed) after (?P<seconds>[0-9.]+) seconds?'
)
RUN_DONE = re.compile(
    r"^[✔✘━] Test run with (?P<tests>\d+) tests?(?: in (?P<suites>\d+) suites?)? (?P<result>passed|failed) "
    r"after (?P<seconds>[0-9.]+) seconds?"
    r"(?: with (?:(?P<issues>\d+) issues?(?: \(including (?P<known>\d+) known issues?\))?|(?P<only_known>\d+) known issues?))?"
    r"\.?\s*$"
)
TYPE_DECL = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?[ \t]+)*(?:(?:final|public|private|fileprivate|internal)[ \t]+)*"
    r"(?:struct|class|enum|actor)[ \t]+(?P<name>\w+)",
    re.M,
)


@dataclass
class Failure:
    """One failing test: where it failed, with the first expectation or error that said so."""

    name: str
    file: str = ""
    line: int = 0
    col: int = 0
    message: str = ""
    id: str = ""
    count: int = 0


@dataclass
class RunSummary:
    tests: int
    suites: int
    passed: bool
    seconds: float
    issues: int = 0
    known: int = 0

    @property
    def unexpected(self) -> int:
        """Issues that are not known issues: the ones that fail the run."""
        return self.issues - self.known


@dataclass
class Parsed:
    """What one swift-testing console log holds."""

    summary: RunSummary | None = None
    failures: list[Failure] = field(default_factory=list)
    suite_times: list[tuple[str, float, bool]] = field(default_factory=list)
    failed_suites: list[str] = field(default_factory=list)


def parse_swift_log(text: str) -> Parsed:
    """The run's summary line, its failing tests (in order of first failure) and its suite times."""
    out = Parsed()
    by_key: dict[tuple[str, str, int], Failure] = {}
    last_issue: Failure | None = None
    for raw in text.splitlines():
        line = raw.rstrip("\r")
        if line.startswith("↳") and last_issue is not None:
            detail = line[1:].strip()
            if detail and len(last_issue.message) < 600:
                last_issue.message += "\n" + detail
            continue
        if line[:1] in SYMBOLS:
            last_issue = None
        if not line.startswith(("✔", "✘", "━")):
            continue
        m = RUN_DONE.match(line)
        if m:
            out.summary = RunSummary(
                tests=int(m["tests"]), suites=int(m["suites"] or 0), passed=m["result"] == "passed",
                seconds=float(m["seconds"]), issues=int(m["issues"] or m["only_known"] or 0),
                known=int(m["known"] or m["only_known"] or 0),
            )
            continue
        m = SUITE_DONE.match(line)
        if m:
            name = m["quoted"] or m["bare"]
            out.suite_times.append((name, float(m["seconds"]), m["result"] == "passed"))
            if m["result"] == "failed":
                out.failed_suites.append(name)
            continue
        m = ISSUE.match(line)
        if m:
            key = (m["name"], m["file"], int(m["line"]))
            if key not in by_key:
                by_key[key] = Failure(m["name"], m["file"], int(m["line"]), int(m["col"]), m["message"])
                out.failures.append(by_key[key])
            by_key[key].count += 1
            last_issue = by_key[key]
            continue
        m = ISSUE_NO_LOCATION.match(line)
        if m:
            key = (m["name"], "", 0)
            if key not in by_key:
                by_key[key] = Failure(m["name"], message=m["message"])
                out.failures.append(by_key[key])
            by_key[key].count += 1
            last_issue = by_key[key]
            continue
        m = TEST_FAILED.match(line)
        if m and not any(f.name == m["name"] for f in out.failures):
            out.failures.append(Failure(m["name"], message="failed without a recorded issue", count=int(m["issues"] or 1)))
    return out


def suite_of(test_id: str) -> str:
    """`Module.Suite` of `Module.Suite/test()`, the unit shards and the impact map work in."""
    return test_id.split("/", 1)[0]


def types_declared_in(path: str) -> set[str]:
    """Type names a Swift file declares at its top level: the suites a test file can hold."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return {m["name"] for m in TYPE_DECL.finditer(f.read())}
    except OSError:
        return set()


def index_test_files(root: str) -> dict[str, list[str]]:
    """Basename to the paths (relative to `root`) of every Swift file under Tests/."""
    found: dict[str, list[str]] = {}
    tests = os.path.join(root, "Tests")
    for folder, _dirs, files in os.walk(tests):
        for name in sorted(files):
            if name.endswith(".swift"):
                found.setdefault(name, []).append(os.path.relpath(os.path.join(folder, name), root))
    return found


def resolve_ids(failures: list[Failure], ids: list[str], root: str = ".") -> tuple[list[Failure], list[Failure]]:
    """Give each failure the id of the test it names, `Module.Suite/name`.

    Returns (resolved, unresolved). A failure that names a test `swift test list` doesn't
    have (a line some test printed) or a test with a custom display name is unresolved. A name
    several suites share is narrowed by the failing file's module, then by the types that file
    declares; what is still ambiguous resolves to its first candidate (the same function in a
    sibling suite is not retried).
    """
    files = index_test_files(root)
    by_name: dict[str, list[str]] = {}
    for test_id in ids:
        by_name.setdefault(test_id.split("/", 1)[1] if "/" in test_id else test_id, []).append(test_id)
    resolved: list[Failure] = []
    unresolved: list[Failure] = []
    for failure in failures:
        candidates = by_name.get(failure.name, [])
        base = os.path.basename(failure.file)
        if len(candidates) > 1 and base in files:
            modules = {p.split(os.sep)[1] for p in files[base]}
            narrowed = [c for c in candidates if c.split(".", 1)[0] in modules]
            candidates = narrowed or candidates
            if len(candidates) > 1:
                declared: set[str] = set()
                for p in files[base]:
                    declared |= types_declared_in(os.path.join(root, p))
                narrowed = [c for c in candidates if suite_of(c).split(".", 1)[1] in declared]
                candidates = narrowed or candidates
        if candidates:
            failure.id = sorted(candidates)[0]
            resolved.append(failure)
        else:
            unresolved.append(failure)
    return resolved, unresolved


def filter_for_test(test_id: str) -> str:
    """A `--filter` regex that selects exactly one test: the id up to its parameter list.

    Swift Testing matches the filter against ids that carry a source location after the
    closing parenthesis, so the pattern is anchored at the start and not at the end.
    """
    return "^" + re.escape(test_id)


def suite_names(root: str) -> dict[str, list[str]]:
    """Console name of each suite under Tests/, from its `@Suite("name")` (else its type name).

    Keys are `Module.Type`; the module is the folder under Tests/. A type with `@Test`
    methods and no `@Suite` is a suite too, and the console prints its type name.
    """
    names: dict[str, list[str]] = {}
    tests = os.path.join(root, "Tests")
    for folder, _dirs, files in os.walk(tests):
        for fname in sorted(files):
            if not fname.endswith(".swift"):
                continue
            path = os.path.join(folder, fname)
            module = os.path.relpath(path, tests).split(os.sep)[0]
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
            for m in re.finditer(r"@Suite\b", text):
                display, end = _suite_args(text, m.end())
                decl = TYPE_DECL.search(text, end) or re.compile(
                    r"(?:struct|class|enum|actor)[ \t]+(?P<name>\w+)").search(text, end)
                if decl:
                    names.setdefault(f"{module}.{decl['name']}", []).append(display or decl["name"])
            for m in TYPE_DECL.finditer(text):
                sid = f"{module}.{m['name']}"
                if sid not in names and "@Test" in text[m.end():m.end() + 200000]:
                    names[sid] = [m["name"]]
    return names


def _suite_args(text: str, start: int) -> tuple[str, int]:
    """The display name in `@Suite("name", …)` at `start`, and where the attribute ends."""
    i = start
    while i < len(text) and text[i] in " \t":
        i += 1
    if i >= len(text) or text[i] != "(":
        return "", start
    depth, j, in_str, esc = 0, i, False, False
    while j < len(text):
        c = text[j]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                break
        j += 1
    m = re.match(r'\s*"((?:[^"\\]|\\.)*)"', text[i + 1:j])
    return (m.group(1).replace('\\"', '"') if m else ""), j + 1


def attribute_suite_times(
    observed: list[tuple[str, float, bool]], ids: list[str], names: dict[str, list[str]]
) -> dict[str, float]:
    """Suite id to seconds, from the console's `(display name, seconds)` lines.

    Two suites can share a display name. Their observed times go to them slowest first,
    integration suites (more tests, then name) before unit ones, which is right in practice
    because the unit tier is the fast one.
    """
    counts: dict[str, int] = {}
    for test_id in ids:
        counts[suite_of(test_id)] = counts.get(suite_of(test_id), 0) + 1
    by_display: dict[str, list[str]] = {}
    for sid in counts:
        for display in names.get(sid) or [sid.split(".", 1)[1]]:
            by_display.setdefault(display, []).append(sid)
    grouped: dict[str, list[float]] = {}
    for display, seconds, _passed in observed:
        grouped.setdefault(display, []).append(seconds)
    times: dict[str, float] = {}
    for display, seconds in grouped.items():
        candidates = by_display.get(display, [])
        ranked = sorted(candidates, key=lambda c: ("UnitTests" in c, -counts[c], c))
        for sid, secs in zip(ranked, sorted(seconds, reverse=True)):
            times[sid] = secs
    return times


# ---- node's spec reporter -------------------------------------------------------------

NODE_FAILED_HEADER = "✖ failing tests:"
NODE_AT = re.compile(r"^test at (?P<file>\S+?):(?P<line>\d+):(?P<col>\d+)\s*$")
NODE_FAIL = re.compile(r"^✖ (?P<name>.+?) \((?P<ms>[0-9.]+)ms\)\s*$")
NODE_COUNT = re.compile(r"^ℹ (?P<key>tests|pass|fail|cancelled|skipped) (?P<n>\d+)\s*$")


def parse_node_log(text: str) -> tuple[dict[str, int], list[Failure]]:
    """node --test's counts and its failing tests, from the spec reporter's closing summary."""
    counts: dict[str, int] = {}
    failures: list[Failure] = []
    in_failures = False
    current: Failure | None = None
    for raw in text.splitlines():
        line = raw.rstrip("\r")
        m = NODE_COUNT.match(line)
        if m:
            counts[m["key"]] = int(m["n"])
            continue
        if line.startswith(NODE_FAILED_HEADER):
            in_failures = True
            continue
        if not in_failures:
            continue
        at = NODE_AT.match(line)
        if at:
            current = Failure("", at["file"], int(at["line"]), int(at["col"]))
            continue
        m = NODE_FAIL.match(line)
        if m and current is not None and not current.name:
            current.name = m["name"]
            failures.append(current)
            continue
        if current is not None and current.name and line.startswith("  ") and len(current.message) < 600:
            current.message += ("\n" if current.message else "") + line.strip()
        if not line.strip():
            continue
    for f in failures:
        f.message = f.message.strip()
        f.id = f.name
    return counts, failures


def js_pattern(names: list[str]) -> str:
    """A JavaScript regular expression matching exactly these test names."""
    return "^(?:" + "|".join(re.sub(r"[.*+?^${}()|\[\]\\/]", lambda m: "\\" + m.group(0), n) for n in names) + ")$"


# ---- GitHub Actions output ----------------------------------------------------------------

def _escape_data(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _escape_property(value: str) -> str:
    return _escape_data(value).replace(":", "%3A").replace(",", "%2C")


def annotation(level: str, message: str, file: str = "", line: int = 0, col: int = 0, title: str = "") -> str:
    """A workflow command: `::error file=…,line=…,title=…::message`."""
    props = []
    if file:
        props.append(f"file={_escape_property(file)}")
    if line:
        props.append(f"line={line}")
    if col:
        props.append(f"col={col}")
    if title:
        props.append(f"title={_escape_property(title)}")
    return f"::{level}{' ' + ','.join(props) if props else ''}::{_escape_data(message)}"


def repo_path(failure: Failure, files: dict[str, list[str]]) -> str:
    """The failing file as a repo-relative path (the console prints only the file's name)."""
    if "/" in failure.file:
        return failure.file
    paths = files.get(failure.file, [])
    return paths[0] if paths else failure.file


def first_line(message: str, limit: int = 200) -> str:
    text = message.strip().splitlines()[0] if message.strip() else ""
    return text if len(text) <= limit else text[: limit - 1] + "…"


def markdown_cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def failures_table(failures: list[Failure], files: dict[str, list[str]] | None = None) -> str:
    rows = ["| Test | Where | What |", "|---|---|---|"]
    for f in failures:
        where = repo_path(f, files or {})
        if f.line:
            where += f":{f.line}"
        rows.append(f"| `{markdown_cell(f.id or f.name)}` | {markdown_cell(where)} | {markdown_cell(first_line(f.message))} |")
    return "\n".join(rows)

#!/usr/bin/env python3
"""Check that a pull request's body says what a reviewer needs for UI work and for features that
act on their own. Stdlib only; the pr-body workflow runs it on every pull request event.

    check_pr_body.py --body-file body.md --files-file changed-files.txt
    PR_BODY=... check_pr_body.py --files-file changed-files.txt

The check is deliberately small and conservative. It never fails a pull request that touches no
UI and carries no "Features that act on their own" section:

* When a changed file is under Sources/ShepherdApp/, Packages/ShepherdUI/ or App/iOS/ (a Markdown
  file is not UI), the body needs a "Departures:", a "Rendered:" and a "Controls used:" line, each
  with something after it. "Departures: none" counts. Template placeholders (HTML comments) do not.
* When the body has the heading "Features that act on their own", its "Bounds:", "Data:",
  "Restart and stop:" and "Decisions:" lines need something after them too. A pull request with no
  such feature deletes the section.

Exit status 0 when the body is fine, 1 with one message per problem otherwise, 2 on bad usage.
"""
import argparse
import os
import re
import sys

UI_PREFIXES = ("Sources/ShepherdApp/", "Packages/ShepherdUI/", "App/iOS/")

UI_FIELDS = {
    "Departures": "every difference from the design you kept, each with a reason; write 'Departures: none' if there are none",
    "Rendered": "the states and themes you rendered, from the real data path, and where the images are (or 'n/a' with a reason for a change nobody sees)",
    "Controls used": "how each control was pressed (ControlPress) and what you asserted (or 'n/a' with a reason when the change adds none)",
}

AUTONOMOUS_HEADING = "Features that act on their own"
AUTONOMOUS_FIELDS = {
    "Bounds": "the default cap on iterations, time and spend, and the test that reaches it",
    "Data": "what is sent where; anything sent to a provider the user did not choose is opt-in and shown in the UI",
    "Restart and stop": "what a restart, Stop, Steer now, a retry, an error and compaction do to it",
    "Decisions": "every product decision you made that nobody asked for, so the user can overrule it (or 'none')",
}

# Text that stands where an answer goes and says nothing.
PLACEHOLDERS = {"", "-", "--", "...", "…", "?", "todo", "tbd", "fixme", "<...>", "<…>"}

COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
HEADING = re.compile(r"^[ \t]{0,3}#{1,6}[ \t]")
BULLET = re.compile(r"^([ \t]*)[-*+][ \t]")


def label_pattern(labels):
    names = "|".join(re.escape(label) for label in sorted(labels, key=len, reverse=True))
    # "- **Label:** value", "**Label**: value", "Label: value", "* Label: value"
    return re.compile(
        r"^[ \t]*(?:[-*+][ \t]+)?(?:\*\*|__)?(?P<label>" + names + r")(?:\*\*|__)?[ \t]*:(?:\*\*|__)?[ \t]*(?P<rest>.*)$",
        re.IGNORECASE,
    )


ALL_LABELS = list(UI_FIELDS) + list(AUTONOMOUS_FIELDS)
LABEL = label_pattern(ALL_LABELS)


def without_comments(body):
    """The body with its HTML comments (the template's placeholders) removed."""
    return COMMENT.sub("", body or "")


def fields(body):
    """What the body says after each known label, keyed by the label in its canonical spelling.

    A value is the rest of the label's line and every line after it up to the next known label, a
    heading, or a bullet at the label's own indent (the next item of the same list). A label named
    twice has both values joined."""
    canonical = {label.lower(): label for label in ALL_LABELS}
    found = {}
    current = None
    indent = 0
    for line in without_comments(body).splitlines():
        match = LABEL.match(line)
        bullet = BULLET.match(line)
        if match:
            current = canonical[match.group("label").lower()]
            indent = len(line) - len(line.lstrip())
            found.setdefault(current, [])
            found[current].append(match.group("rest"))
        elif HEADING.match(line) or (bullet and len(bullet.group(1)) <= indent):
            current = None
        elif current is not None:
            found[current].append(line)
    return {label: "\n".join(parts).strip() for label, parts in found.items()}


def says_something(value):
    return value is not None and value.strip().lower() not in PLACEHOLDERS


def ui_files(files):
    """The changed files that are UI: anything under the UI folders but Markdown."""
    return [f for f in files if f.startswith(UI_PREFIXES) and not f.endswith(".md")]


def has_autonomous_section(body):
    heading = re.compile(r"^[ \t]{0,3}#{1,6}[ \t]+" + re.escape(AUTONOMOUS_HEADING) + r"\b", re.IGNORECASE | re.MULTILINE)
    return heading.search(without_comments(body)) is not None


def problems(body, files):
    """One message per thing the body lacks; empty when it is fine."""
    said = fields(body)
    found = []
    touched = ui_files(files)
    if touched:
        shown = ", ".join(touched[:3]) + (f" and {len(touched) - 3} more" if len(touched) > 3 else "")
        for label, what in UI_FIELDS.items():
            if not says_something(said.get(label)):
                found.append(f"UI files changed ({shown}) but the pull request body has no '{label}:' line with an answer. "
                             f"Say {what}. An HTML comment is a placeholder, not an answer.")
    if has_autonomous_section(body):
        for label, what in AUTONOMOUS_FIELDS.items():
            if not says_something(said.get(label)):
                found.append(f"The body has a '{AUTONOMOUS_HEADING}' section but its '{label}:' line is empty. "
                             f"Say {what}. If the change has no such feature, delete the whole section.")
    return found


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--body-file", help="the pull request body (default: the PR_BODY environment variable)")
    parser.add_argument("--files-file", required=True, help="the changed files, one path per line")
    args = parser.parse_args(argv)
    if args.body_file:
        with open(args.body_file, encoding="utf-8") as handle:
            body = handle.read()
    else:
        body = os.environ.get("PR_BODY", "")
    with open(args.files_file, encoding="utf-8") as handle:
        files = [line.strip() for line in handle if line.strip()]
    found = problems(body, files)
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    for message in found:
        print(f"::error title=Pull request body::{message}" if annotate else f"error: {message}")
    if found:
        print("\nThe template is .github/pull_request_template.md; edit the body and this check runs again.")
        return 1
    print("The pull request body says what it needs to.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

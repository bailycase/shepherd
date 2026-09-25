#!/usr/bin/env python3
"""Carry source mtimes across CI runs so a restored .build compiles incrementally.

A fresh checkout gives every file a new mtime, so a restored build cache would
still recompile everything. `save` records each tracked file's blob sha and
mtime; `restore` puts the recorded mtime back only on files whose blob sha still
matches, so every changed file keeps its fresh mtime and rebuilds. Commit times
(git-restore-mtime) are not used: on a PR's merge ref they can predate the build.
Files edited since checkout are skipped both ways, since their index sha is not
their content.

    ci_mtimes.py save <manifest>
    ci_mtimes.py restore <manifest>
"""
import os
import subprocess
import sys


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, check=True).stdout


def index():
    """(path, blob sha) for every tracked file, with None for a file edited since checkout."""
    edited = set(filter(None, git("ls-files", "-m", "-z").split(b"\0")))
    for record in filter(None, git("ls-files", "-s", "-z").split(b"\0")):
        meta, path = record.split(b"\t", 1)
        yield path, None if path in edited else meta.split()[1]


def save(manifest):
    count = 0
    with open(manifest, "wb") as f:
        for path, sha in index():
            if sha is None:
                continue
            try:
                st = os.lstat(path)
            except FileNotFoundError:
                continue
            f.write(b"%s %d %s\0" % (sha, st.st_mtime_ns, path))
            count += 1
    print(f"saved {count} mtimes")


def restore(manifest):
    try:
        with open(manifest, "rb") as f:
            data = f.read()
    except FileNotFoundError:
        print("no mtime manifest: every file rebuilds")
        return
    saved = {}
    for record in filter(None, data.split(b"\0")):
        sha, ns, path = record.split(b" ", 2)
        saved[path] = (sha, int(ns))
    restored = changed = 0
    for path, sha in index():
        entry = saved.get(path)
        if sha is not None and entry and entry[0] == sha:
            os.utime(path, ns=(entry[1], entry[1]), follow_symlinks=False)
            restored += 1
        else:
            changed += 1
    print(f"restored {restored} mtimes; {changed} files are new or changed")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("save", "restore"):
        sys.exit(__doc__)
    {"save": save, "restore": restore}[sys.argv[1]](sys.argv[2])

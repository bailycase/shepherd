#!/usr/bin/env python3
"""Preserve unchanged checkout inputs' mtimes with a hosted SwiftPM build cache.

Swift's file hashing avoids some compilation, but module emission, C inputs and
resources still consult timestamps. Never backdate a changed file or follow a
symlink from the checkout. Missing/invalid metadata just leaves a normal build.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


MANIFEST = ".build/ci-input-mtimes.json"


def inputs(root):
    tracked = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                             check=True, capture_output=True).stdout
    for name in tracked.split(b"\0"):
        if not name:
            continue
        relative = os.fsdecode(name)
        path = root / relative
        # Only paths supplied by this checkout, not by the cached manifest. Exclude
        # links, including linked parents, even when their destination is in the repo.
        if path.resolve() != path or not path.is_file():
            continue
        stat = path.stat()
        yield relative, path, hashlib.sha256(path.read_bytes()).hexdigest(), stat


def save(root):
    root = root.resolve()
    manifest = root / MANIFEST
    if manifest.resolve() != manifest:
        raise ValueError("mtime manifest must not be symlinked")
    entries = {name: [digest, stat.st_mtime_ns] for name, _, digest, stat in inputs(root)}
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps(entries))
    print(f"Saved timestamps for {len(entries)} tracked inputs")


def restore(root):
    root = root.resolve()
    manifest = root / MANIFEST
    try:
        if manifest.resolve() != manifest:
            raise ValueError("symlinked manifest")
        entries = json.loads(manifest.read_text())
        if not isinstance(entries, dict):
            raise ValueError("invalid manifest")
    except (OSError, ValueError):
        print("No usable input timestamps; using normal build invalidation")
        return
    restored = 0
    now = time.time_ns()
    for name, path, digest, stat in inputs(root):
        entry = entries.get(name)
        if (isinstance(entry, list) and len(entry) == 2 and entry[0] == digest
                and type(entry[1]) is int and 0 < entry[1] <= now):
            os.utime(path, ns=(stat.st_atime_ns, entry[1]), follow_symlinks=False)
            restored += 1
    print(f"Restored timestamps for {restored} unchanged tracked inputs")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("save", "restore"):
        sys.exit("usage: ci_mtimes.py save|restore")
    {"save": save, "restore": restore}[sys.argv[1]](Path.cwd())

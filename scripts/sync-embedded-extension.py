#!/usr/bin/env python3
"""Rewrite one embedded extension literal from its canonical Extensions/ file.

usage: sync-embedded-extension.py <swift-file> <static-name> <canonical-file>

The literal is a raw multi-line string (#\"\"\" … \"\"\"#) indented by 8 spaces;
ShepherdAppUnitTests (EmbeddedExtensionTests) enforces byte identity, so this is the only sane way to edit one.
"""
import re
import sys

swift_path, name, canonical_path = sys.argv[1:4]
swift = open(swift_path, encoding="utf-8").read()
canonical = open(canonical_path, encoding="utf-8").read()
assert canonical.endswith("\n"), "canonical file must end with a newline"
body = "".join(("        " + line) if line.strip() else line for line in canonical.splitlines(keepends=True))
pattern = re.compile(r'(static let %s = #""")\n.*?\n(        """#)' % re.escape(name), re.S)
# Swift drops the newline before the closing delimiter, so the canonical trailing newline needs a blank line.
new, count = pattern.subn(lambda m: m.group(1) + "\n" + body + "\n" + m.group(2), swift, count=1)
assert count == 1, f"literal {name} not found in {swift_path}"
open(swift_path, "w", encoding="utf-8").write(new)
print(f"synced {name} from {canonical_path}")

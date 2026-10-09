"""Every canonical extension under Extensions/ must equal one of the Swift string literals the app embeds.

pi loads the copies the app writes from `static let … = #\"\"\" … \"\"\"#` literals, so a literal that
drifts from its canonical file ships a bug. ShepherdAppUnitTests (EmbeddedExtensionTests) checks the
same pairs in Swift; this runs without a build, which lets a change to Extensions/ alone skip the
Swift job (scripts/ci_plan.py) without losing the check. Edit one with
scripts/sync-embedded-extension.py. Run: python3 -m unittest discover -s Tests/Release -v
"""
import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OPEN = re.compile(r'^\s*(?:(?:public|private|fileprivate|internal)\s+)?static let \w+ = #"""\s*$')
CLOSE = re.compile(r'^(\s*)"""#')


def literals():
    """Every multi-line raw string literal under Sources/: its content, as Swift reads it."""
    found = []
    for folder, _dirs, files in os.walk(os.path.join(ROOT, "Sources")):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            with open(path, encoding="utf-8") as f:
                lines = f.read().split("\n")
            i = 0
            while i < len(lines):
                if OPEN.match(lines[i]):
                    body, j = [], i + 1
                    while j < len(lines) and not CLOSE.match(lines[j]):
                        body.append(lines[j])
                        j += 1
                    if j < len(lines):
                        indent = CLOSE.match(lines[j]).group(1)
                        found.append("\n".join(l[len(indent):] if l.startswith(indent) else l.lstrip() for l in body))
                    i = j
                i += 1
    return found


def canonical_files():
    out = []
    base = os.path.join(ROOT, "Extensions")
    for name in sorted(os.listdir(base)):
        if name.endswith((".ts", ".mjs")):
            out.append(os.path.join(base, name))
    skill = os.path.join(base, "design-skill")
    for name in sorted(os.listdir(skill)):
        out.append(os.path.join(skill, name))
    return out


class EmbeddedExtensionTests(unittest.TestCase):
    def test_every_canonical_file_equals_an_embedded_literal(self):
        embedded = set(literals())
        self.assertGreater(len(embedded), 20)
        drifted = []
        for path in canonical_files():
            with open(path, encoding="utf-8") as f:
                if f.read() not in embedded:
                    drifted.append(os.path.relpath(path, ROOT))
        self.assertEqual(
            drifted, [],
            "these canonical files match no literal under Sources/; sync the Swift copy with "
            "scripts/sync-embedded-extension.py <swift-file> <static-name> <canonical-file>",
        )

    def test_the_canonical_files_are_the_twenty_five_the_app_embeds(self):
        self.assertEqual(len(canonical_files()), 25, "a new canonical file needs an embedded copy and a row in EmbeddedExtensionTests")


if __name__ == "__main__":
    unittest.main()

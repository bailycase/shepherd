"""Tests for scripts/ci_stale_link.py, which decides when the swift-build action rebuilds from scratch.

Run: python3 -m unittest discover -s Tests/Release -v
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCRIPT = os.path.join(ROOT, "scripts", "ci_stale_link.py")
_spec = importlib.util.spec_from_file_location("ci_stale_link", SCRIPT)
assert _spec is not None and _spec.loader is not None
ci_stale_link = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ci_stale_link)

WARNING = """\
/src/Packages/ShepherdUI/Sources/ShepherdUI/Components/Automations/Automations.swift:72:69: warning: main actor-isolated property 'open' can not be referenced from a nonisolated autoclosure
 70 |     let message = "error: not a diagnostic"
    |                                                                     `- warning: main actor-isolated property 'open' can not be referenced from a nonisolated autoclosure
"""

# The shape of CI run 36202420430: every source compiled, one test object was
# older than the module it called.
STALE = WARNING + """\
[459/462] Compiling ShepherdAppIntegrationTests WorktreeBaseOfflineTests.swift
[460/462] Write Objects.LinkFileList
error: link command failed with exit code 1 (use -v to see invocation)
ld: warning: Could not find or use auto-linked framework 'CoreAudioTypes': framework 'CoreAudioTypes' not found
Undefined symbols for architecture arm64:
  "ShepherdCore.Agent.init(id: ShepherdCore.Identifier<ShepherdCore.AgentMarker>, name: Swift.String) -> ShepherdCore.Agent", referenced from:
      closure #1 () -> ShepherdCore.ShepherdState in variable initialization expression of static ShepherdProtocolUnitTests.RemoteSamples.state : ShepherdCore.ShepherdState in RemoteMessageTests.swift.o
      one-time initialization function for agent in Fixture.swift.o
      closure #2 () -> ShepherdCore.ShepherdState in RemoteMessageTests.swift.o
ld: symbol(s) not found for architecture arm64
clang: error: linker command failed with exit code 1 (use -v to see invocation)
[461/462] Linking ShepherdPackageTests
"""

COMPILE_ERROR = WARNING + """\
[20/30] Compiling ShepherdCore Models.swift
/src/Sources/ShepherdCore/Models.swift:12:9: error: cannot find 'checkout' in scope
10 |     public init() {
11 |
12 |         checkout = nil
   |         `- error: cannot find 'checkout' in scope
"""


class StaleObjectsTests(unittest.TestCase):
    def test_a_link_failure_with_undefined_symbols_is_stale(self):
        self.assertEqual(ci_stale_link.stale_objects(STALE), ["RemoteMessageTests.swift.o", "Fixture.swift.o"])

    def test_a_compile_error_is_not_stale(self):
        self.assertIsNone(ci_stale_link.stale_objects(COMPILE_ERROR))

    def test_a_compile_error_beside_a_link_failure_is_not_stale(self):
        self.assertIsNone(ci_stale_link.stale_objects(STALE + COMPILE_ERROR))

    def test_other_failures_are_not_stale(self):
        cases = {
            "a link failure without undefined symbols": (
                "error: link command failed with exit code 1 (use -v to see invocation)\n"
                "ld: library 'ghostty' not found\n"
                "clang: error: linker command failed with exit code 1 (use -v to see invocation)\n"
            ),
            "undefined symbols without a failed link": "Undefined symbols for architecture arm64:\n",
            "a compiler crash": STALE + "error: compile command failed due to signal 6 (use -v to see invocation)\n",
            "a missing header": STALE + "/src/Sources/ShepherdPTYSpawn/spawn.c:1:10: fatal error: 'spawn.h' file not found\n",
            "a SwiftPM error": STALE + "error: fatalError\n",
            "a successful build": WARNING + "Build complete! (8.54s)\n",
            "an empty log": "",
        }
        for name, log in cases.items():
            with self.subTest(name):
                self.assertIsNone(ci_stale_link.stale_objects(log))

    def test_the_command_exits_zero_only_for_a_stale_link(self):
        with tempfile.TemporaryDirectory() as d:
            for log, code, out in ((STALE, 0, "RemoteMessageTests.swift.o, Fixture.swift.o\n"), (COMPILE_ERROR, 1, "")):
                path = os.path.join(d, "build.log")
                with open(path, "w", encoding="utf-8") as f:
                    f.write(log)
                result = subprocess.run([sys.executable, SCRIPT, path], capture_output=True, text=True)
                self.assertEqual((result.returncode, result.stdout), (code, out))


if __name__ == "__main__":
    unittest.main()

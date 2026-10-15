"""The Mac app's entitlements must let Sentry install its crash handler.

Run: python3 -m unittest discover -s Tests/Release -v
"""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ENTITLEMENTS = os.path.join(ROOT, "App", "Shepherd.entitlements")

# Sentry registers EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES (SentryCrashMonitor_MachException.c).
PROBE = """
#include <mach/mach.h>
int main(void) {
    mach_port_t port;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    exception_mask_t mask = EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC
        | EXC_MASK_SOFTWARE | EXC_MASK_BREAKPOINT;
    kern_return_t kr = task_set_exception_ports(mach_task_self(), mask, port,
                                                EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES, THREAD_STATE_NONE);
    return kr == KERN_SUCCESS ? 0 : 1;
}
"""


class AppEntitlementsTests(unittest.TestCase):
    def test_platform_restrictions_stay_off_but_the_rest_of_the_hardening_stays_on(self):
        with open(ENTITLEMENTS, "rb") as f:
            entitlements = plistlib.load(f)
        self.assertNotIn("com.apple.security.hardened-process.platform-restrictions-string", entitlements,
                         "platform restrictions kill the process when Sentry sets its exception ports")
        for key in ("hardened-process", "hardened-process.dyld-ro", "hardened-process.hardened-heap"):
            self.assertIs(entitlements.get(f"com.apple.security.{key}"), True, key)
        self.assertEqual(entitlements.get("com.apple.security.hardened-process.enhanced-security-version-string"), "2")

    @unittest.skipUnless(sys.platform == "darwin" and all(shutil.which(t) for t in ("codesign", "cc")),
                         "needs macOS with codesign and a compiler")
    def test_a_process_signed_with_them_can_set_the_exception_ports_sentry_sets(self):
        with tempfile.TemporaryDirectory() as scratch:
            source = os.path.join(scratch, "probe.c")
            binary = os.path.join(scratch, "probe")
            with open(source, "w") as f:
                f.write(PROBE)
            subprocess.run(["cc", "-arch", "arm64", "-o", binary, source], check=True, capture_output=True)
            subprocess.run(["codesign", "--force", "-s", "-", "--entitlements", ENTITLEMENTS, binary],
                           check=True, capture_output=True)
            result = subprocess.run([binary], capture_output=True)
            self.assertEqual(result.returncode, 0,
                             "a negative status is the OS killing the process with EXC_GUARD")


if __name__ == "__main__":
    unittest.main()

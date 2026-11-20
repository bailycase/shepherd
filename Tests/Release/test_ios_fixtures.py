"""Duo-only regressions must not break the generic simulator run."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def _test_env(bash_env, extra=None):
    # The script reads SHEPHERD_SIMULATOR_SET from the environment, so scrub it: every run
    # here passes its set explicitly (or expects the missing-set error).
    env = {k: v for k, v in os.environ.items() if k != "SHEPHERD_SIMULATOR_SET"}
    env["BASH_ENV"] = str(bash_env)
    if extra:
        env.update(extra)
    return env


class IOSFixtureSelectionTests(unittest.TestCase):
    def test_fold_check_requires_its_pose_and_window_support(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stub = root / "environment.sh"
            # Stop at simulator lookup, before compiling, installing, or launching anything.
            stub.write_text('xcrun() { printf \'{"devices":{}}\\n\'; }\n')
            cases = [
                ([], "all", 66),
                (["-w", "-f", "closed"], "all", 66),
                ([], "windows-fold", 64),
                (["-w", "-f", "open"], "windows-fold", 66),
                (["-w", "-f", "open", "-r", "landscape"], "windows-fold", 64),
            ]
            for flags, screen, expected in cases:
                with self.subTest(flags=flags, screen=screen):
                    result = subprocess.run(
                        ["bash", "Tests/ShepherdIOSChecks/run-simulator.sh", "-d", "absent", "-o", str(root / "shots"), *flags, screen],
                        cwd=ROOT, env=_test_env(stub),
                        text=True, capture_output=True, timeout=5,
                    )
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)


class SimulatorSetAndGuardTests(unittest.TestCase):
    def run_script(self, stub, args, extra_env=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "environment.sh").write_text(stub)
            env = _test_env(root / "environment.sh", extra_env)
            return subprocess.run(
                ["bash", "Tests/ShepherdIOSChecks/run-simulator.sh", "-o", str(root / "shots"), *args],
                cwd=ROOT, env=env, text=True, capture_output=True, timeout=10)

    def test_pose_guard_rejects_old_swiftui_and_names_developer_dir(self):
        stub = ('xcrun() { if [[ " $* " == *" swiftc "* ]]; then echo "stub: old SwiftUI" >&2; return 1; fi; '
                'printf \'{"devices":{}}\\n\'; }\n')
        result = self.run_script(stub, ["-d", "absent", "-f", "closed", "home"])
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("DEVELOPER_DIR", result.stdout + result.stderr)

    def test_pose_guard_passes_new_swiftui_and_still_reports_a_missing_device(self):
        stub = 'xcrun() { printf \'{"devices":{}}\\n\'; }\n'
        result = self.run_script(stub, ["-d", "absent", "-f", "closed", "home"])
        self.assertEqual(result.returncode, 66, result.stdout + result.stderr)

    def test_set_flag_reaches_simctl_calls(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "simctl.log"
            stub = (f'xcrun() {{ printf \'%s\\n\' "xcrun $*" >> "{log}"; printf \'{{"devices":{{}}}}\\n\'; }}\n')
            result = self.run_script(stub, ["-d", "absent", "--set", "/tmp/custom-set", "home"])
            self.assertEqual(result.returncode, 66, result.stdout + result.stderr)
            lines = [l for l in log.read_text().splitlines() if l.startswith("xcrun simctl")]
            self.assertTrue(lines, "expected the script to call simctl")
            for line in lines:
                self.assertIn("--set /tmp/custom-set", line)

    def test_set_env_var_used_when_flag_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "simctl.log"
            stub = (f'xcrun() {{ printf \'%s\\n\' "xcrun $*" >> "{log}"; printf \'{{"devices":{{}}}}\\n\'; }}\n')
            result = self.run_script(stub, ["-d", "absent", "home"],
                                      {"SHEPHERD_SIMULATOR_SET": "/tmp/env-set"})
            self.assertEqual(result.returncode, 66, result.stdout + result.stderr)
            lines = [l for l in log.read_text().splitlines() if l.startswith("xcrun simctl")]
            self.assertTrue(lines, "expected the script to call simctl")
            for line in lines:
                self.assertIn("--set /tmp/env-set", line)

    def test_platform_create_failure_prints_not_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stub = ('xcrun() { if [[ " $* " == *" create "* ]]; then echo "Incompatible device" >&2; return 1; fi; '
                    'printf \'{"devices":{}}\\n\'; }\n')
            (root / "environment.sh").write_text(stub)
            result = subprocess.run(
                ["bash", "Tests/ShepherdIOSChecks/run-simulator.sh", "--platform", "duo",
                 "--set", str(root / "sims"), "-o", str(root / "shots"), "home"],
                cwd=ROOT, env=_test_env(root / "environment.sh"),
                text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("not run: duo", result.stdout + result.stderr)
            self.assertEqual(list((root / "shots").glob("*.png")), [])

    def test_exit_trap_deletes_after_a_failing_shutdown(self):
        # The EXIT trap runs under set -e: a shutdown that fails (the device never booted)
        # must not abort the trap before delete runs. Create succeeds, -p skips the build,
        # and the missing products dir then fails the run.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "simctl.log"
            stub = (
                f'xcrun() {{ printf \'%s\\n\' "xcrun $*" >> "{log}"; '
                'if [[ " $* " == *" create "* ]]; then echo FAKE-UDID-1; return 0; fi; '
                'if [[ " $* " == *" shutdown "* ]]; then return 1; fi; '
                'printf \'{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-1":'
                '[{"udid":"FAKE-UDID-1","name":"Shepherd duo","state":"Shutdown"}]}}\\n\'; }\n'
            )
            (root / "environment.sh").write_text(stub)
            result = subprocess.run(
                ["bash", "Tests/ShepherdIOSChecks/run-simulator.sh", "--platform", "duo",
                 "--set", str(root / "sims"), "-p", "/nonexistent", "-o", str(root / "shots"), "home"],
                cwd=ROOT, env=_test_env(root / "environment.sh"),
                text=True, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            lines = [l for l in log.read_text().splitlines() if l.startswith("xcrun simctl")]
            shutdown = [l for l in lines if " shutdown " in l]
            deletes = [l for l in lines if " delete " in l]
            self.assertTrue(shutdown, "expected the trap to attempt shutdown")
            self.assertTrue(any("FAKE-UDID-1" in l for l in deletes),
                            f"a failing shutdown must not skip delete:\n{chr(10).join(lines)}")
            self.assertLess(lines.index(shutdown[0]), lines.index(deletes[0]))
            self.assertEqual(list((root / "shots").glob("*.png")), [])

    def test_platform_needs_a_set_and_exactly_one_device_source(self):
        stub = 'xcrun() { printf \'{"devices":{}}\\n\'; }\n'
        cases = [
            (["home"], {}),  # neither -d nor --platform
            (["-d", "absent", "--platform", "iphone", "--set", "/tmp/s", "home"], {}),  # both
            (["--platform", "iphone", "home"], {}),  # created devices stay out of the default set
            (["--platform", "watch", "--set", "/tmp/s", "home"], {}),  # unknown platform
        ]
        for args, extra in cases:
            with self.subTest(args=args):
                result = self.run_script(stub, args, extra)
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)

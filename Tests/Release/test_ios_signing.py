"""Signing gates use scratch apps and mocked native tools, never a keychain."""
import contextlib
import io
from pathlib import Path
import plistlib
import subprocess
import unittest
from unittest.mock import Mock, patch

import test_release

release = test_release.release


class IOSSigningTests(unittest.TestCase):
    def setUp(self):
        self.team = "4J6D7M7D79"
        self.signed = {
            "aps-environment": "production",
            "application-identifier": f"{self.team}.{release.IOS.bundle_id}",
            "com.apple.developer.team-identifier": self.team,
            "get-task-allow": False,
        }
        self.profile = {"TeamIdentifier": [self.team], "Entitlements": self.signed.copy()}
        self.commands = []
        self.app_overrides = {}
        self.extra_app = False

    def native(self, args, **kwargs):
        self.assertTrue(kwargs["capture_output"])
        self.assertTrue(kwargs["check"])
        self.assertEqual(kwargs["timeout"], 120)
        self.commands.append(args)
        output = b""
        if args[0] == "ditto":
            payload = Path(args[-1]) / "Payload"
            payload.mkdir()
            test_release.VerifyIOSTests.make_app(self, str(payload), **self.app_overrides)
            if self.extra_app:
                (payload / "Other.app").mkdir()
        elif args[:2] == ("codesign", "--force"):
            requested = Path(args[args.index("--entitlements") + 1])
            self.assertEqual(plistlib.loads(requested.read_bytes()), {"aps-environment": "production"})
            self.assertIn("--generate-entitlement-der", args)
            self.assertEqual(args[args.index("--sign") + 1], "-")
        elif args[:2] == ("codesign", "-d"):
            output = plistlib.dumps(self.signed)
        elif args[0] == "security":
            output = plistlib.dumps(self.profile)
        return subprocess.CompletedProcess(args, 0, output, b"private diagnostics")

    def test_preparation_seals_and_reads_back_production_entitlements(self):
        with patch.object(release.subprocess, "run", side_effect=self.native):
            release.prepare_ios_signing("scratch.app")
        self.assertEqual(len(self.commands), 2)
        self.assertFalse(Path(self.commands[0][self.commands[0].index("--entitlements") + 1]).exists())
        self.signed.clear()
        with patch.object(release.subprocess, "run", side_effect=self.native):
            with self.assertRaises(ValueError):
                release.prepare_ios_signing("scratch.app")

    def test_export_checks_metadata_signature_and_profile_and_removes_scratch(self):
        with patch.object(release.subprocess, "run", side_effect=self.native):
            release.verify_ios_ipa("scratch.ipa", "321")
        self.assertEqual([args[0] for args in self.commands], ["ditto", "codesign", "codesign", "security"])
        self.assertEqual(self.commands[1][1:4], ("--verify", "--deep", "--strict"))
        self.assertFalse(Path(self.commands[0][-1]).exists())

    def test_signature_and_profile_fail_closed(self):
        for target in (self.signed, self.profile["Entitlements"]):
            original = target.copy()
            for key in original:
                for value in (None, "$(UNRESOLVED)", "wrong", True):
                    with self.subTest(key=key, value=value):
                        target.clear()
                        target.update(original)
                        if value is None:
                            target.pop(key)
                        else:
                            target[key] = value
                        # Missing get-task-allow is valid (no debugging entitlement).
                        if key == "get-task-allow" and value is None:
                            continue
                        with patch.object(release.subprocess, "run", side_effect=self.native):
                            with self.assertRaises(ValueError):
                                release.verify_ios_ipa("scratch.ipa", "321")
            target.clear()
            target.update(original)
        self.profile["TeamIdentifier"] = ["WRONGTEAM1"]
        with patch.object(release.subprocess, "run", side_effect=self.native):
            with self.assertRaises(ValueError):
                release.verify_ios_ipa("scratch.ipa", "321")

    def test_wrong_build_and_multiple_apps_stop_before_signature_tools(self):
        for extra in (False, True):
            self.extra_app = extra
            self.commands.clear()
            with patch.object(release.subprocess, "run", side_effect=self.native):
                with self.assertRaises(ValueError):
                    release.verify_ios_ipa("scratch.ipa", "wrong" if not extra else "321")
            self.assertEqual(len(self.commands), 1)

    def test_malformed_plists_and_native_failure_do_not_leak_output(self):
        for data in (b"", b"broken", b"<?xml version='1.0'?><plist><dict>", plistlib.dumps([]), plistlib.dumps({"aps-environment": "${APS}"})):
            with self.assertRaises(ValueError):
                release._ios_plist(data)
        for failure in (subprocess.CalledProcessError(1, "security", b"PRIVATE CERT", b"PRIVATE PROFILE"),
                        subprocess.TimeoutExpired("security", 120), FileNotFoundError()):
            with patch.object(release.subprocess, "run", side_effect=failure):
                output = io.StringIO()
                with contextlib.redirect_stderr(output):
                    self.assertEqual(release.main(["verify-ios-ipa", "scratch.ipa", "321"]), 1)
                self.assertNotIn("PRIVATE", output.getvalue())


class IOSPushCapabilityTests(unittest.TestCase):
    def setUp(self):
        self.client = Mock(api=release.ASC_API)
        self.app = {"data": [{"id": "existing-id", "attributes": {"identifier": release.IOS.bundle_id}}]}
        self.enabled = {"data": [{"attributes": {"capabilityType": "PUSH_NOTIFICATIONS"}}]}

    def test_existing_push_is_a_read_only_noop(self):
        self.client.request.side_effect = [self.app, self.enabled]
        release.ensure_ios_push(self.client)
        self.assertEqual(self.client.request.call_count, 2)
        self.assertTrue(all(call.args[0] == "GET" for call in self.client.request.call_args_list))
        self.assertIn("filter%5Bidentifier%5D=com.bailycase.shepherd.ios",
                      self.client.request.call_args_list[0].args[1])

    def test_missing_push_is_enabled_on_only_the_existing_app_and_verified(self):
        self.client.request.side_effect = [self.app, {"data": []}, {}, self.enabled]
        release.ensure_ios_push(self.client)
        self.assertEqual(self.client.request.call_count, 4)
        self.assertEqual(self.client.request.call_args_list[2].args, (
            "POST", release.ASC_API + "/v1/bundleIdCapabilities", {"data": {
                "type": "bundleIdCapabilities", "attributes": {"capabilityType": "PUSH_NOTIFICATIONS"},
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": "existing-id"}}},
            }}))
        self.assertEqual(self.client.request.call_args_list[-1].args[0], "GET")

    def test_wrong_missing_or_ambiguous_app_and_pagination_are_refused(self):
        for response in ({"data": []}, {"data": self.app["data"] * 2},
                         {"data": [{"id": "wrong", "attributes": {"identifier": release.IOS.bundle_id + ".dev"}}]},
                         {**self.app, "links": {"next": "another-page"}}):
            with self.subTest(response=response):
                self.client.request.reset_mock()
                self.client.request.side_effect = [response]
                with self.assertRaises(release.AppStoreConnectError):
                    release.ensure_ios_push(self.client)
                self.assertEqual(self.client.request.call_count, 1)

    def test_failed_api_or_verification_stops_without_retry(self):
        for responses in ([self.app, {"data": [], "links": {"next": "next"}}],
                          [self.app, release.AppStoreConnectError("denied")],
                          [self.app, {"data": []}, release.AppStoreConnectError("denied")],
                          [self.app, {"data": []}, {}, {"data": []}]):
            with self.subTest(responses=responses):
                self.client.request.reset_mock()
                self.client.request.side_effect = responses
                with self.assertRaises(release.AppStoreConnectError):
                    release.ensure_ios_push(self.client)
                self.assertEqual(self.client.request.call_count, len(responses))


if __name__ == "__main__":
    unittest.main()

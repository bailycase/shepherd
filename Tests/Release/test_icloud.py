"""Fleet's iCloud rendezvous in the release: the entitlements, the provisioning profile and what the workflow does with and
without the secret. CloudKit itself is not reachable from here. Run: python3 -m unittest discover -s Tests/Release -v
"""
import base64
import importlib.util
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_spec = importlib.util.spec_from_file_location("release_icloud", os.path.join(ROOT, "scripts", "release.py"))
assert _spec is not None and _spec.loader is not None
release = importlib.util.module_from_spec(_spec)
sys.modules["release_icloud"] = release
_spec.loader.exec_module(release)

TEAM = "ABCDE12345"
CONTAINER = "iCloud.com.bailycase.shepherd"
NOW = datetime(2026, 11, 13)


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def profile(app_key="nightly", **changes):
    """What `security cms -D` shows of a Developer ID profile for the app."""
    granted = {
        "com.apple.application-identifier": f"{TEAM}.{release.APPS[app_key].bundle_id}",
        "com.apple.developer.team-identifier": TEAM,
        "com.apple.developer.icloud-container-identifiers": [CONTAINER],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-environment": ["Development", "Production"],
    }
    value = {"TeamIdentifier": [TEAM], "ExpirationDate": datetime(2027, 6, 1), "Entitlements": granted}
    granted.update(changes.pop("granted", {}))
    value.update(changes)
    return value


def secret(value):
    """The base64 a person pastes into the GitHub secret: the bytes of the .provisionprofile. The stand-in decoder
    reads them back as the plist, which `security cms` does for the real thing."""
    return base64.b64encode(plistlib.dumps(value)).decode()


def decode(path):
    with open(path, "rb") as f:
        return plistlib.loads(f.read())


class EmbedProfileTests(unittest.TestCase):
    def embed(self, app_key="nightly", secrets=None, identity="Developer ID Application: Fixture", decoder=decode):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        app = Path(directory.name) / "Shepherd.app"
        (app / "Contents").mkdir(parents=True)
        out = str(Path(directory.name) / "Shepherd.entitlements")
        chosen, lines = release.embed_profile(app_key, str(app), out, secrets or {}, identity, ROOT, decode=decoder, now=NOW)
        return SimpleNamespace(chosen=chosen, lines=lines, app=app, out=out, embedded=app / release.EMBEDDED_PROFILE)

    def test_a_usable_profile_is_embedded_and_the_app_is_signed_with_the_icloud_entitlements(self):
        for key, env in (("nightly", "PROFILE_NIGHTLY"), ("main", "PROFILE_STABLE")):
            with self.subTest(app=key):
                value = profile(key)
                result = self.embed(key, {env: secret(value)})
                self.assertEqual(result.chosen, result.out)
                self.assertEqual(decode(str(result.embedded)), value, "the profile is embedded as given")
                with open(result.out, "rb") as f:
                    signed = plistlib.load(f)
                self.assertEqual(signed["com.apple.developer.icloud-container-identifiers"], [CONTAINER])
                self.assertEqual(signed["com.apple.developer.icloud-services"], ["CloudKit"])
                self.assertEqual(signed["com.apple.application-identifier"], f"{TEAM}.{release.APPS[key].bundle_id}")
                self.assertEqual(signed["com.apple.developer.team-identifier"], TEAM)
                self.assertEqual(signed["com.apple.developer.icloud-container-environment"], "Production")
                self.assertIs(signed["com.apple.security.hardened-process"], True, "the hardening stays")
                self.assertTrue(any("Embedded the provisioning profile" in line for line in result.lines))

    def test_a_profile_that_grants_every_icloud_service_is_taken(self):
        # The Developer ID profile in use lists icloud-services as "*", not ["CloudKit"].
        value = profile(granted={"com.apple.developer.icloud-services": "*"})
        del value["Entitlements"]["com.apple.developer.icloud-container-environment"]
        result = self.embed(secrets={"PROFILE_NIGHTLY": secret(value)})
        self.assertEqual(result.chosen, result.out)
        with open(result.out, "rb") as f:
            signed = plistlib.load(f)
        self.assertEqual(signed["com.apple.developer.icloud-services"], ["CloudKit"])
        self.assertNotIn("com.apple.developer.icloud-container-environment", signed, "only what the profile names")

    def test_a_secret_pasted_with_line_breaks_still_decodes(self):
        wrapped = re.sub(r"(.{76})", r"\1\n", secret(profile()))
        self.assertEqual(self.embed(secrets={"PROFILE_NIGHTLY": wrapped}).chosen.endswith("Shepherd.entitlements"), True)
        self.assertTrue(self.embed(secrets={"PROFILE_NIGHTLY": wrapped}).embedded.exists())

    def test_without_the_secret_the_app_is_built_without_the_icloud_entitlements_and_the_log_says_so(self):
        for key, name in (("nightly", "PROFILE_NIGHTLY"), ("main", "PROFILE_STABLE")):
            with self.subTest(app=key):
                result = self.embed(key, {})
                self.assertEqual(result.chosen, os.path.join(ROOT, release.APP_ENTITLEMENTS))
                self.assertFalse(result.embedded.exists())
                self.assertFalse(os.path.exists(result.out))
                self.assertEqual(len(result.lines), 1)
                self.assertIn(f"No {name} secret", result.lines[0])
                self.assertIn("without the iCloud entitlements", result.lines[0])
                self.assertTrue(result.lines[0].startswith("::notice"), "a missing secret is expected, not a warning")

    def test_each_app_uses_only_its_own_secret(self):
        stable_only = {"PROFILE_STABLE": secret(profile("main"))}
        self.assertFalse(self.embed("nightly", stable_only).embedded.exists())
        self.assertTrue(self.embed("main", stable_only).embedded.exists())

    def test_an_ad_hoc_build_never_takes_a_profile(self):
        for identity in ("-", ""):
            with self.subTest(identity=identity):
                result = self.embed(secrets={"PROFILE_NIGHTLY": secret(profile())}, identity=identity)
                self.assertEqual(result.chosen, os.path.join(ROOT, release.APP_ENTITLEMENTS))
                self.assertFalse(result.embedded.exists())

    def test_a_secret_that_does_not_fit_warns_and_builds_without_icloud_instead_of_failing(self):
        for label, bad in [
            ("another app", profile(granted={"com.apple.application-identifier": f"{TEAM}.com.bailycase.shepherd"})),
            ("another team", profile(granted={"com.apple.developer.team-identifier": "ZZZZZ99999"})),
            ("no container", profile(granted={"com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.other"]})),
            ("no CloudKit", profile(granted={"com.apple.developer.icloud-services": []})),
            ("expired", profile(ExpirationDate=datetime(2026, 1, 1))),
            ("no entitlements", {"TeamIdentifier": [TEAM]}),
        ]:
            with self.subTest(problem=label):
                result = self.embed("nightly", {"PROFILE_NIGHTLY": secret(bad)})
                self.assertEqual(result.chosen, os.path.join(ROOT, release.APP_ENTITLEMENTS))
                self.assertFalse(result.embedded.exists(), "nothing half-embedded")
                self.assertTrue(result.lines[0].startswith("::warning"), result.lines)

    def test_a_secret_that_is_not_a_profile_warns_and_builds_without_icloud(self):
        def refusing(path):
            raise ValueError("the provisioning profile can't be decoded")
        for label, secrets, decoder in [("not base64", {"PROFILE_NIGHTLY": "***"}, decode),
                                        ("not decodable", {"PROFILE_NIGHTLY": secret(profile())}, refusing)]:
            with self.subTest(problem=label):
                result = self.embed("nightly", secrets, decoder=decoder)
                self.assertEqual(result.chosen, os.path.join(ROOT, release.APP_ENTITLEMENTS))
                self.assertTrue(result.lines[0].startswith("::warning"))
                self.assertFalse(result.embedded.exists())

    def test_the_profile_is_decoded_with_security_cms(self):
        seen = []

        def run(command, **_):
            seen.append(command)
            return SimpleNamespace(returncode=0, stdout=plistlib.dumps(profile()))
        self.assertEqual(release.decode_profile("p.provisionprofile", run=run)["TeamIdentifier"], [TEAM])
        self.assertEqual(seen, [["security", "cms", "-D", "-i", "p.provisionprofile"]])
        with self.assertRaises(ValueError):
            release.decode_profile("p", run=lambda *a, **k: SimpleNamespace(returncode=1, stdout=b""))
        with self.assertRaises(ValueError):
            release.decode_profile("p", run=lambda *a, **k: SimpleNamespace(returncode=0, stdout=b"not a plist"))


class VerifyIcloudTests(unittest.TestCase):
    def check(self, signed, embedded):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        app = Path(directory.name) / "Shepherd Nightly.app"
        (app / "Contents").mkdir(parents=True)
        if embedded is not None:
            (app / release.EMBEDDED_PROFILE).write_bytes(plistlib.dumps(embedded))
        run = lambda *a, **k: SimpleNamespace(returncode=0, stdout=plistlib.dumps(signed))
        return release.icloud_problems(str(app), run=run, decode=decode)

    def icloud(self):
        value = profile()
        return {k: v for k, v in value["Entitlements"].items() if k != "com.apple.developer.icloud-container-environment"}

    def test_an_app_signed_with_icloud_needs_a_profile_that_grants_it(self):
        self.assertEqual(self.check(self.icloud(), profile()), [])
        self.assertIn("no Contents/embedded.provisionprofile", self.check(self.icloud(), None)[0])
        wrong = profile(granted={"com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.other"]})
        self.assertIn("icloud-container-identifiers", self.check(self.icloud(), wrong)[0])

    def test_a_profile_granting_every_service_backs_cloudkit(self):
        wildcard = profile(granted={"com.apple.developer.icloud-services": "*"})
        self.assertEqual(self.check(self.icloud(), wildcard), [])

    def test_an_app_signed_without_icloud_ships_without_a_profile(self):
        plain = {"com.apple.security.hardened-process": True}
        self.assertEqual(self.check(plain, None), [])
        self.assertIn("without the iCloud entitlements", self.check(plain, profile())[0])


class ReleaseFilesTests(unittest.TestCase):
    """Drift between the entitlements, the Xcode configurations, the workflow and the schema fails here, before a release."""

    def test_the_icloud_entitlements_are_the_apps_plus_the_container_and_cloudkit_and_nothing_else(self):
        base = plistlib.loads(read("App", "Shepherd.entitlements").encode())
        icloud = plistlib.loads(read("App", "Shepherd.icloud.entitlements").encode())
        self.assertEqual({k: v for k, v in icloud.items() if not k.startswith("com.apple.developer.")}, base)
        self.assertEqual({k: v for k, v in icloud.items() if k.startswith("com.apple.developer.")},
                         {"com.apple.developer.icloud-container-identifiers": [CONTAINER],
                          "com.apple.developer.icloud-services": ["CloudKit"]})

    def test_the_container_is_the_one_the_swift_store_opens(self):
        self.assertEqual(release.ICLOUD_CONTAINER, CONTAINER)
        self.assertIn(f'"{CONTAINER}"', read("Sources", "ShepherdSessions", "Fleet", "FleetCloudKitStore.swift"))

    def test_every_xcode_configuration_keeps_the_plain_entitlements_so_local_builds_open(self):
        project = read("Shepherd.xcodeproj", "project.pbxproj")
        self.assertNotIn("CODE_SIGN_ENTITLEMENTS = App/Shepherd.icloud.entitlements", project)
        for name in ("Debug", "Release", "Nightly"):
            with self.subTest(configuration=name):
                blocks = re.findall(r"/\* %s \*/ = \{\n\t\t\tisa = XCBuildConfiguration;\n(.*?)\n\t\t\};" % name, project, re.S)
                mac = [b for b in blocks if "INFOPLIST_FILE = App/Info.plist;" in b]
                self.assertEqual(len(mac), 1)
                self.assertIn("CODE_SIGN_ENTITLEMENTS = App/Shepherd.entitlements;", mac[0])

    def test_the_profile_is_embedded_before_signing_and_the_agreement_is_checked_after(self):
        workflow = read(".github", "workflows", "release-build.yml")
        names = re.findall(r"\n      - name: (.*)", workflow)
        self.assertLess(names.index("Embed the iCloud provisioning profile"), names.index("Sign"))
        self.assertLess(names.index("Sign"), names.index("Verify the iCloud entitlements"))
        self.assertLess(names.index("Verify the iCloud entitlements"), names.index("Notarize"))
        sign = workflow.split("      - name: Sign\n", 1)[1].split("\n      - ", 1)[0]
        self.assertIn("${{ steps.icloud.outputs.entitlements }}", sign)
        self.assertNotIn("App/Shepherd.entitlements", sign, "the entitlements to sign with come from the embed step")

    def test_both_secrets_reach_the_build_from_the_release_workflow_and_are_optional(self):
        build = read(".github", "workflows", "release-build.yml")
        release_yml = read(".github", "workflows", "release.yml")
        for secret_name in ("DEVELOPER_ID_PROFILE_NIGHTLY", "DEVELOPER_ID_PROFILE_STABLE"):
            with self.subTest(secret=secret_name):
                self.assertRegex(build, r"\n      %s:\n        required: false" % secret_name)
                self.assertIn(f"{secret_name}: ${{{{ secrets.{secret_name} }}}}", release_yml)
                self.assertIn(f"${{{{ secrets.{secret_name} }}}}", build.split("name: Embed the iCloud provisioning profile", 1)[1])

    def run_embed_step(self, env):
        """The workflow's own embed command, run with `env`: what it puts in $GITHUB_OUTPUT and on the log."""
        build = read(".github", "workflows", "release-build.yml")
        step = build.split("      - name: Embed the iCloud provisioning profile\n", 1)[1].split("\n      - ", 1)[0]
        shell = "\n".join(line[10:] for line in step.split("run: |\n", 1)[1].splitlines() if line.startswith("          "))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").symlink_to(Path(ROOT) / "scripts", target_is_directory=True)
            app = root / "build" / "Shepherd Nightly.app"
            (app / "Contents").mkdir(parents=True)
            output = root / "github-output"
            output.write_text("")
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", shell], cwd=root, capture_output=True, text=True, timeout=30,
                                    env={**{k: v for k, v in os.environ.items() if not k.startswith("PROFILE_")},
                                         "APP_KEY": "nightly", "PRODUCTS": str(root / "build"), "PRODUCT": "Shepherd Nightly.app",
                                         "RUNNER_TEMP": directory, "GITHUB_OUTPUT": str(output), **env})
            return result, output.read_text(), (app / release.EMBEDDED_PROFILE).exists()

    def test_the_embed_step_without_the_secret_signs_with_the_plain_entitlements_and_never_fails(self):
        result, output, embedded = self.run_embed_step({"IDENTITY": "Developer ID Application: Fixture"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.strip(), "entitlements=App/Shepherd.entitlements")
        self.assertIn("without the iCloud entitlements", result.stderr)
        self.assertFalse(embedded)

    def test_the_embed_step_with_a_secret_that_is_not_a_profile_warns_and_still_succeeds(self):
        result, output, embedded = self.run_embed_step({"IDENTITY": "Developer ID Application: Fixture",
                                                        "PROFILE_NIGHTLY": base64.b64encode(b"nothing like a profile").decode()})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.strip(), "entitlements=App/Shepherd.entitlements")
        self.assertIn("::warning", result.stderr)
        self.assertFalse(embedded)

    def test_the_schema_declares_both_record_types_with_every_field_encrypted(self):
        schema = read("scripts", "fleet-rendezvous.ckdb")
        store = read("Sources", "ShepherdSessions", "Fleet", "FleetCloudKitStore.swift")
        written = set(re.findall(r'fields\["(\w+)"\]', store))
        self.assertEqual(written, {"hostID", "name", "port", "routes", "build", "expiresAt", "updatedAt"})
        for record_type in ("FleetJoin", "FleetPresence"):
            with self.subTest(record_type=record_type):
                body = schema.split(f"RECORD TYPE {record_type} (", 1)[1].split(");", 1)[0]
                fields = dict(re.findall(r"^\s*(\w+)\s+(ENCRYPTED \w+),?$", body, re.M))
                self.assertEqual(set(fields), written, "every field the app writes is declared, and none else")
                self.assertEqual(len(re.findall(r"ENCRYPTED", body)), len(written))
                self.assertNotRegex(body, r"\b(STRING|BYTES|INT64|DOUBLE|TIMESTAMP)\b,\n(?!\s*\"___)(?!\s*GRANT)(?!\s*$)[^\n]*ENCRYPTED\w*\s*$",
                                    "no unencrypted user field")
        self.assertEqual({r"FleetJoin", "FleetPresence"}, set(re.findall(r"RECORD TYPE (\w+)", schema)))
        keys = read("Sources", "ShepherdSessions", "Fleet", "FleetRendezvous.swift")
        self.assertIn('case join = "FleetJoin", presence = "FleetPresence"', keys)

    def test_the_release_notes_say_how_to_deploy_the_schema(self):
        docs = read("docs", "releases.md")
        self.assertIn("scripts/fleet-rendezvous.ckdb", docs)
        self.assertIn("DEVELOPER_ID_PROFILE_NIGHTLY", docs)


if __name__ == "__main__":
    unittest.main()

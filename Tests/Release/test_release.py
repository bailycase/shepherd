"""Tests for scripts/release.py, the logic behind .github/workflows/release.yml.

Run: python3 -m unittest discover -s Tests/Release -v
"""
import base64
import contextlib
import hashlib
import http.server
import importlib.util
import io
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_spec = importlib.util.spec_from_file_location("release", os.path.join(ROOT, "scripts", "release.py"))
assert _spec is not None and _spec.loader is not None
release = importlib.util.module_from_spec(_spec)
# dataclasses look their module up while the class is built.
sys.modules["release"] = release
_spec.loader.exec_module(release)

STAMP = "202609232100"


def item(version, channel=None, archive="Shepherd-v1.0.0.dmg", deltas=()):
    tag = f"<sparkle:channel>{channel}</sparkle:channel>" if channel else ""
    delta_xml = "".join(
        f'<enclosure url="https://github.com/bailycase/shepherd/releases/download/{d}" sparkle:deltaFrom="1"/>'
        for d in deltas
    )
    return (f"<item><title>{version}</title>{tag}<sparkle:version>{version}</sparkle:version>"
            f'<enclosure url="https://github.com/bailycase/shepherd/releases/download/{archive}" length="1"/>'
            f"<sparkle:deltas>{delta_xml}</sparkle:deltas></item>")


def feed(*items):
    return ('<?xml version="1.0" standalone="yes"?><rss xmlns:sparkle="http://www.andymatuschak.org/'
            'xml-namespaces/sparkle" version="2.0"><channel><title>Shepherd</title>'
            + "".join(items) + "</channel></rss>")


class PlanTests(unittest.TestCase):
    """What every trigger of the workflow builds."""

    def test_a_release_tag_builds_shepherd_on_the_stable_channel(self):
        p = release.plan("refs/tags/v1.2.3", STAMP)
        self.assertTrue(p["build"])
        self.assertEqual((p["app"], p["channel"], p["version"], p["tag"]), ("main", "stable", "1.2.3", "v1.2.3"))
        self.assertEqual((p["scheme"], p["configuration"]), ("Shepherd (Prod)", "Release"))
        self.assertEqual((p["product"], p["dmg"], p["dsyms"], p["volume"]),
                         ("Shepherd.app", "Shepherd.dmg", "Shepherd-dSYMs.zip", "Shepherd"))
        self.assertEqual(p["bundle_id"], "com.bailycase.shepherd")
        self.assertEqual(p["title"], "Shepherd v1.2.3")
        self.assertFalse(p["prerelease"])

    def test_a_beta_tag_builds_shepherd_as_a_prerelease(self):
        p = release.plan("refs/tags/v1.3.0-beta.2", STAMP)
        self.assertTrue(p["build"])
        self.assertEqual((p["app"], p["channel"], p["version"], p["tag"]), ("main", "beta", "1.3.0-beta.2", "v1.3.0-beta.2"))
        self.assertEqual(p["dmg"], "Shepherd.dmg")
        self.assertTrue(p["prerelease"])

    def test_a_push_to_nightly_builds_shepherd_nightly(self):
        p = release.plan("refs/heads/nightly", STAMP)
        self.assertTrue(p["build"])
        self.assertEqual((p["app"], p["channel"]), ("nightly", "nightly"))
        self.assertEqual((p["version"], p["tag"]), (f"0.0.0-nightly.{STAMP}", f"nightly-{STAMP}"))
        self.assertEqual((p["scheme"], p["configuration"]), ("Shepherd (Nightly)", "Nightly"))
        self.assertEqual((p["product"], p["dmg"], p["dsyms"], p["volume"]),
                         ("Shepherd Nightly.app", "Shepherd-Nightly.dmg", "Shepherd-Nightly-dSYMs.zip", "Shepherd Nightly"))
        self.assertEqual(p["bundle_id"], "com.bailycase.shepherd.nightly")
        self.assertEqual(p["title"], f"Shepherd Nightly nightly-{STAMP}")
        self.assertTrue(p["prerelease"])

    def test_a_stray_rc_tag_builds_nothing(self):
        p = release.plan("refs/tags/v1.3.0-rc.1", STAMP)
        self.assertFalse(p["build"])
        self.assertIn("retired", p["reason"])

    def test_other_tags_build_nothing(self):
        for tag in ("v1.2", "v1.2.3-alpha.1", "v1.2.3-beta", "vnext", "v1.2.3.4"):
            with self.subTest(tag=tag):
                self.assertFalse(release.plan(f"refs/tags/{tag}", STAMP)["build"])

    def test_only_the_nightly_branch_builds_shepherd_nightly(self):
        # A manual run (workflow_dispatch) on another branch must not ship it to Shepherd Nightly.
        for ref in ("refs/heads/master", "refs/heads/feat/native-redesign", "refs/heads/nightly-old"):
            with self.subTest(ref=ref):
                p = release.plan(ref, STAMP)
                self.assertFalse(p["build"])
                self.assertIn("only the nightly branch", p["reason"])

    def test_a_rerun_that_already_published_its_nightly_builds_nothing(self):
        # A re-run keeps the build number (the run number), so a second release of it would put
        # two archives with one CFBundleVersion in Shepherd Nightly's feed.
        p = release.plan("refs/heads/nightly", STAMP, 2, "nightly-202609232159")
        self.assertFalse(p["build"])
        self.assertIn("nightly-202609232159", p["reason"])

    def test_a_rerun_before_anything_was_published_builds(self):
        self.assertTrue(release.plan("refs/heads/nightly", STAMP, 2, "")["build"])
        # A first attempt is a new run, with its own build number, even on a published commit.
        self.assertTrue(release.plan("refs/heads/nightly", STAMP, 1, "nightly-202609232159")["build"])

    def test_the_plan_command_takes_the_attempt_and_the_published_tag(self):
        for args, builds in ((["refs/heads/nightly", STAMP], True),
                             (["refs/heads/nightly", STAMP, "1", ""], True),
                             (["refs/heads/nightly", STAMP, "3", "nightly-202609232159"], False),
                             (["refs/tags/v1.2.3", STAMP, "2", ""], True)):
            with self.subTest(args=args):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(release.main(["plan", *args]), 0)
                line = out.getvalue().strip()
                self.assertTrue(line.startswith("plan="))
                self.assertEqual(json.loads(line.removeprefix("plan="))["build"], builds)

    def test_a_nightly_needs_a_well_formed_stamp(self):
        with self.assertRaises(ValueError):
            release.plan("refs/heads/nightly", "2026-09-23")

    def test_the_two_apps_never_share_a_bundle_name_or_asset(self):
        main, nightly = release.plan("refs/tags/v1.0.0", STAMP), release.plan("refs/heads/nightly", STAMP)
        for key in ("bundle_id", "product", "dmg", "dsyms", "volume", "scheme", "configuration"):
            with self.subTest(key=key):
                self.assertNotEqual(main[key], nightly[key])


class IOSPlanTests(unittest.TestCase):
    """Only a push to nightly uploads the iOS client, to TestFlight internal testing."""

    def test_a_push_to_nightly_with_the_key_uploads_to_testflight_internal(self):
        p = release.plan("refs/heads/nightly", STAMP, asc_key=True)
        self.assertTrue(p["build"])
        self.assertTrue(p["ios"])
        self.assertEqual((p["ios_scheme"], p["ios_configuration"], p["ios_product"]),
                         ("Shepherd iOS", "Release", "Shepherd iOS.app"))
        self.assertEqual(p["ios_bundle_id"], "com.bailycase.shepherd.ios")
        self.assertEqual(p["ios_export_options"], "App/iOS/ExportOptions.plist")
        self.assertEqual(p["ios_testing"], "internal")

    def test_without_the_key_the_upload_is_skipped_and_the_mac_nightly_still_builds(self):
        p = release.plan("refs/heads/nightly", STAMP)
        self.assertTrue(p["build"])
        self.assertFalse(p["ios"])
        for secret in release.IOS_SECRETS:
            self.assertIn(secret, p["ios_reason"])
        self.assertEqual({k: v for k, v in p.items() if not k.startswith("ios")},
                         {k: v for k, v in release.plan("refs/heads/nightly", STAMP, asc_key=True).items()
                          if not k.startswith("ios")})

    def test_no_other_trigger_uploads_the_ios_client_yet(self):
        # Beta tags (external testing) and stable tags (the App Store) are later lanes.
        for ref in ("refs/tags/v1.2.3", "refs/tags/v1.3.0-beta.2", "refs/tags/v1.3.0-rc.1", "refs/tags/vnext",
                    "refs/heads/master", "refs/heads/feat/native-redesign", "refs/heads/nightly-old",
                    "refs/pull/32/merge"):
            with self.subTest(ref=ref):
                p = release.plan(ref, STAMP, asc_key=True)
                self.assertFalse(p["ios"])
                self.assertTrue(p["ios_reason"])

    def test_a_rerun_that_already_published_its_nightly_uploads_nothing(self):
        # The re-run would reuse the build number, which TestFlight refuses as a redundant binary.
        p = release.plan("refs/heads/nightly", STAMP, 2, "nightly-202609232159", asc_key=True)
        self.assertFalse(p["ios"])
        self.assertIn("nightly-202609232159", p["ios_reason"])

    def test_the_plan_command_takes_the_key_flag_anywhere(self):
        for args, ios in ((["refs/heads/nightly", STAMP], False),
                          (["refs/heads/nightly", STAMP, "--asc-key"], True),
                          (["refs/heads/nightly", STAMP, "1", "", "--asc-key"], True),
                          (["--asc-key", "refs/heads/nightly", STAMP, "1", ""], True),
                          (["refs/tags/v1.2.3", STAMP, "1", "", "--asc-key"], False)):
            with self.subTest(args=args):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(release.main(["plan", *args]), 0)
                self.assertEqual(json.loads(out.getvalue().strip().removeprefix("plan="))["ios"], ios)

    def test_the_ios_client_shares_no_identity_with_the_mac_apps(self):
        for app in release.APPS.values():
            with self.subTest(app=app.key):
                self.assertNotEqual(release.IOS.bundle_id, app.bundle_id)
                self.assertNotEqual(release.IOS.product, app.product)
                self.assertNotEqual(release.IOS.scheme, app.scheme)


class RouteTests(unittest.TestCase):
    """Which feeds each published release lands in when the appcasts are rebuilt."""

    def test_each_tag_form_lands_in_its_feeds(self):
        cases = [
            ("v1.2.3", ("Shepherd.dmg", "Shepherd-v1.2.3.dmg", ["stable", "beta"])),
            ("v1.3.0-beta.2", ("Shepherd.dmg", "Shepherd-v1.3.0-beta.2.dmg", ["beta"])),
            (f"nightly-{STAMP}", ("Shepherd-Nightly.dmg", f"Shepherd-Nightly-nightly-{STAMP}.dmg", ["shepherd-nightly"])),
        ]
        for tag, expected in cases:
            with self.subTest(tag=tag):
                self.assertEqual(release.route(tag), expected)

    def test_rc_releases_and_strays_land_nowhere(self):
        for tag in ("v0.1.0-rc.1", "v1.2", "nightly-latest", "something"):
            with self.subTest(tag=tag):
                self.assertIsNone(release.route(tag))

    def test_nightly_releases_feed_shepherd_nightly_only_through_its_own_dmg(self):
        # Nightlies from before the split carry Shepherd.dmg: the download of
        # Shepherd-Nightly.dmg fails for them, so a main-app build never enters this feed.
        asset, _, feeds = release.route(f"nightly-{STAMP}")
        self.assertEqual(asset, "Shepherd-Nightly.dmg")
        self.assertEqual(feeds, ["shepherd-nightly"])

    def test_no_main_app_release_reaches_shepherd_nightlys_feed(self):
        for tag in ("v1.2.3", "v1.3.0-beta.2"):
            with self.subTest(tag=tag):
                self.assertNotIn("shepherd-nightly", release.route(tag)[2])

    def test_latest_is_the_newest_tag_each_feed_carries(self):
        tags = [f"nightly-{STAMP}", "v0.1.0-rc.1", "v0.2.0-beta.1", "v0.1.0", "v0.1.0-beta.6"]
        self.assertEqual(release.latest("shepherd-nightly", tags), f"nightly-{STAMP}")
        self.assertEqual(release.latest("beta", tags), "v0.2.0-beta.1")
        self.assertEqual(release.latest("stable", tags), "v0.1.0")
        self.assertIsNone(release.latest("stable", ["v0.2.0-beta.1"]))


class FeedTests(unittest.TestCase):
    def test_every_feed_has_its_gh_pages_name_and_channel_tag(self):
        self.assertEqual(
            [(f.dir, f.file, f.channel, f.app) for f in release.FEEDS],
            [("stable", "appcast.xml", "", "main"),
             ("beta", "appcast-beta.xml", "beta", "main"),
             ("shepherd-nightly", "appcast-shepherd-nightly.xml", "", "nightly")],
        )

    def test_fix_urls_points_each_archive_at_its_tags_asset(self):
        xml = feed(item("5", archive="Shepherd-v1.2.3.dmg"), item("6", archive="Shepherd-v1.3.0-beta.1.dmg"))
        fixed = release.fix_urls(xml, "beta")
        self.assertIn("releases/download/v1.2.3/Shepherd.dmg\"", fixed)
        self.assertIn("releases/download/v1.3.0-beta.1/Shepherd.dmg\"", fixed)

        nightly = release.fix_urls(feed(item("7", archive=f"Shepherd-Nightly-nightly-{STAMP}.dmg")), "shepherd-nightly")
        self.assertIn(f"releases/download/nightly-{STAMP}/Shepherd-Nightly.dmg\"", nightly)

    def test_point_deltas_moves_deltas_to_the_release_holding_them(self):
        xml = feed(item("7", deltas=["Shepherd7-6.delta"]))
        pointed = release.point_deltas(xml, "v1.3.0-beta.2", ["Shepherd7-6.delta"])
        self.assertIn("download/v1.3.0-beta.2/Shepherd7-6.delta\"", pointed)

    def test_shepherd_nightly_deltas_upload_without_the_space_in_their_name(self):
        # generate_appcast names deltas after the app and percent-encodes the URL.
        name = "Shepherd Nightly63-61.delta"
        self.assertEqual(release.delta_asset_name(name), "Shepherd-Nightly63-61.delta")
        xml = feed(item("63", deltas=["Shepherd%20Nightly63-61.delta"]))
        pointed = release.point_deltas(xml, f"nightly-{STAMP}", [name])
        self.assertIn(f"download/nightly-{STAMP}/Shepherd-Nightly63-61.delta\"", pointed)
        self.assertNotIn("%20", pointed)

    def test_the_deltas_command_renames_and_lists_what_to_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            names = ["Shepherd Nightly63-61.delta", "Shepherd Nightly63-62.delta"]
            for name in names:
                open(os.path.join(directory, name), "w").close()
            with open(os.path.join(directory, "appcast.xml"), "w", encoding="utf-8") as f:
                f.write(feed(item("63", deltas=[n.replace(" ", "%20") for n in names])))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(release.main(["deltas", directory, f"nightly-{STAMP}"]), 0)
            uploads = out.getvalue().split()
            self.assertEqual([os.path.basename(p) for p in uploads],
                             ["Shepherd-Nightly63-61.delta", "Shepherd-Nightly63-62.delta"])
            self.assertTrue(all(os.path.isfile(p) for p in uploads))
            with open(os.path.join(directory, "appcast.xml"), encoding="utf-8") as f:
                xml = f.read()
            self.assertEqual(xml.count(f"download/nightly-{STAMP}/Shepherd-Nightly63-6"), 2)

    def test_publish_writes_every_feed_and_the_legacy_aliases(self):
        with tempfile.TemporaryDirectory() as root:
            casts, pages = os.path.join(root, "casts"), os.path.join(root, "pages")
            os.makedirs(pages)
            sources = {
                "stable": feed(item("25")),
                "beta": feed(item("60", "beta"), item("25", "beta")),
                "shepherd-nightly": feed(item("61", archive=f"Shepherd-Nightly-nightly-{STAMP}.dmg")),
            }
            for directory, xml in sources.items():
                os.makedirs(os.path.join(casts, directory))
                with open(os.path.join(casts, directory, "appcast.xml"), "w") as f:
                    f.write(xml)

            written = release.publish(casts, pages)

            self.assertEqual(sorted(written), sorted(os.listdir(pages)))
            self.assertEqual(sorted(written), ["appcast-beta.xml", "appcast-nightly.xml", "appcast-rc.xml",
                                               "appcast-shepherd-nightly.xml", "appcast.xml"])
            def read(name):
                with open(os.path.join(pages, name), encoding="utf-8") as f:
                    return f.read()
            self.assertEqual(read("appcast.xml"), sources["stable"])
            self.assertEqual(read("appcast-beta.xml"), sources["beta"])
            self.assertEqual(read("appcast-shepherd-nightly.xml"), sources["shepherd-nightly"])
            # Old rc and nightly installs of Shepherd read the beta feed's items on the default
            # channel, which Sparkle shows whatever channels a build allows (the first nightly
            # builds allowed none).
            for alias in ("appcast-rc.xml", "appcast-nightly.xml"):
                with self.subTest(alias=alias):
                    xml = read(alias)
                    self.assertEqual(xml, sources["beta"].replace("<sparkle:channel>beta</sparkle:channel>", ""))
                    self.assertNotIn("sparkle:channel", xml)
                    self.assertEqual(xml.count("<item>"), 2)
                    self.assertNotIn("Shepherd-Nightly", xml)

    def test_untag_drops_every_channel_element_and_its_indentation(self):
        xml = "<item>\n    <title>62</title>\n    <sparkle:channel>beta</sparkle:channel>\n    <sparkle:version>62</sparkle:version>\n</item>"
        self.assertEqual(release.untag(xml), "<item>\n    <title>62</title>\n    <sparkle:version>62</sparkle:version>\n</item>")


class VerifyAppTests(unittest.TestCase):
    def make_app(self, root, product, **info):
        path = os.path.join(root, product)
        os.makedirs(os.path.join(path, "Contents", "MacOS"))
        executable = info.get("CFBundleExecutable")
        if executable:
            open(os.path.join(path, "Contents", "MacOS", executable), "w").close()
        with open(os.path.join(path, "Contents", "Info.plist"), "wb") as f:
            plistlib.dump(info, f)
        return path

    def info(self, key, **overrides):
        app = release.APPS[key]
        info = {
            "CFBundleIdentifier": app.bundle_id,
            "CFBundleName": app.name,
            "CFBundleDisplayName": app.name,
            "CFBundleExecutable": app.name,
            "CFBundleShortVersionString": "1.0.0",
            "SUFeedURL": release.REPOSITORY_PAGES + app.appcast,
            "SUPublicEDKey": "key",
        }
        info.update(overrides)
        return info

    def test_each_built_app_matches_its_own_identity(self):
        for key in release.APPS:
            with self.subTest(app=key), tempfile.TemporaryDirectory() as root:
                path = self.make_app(root, release.APPS[key].product, **self.info(key))
                self.assertEqual(release.verify_app(path, key, "1.0.0"), [])

    def test_a_nightly_build_with_the_main_feed_or_id_is_refused(self):
        for override in ({"SUFeedURL": release.REPOSITORY_PAGES + "appcast.xml"},
                         {"CFBundleIdentifier": "com.bailycase.shepherd"},
                         {"CFBundleName": "Shepherd"}):
            with self.subTest(override=override), tempfile.TemporaryDirectory() as root:
                path = self.make_app(root, "Shepherd Nightly.app", **self.info("nightly", **override))
                self.assertEqual(len(release.verify_app(path, "nightly")), 1)

    def test_a_wrong_bundle_name_version_or_missing_executable_is_refused(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.make_app(root, "Shepherd.app", **self.info("nightly"))
            self.assertTrue(release.verify_app(path, "nightly"))
        with tempfile.TemporaryDirectory() as root:
            path = self.make_app(root, "Shepherd.app", **self.info("main"))
            self.assertTrue(release.verify_app(path, "main", "2.0.0"))
        with tempfile.TemporaryDirectory() as root:
            info = self.info("main")
            path = self.make_app(root, "Shepherd.app", **info)
            os.remove(os.path.join(path, "Contents", "MacOS", info["CFBundleExecutable"]))
            self.assertTrue(release.verify_app(path, "main"))


class VerifyIOSTests(unittest.TestCase):
    def make_app(self, root, product="Shepherd iOS.app", privacy=True, **overrides):
        path = os.path.join(root, product)
        os.makedirs(path)
        info = {
            "CFBundleIdentifier": "com.bailycase.shepherd.ios",
            "CFBundleExecutable": "Shepherd iOS",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "321",
            "ITSAppUsesNonExemptEncryption": False,
        }
        info.update(overrides)
        info = {k: v for k, v in info.items() if v is not None}
        if info.get("CFBundleExecutable"):
            open(os.path.join(path, info["CFBundleExecutable"]), "w").close()
        if privacy:
            open(os.path.join(path, "PrivacyInfo.xcprivacy"), "w").close()
        with open(os.path.join(path, "Info.plist"), "wb") as f:
            plistlib.dump(info, f)
        return path

    def test_an_archived_nightly_build_is_ready_to_upload(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(release.verify_ios(self.make_app(root), "321"), [])

    def test_what_app_store_connect_or_testers_would_trip_on_is_refused(self):
        cases = {
            "another app": {"CFBundleIdentifier": "com.bailycase.shepherd.nightly"},
            "another build number": {"CFBundleVersion": "1"},
            "a mac nightly version": {"CFBundleShortVersionString": "0.0.0-nightly.202609232100"},
            "four version parts": {"CFBundleShortVersionString": "1.2.3.4"},
            "no compliance answer": {"ITSAppUsesNonExemptEncryption": None},
            "non-exempt encryption": {"ITSAppUsesNonExemptEncryption": True},
            "no executable": {"CFBundleExecutable": None},
        }
        for name, overrides in cases.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as root:
                self.assertEqual(len(release.verify_ios(self.make_app(root, **overrides), "321")), 1)

    def test_a_wrong_bundle_name_or_missing_privacy_manifest_is_refused(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertTrue(release.verify_ios(self.make_app(root, product="Shepherd.app"), "321"))
        with tempfile.TemporaryDirectory() as root:
            self.assertTrue(release.verify_ios(self.make_app(root, privacy=False), "321"))

    def test_the_version_rule_takes_one_to_three_integers(self):
        for version, ok in (("1", True), ("0.1", True), ("0.1.0", True), ("10.20.30", True),
                            ("1.2.3.4", False), ("1.2.3-beta.1", False), ("v1.2.3", False), ("", False)):
            with self.subTest(version=version):
                self.assertEqual(bool(release.VERSION_STRING.match(version)), ok)


class ContractTests(unittest.TestCase):
    """Bundle ids, names and feeds are a contract between the Xcode project, the apps' Swift
    code and this script. Read the sources so drift fails here, before a release builds."""

    def read(self, *parts):
        with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
            return f.read()

    def target_configuration(self, name):
        project = self.read("Shepherd.xcodeproj", "project.pbxproj")
        blocks = re.findall(r"/\* %s \*/ = \{\n\t\t\tisa = XCBuildConfiguration;\n(.*?)\n\t\t\};" % name, project, re.S)
        mac = [b for b in blocks if "INFOPLIST_FILE = App/Info.plist;" in b]
        self.assertEqual(len(mac), 1, f"one Mac target configuration named {name}")
        return mac[0]

    def setting(self, block, key):
        m = re.search(r"\b%s = (\"?)(.*?)\1;" % key, block)
        self.assertIsNotNone(m, key)
        return m.group(2)

    def test_the_xcode_configurations_build_the_apps_this_script_ships(self):
        for app in release.APPS.values():
            with self.subTest(app=app.key):
                block = self.target_configuration(app.configuration)
                self.assertEqual(self.setting(block, "PRODUCT_BUNDLE_IDENTIFIER"), app.bundle_id)
                self.assertEqual(self.setting(block, "PRODUCT_NAME"), app.name)
                self.assertEqual(self.setting(block, "SHEPHERD_APPCAST"), app.appcast)

    def test_the_dev_build_shares_no_shipped_apps_identity(self):
        # Preferences, notifications and Sparkle's installer are keyed by bundle id, so a Dev
        # build on a shipped id would reach into the installed app beside it.
        dev = self.setting(self.target_configuration("Debug"), "PRODUCT_BUNDLE_IDENTIFIER")
        self.assertEqual(dev, "com.bailycase.shepherd.dev")
        self.assertNotIn(dev, [app.bundle_id for app in release.APPS.values()])

    def test_each_app_has_its_scheme(self):
        for app in release.APPS.values():
            with self.subTest(app=app.key):
                scheme = self.read("Shepherd.xcodeproj", "xcshareddata", "xcschemes", f"{app.scheme}.xcscheme")
                self.assertIn(f'<ArchiveAction\n      buildConfiguration = "{app.configuration}"', scheme)

    def test_info_plist_takes_the_feed_from_the_configuration(self):
        info = plistlib.loads(self.read("App", "Info.plist").encode())
        self.assertEqual(info["SUFeedURL"], release.REPOSITORY_PAGES + "$(SHEPHERD_APPCAST)")

    def ios_configurations(self):
        project = self.read("Shepherd.xcodeproj", "project.pbxproj")
        blocks = re.findall(r"/\* \w+ \*/ = \{\n\t\t\tisa = XCBuildConfiguration;\n(.*?)\n\t\t\};", project, re.S)
        ios = [b for b in blocks if f"PRODUCT_BUNDLE_IDENTIFIER = {release.IOS.bundle_id};" in b]
        self.assertEqual(len(ios), 3, "Debug, Release and Nightly iOS configurations")
        return ios

    def test_every_ios_configuration_is_ready_for_cloud_signing_and_testflight(self):
        export = plistlib.loads(self.read(*release.IOS.export_options.split("/")).encode())
        for block in self.ios_configurations():
            with self.subTest(configuration=self.setting(block, "name")):
                self.assertEqual(self.setting(block, "CODE_SIGN_STYLE"), "Automatic")
                self.assertEqual(self.setting(block, "DEVELOPMENT_TEAM"), export["teamID"])
                self.assertEqual(self.setting(block, "GENERATE_INFOPLIST_FILE"), "YES")
                self.assertEqual(self.setting(block, "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption"), "NO")
                self.assertEqual(self.setting(block, "PRODUCT_NAME"), "$(TARGET_NAME)")
                # Automatic signing picks these; a pinned one breaks the cloud-signed export.
                for pinned in ("CODE_SIGN_IDENTITY", "PROVISIONING_PROFILE_SPECIFIER", "CODE_SIGN_ENTITLEMENTS"):
                    self.assertNotIn(pinned, block)
                # The Mac target is found by its INFOPLIST_FILE; the iOS target must not share it.
                self.assertNotRegex(block, r"\bINFOPLIST_FILE = ")

    def test_every_ios_marketing_version_is_one_testflight_accepts(self):
        for block in self.ios_configurations():
            self.assertRegex(self.setting(block, "MARKETING_VERSION"), release.VERSION_STRING)

    def test_the_ios_scheme_archives_the_planned_configuration(self):
        scheme = self.read("Shepherd.xcodeproj", "xcshareddata", "xcschemes", f"{release.IOS.scheme}.xcscheme")
        self.assertIn(f'<ArchiveAction\n      buildConfiguration = "{release.IOS.configuration}"', scheme)
        self.assertIn(f'BuildableName = "{release.IOS.product}"', scheme)

    def test_the_ios_client_ships_its_privacy_manifest(self):
        # App/iOS is a synchronized folder: every file in it joins the target unless excepted.
        project = self.read("Shepherd.xcodeproj", "project.pbxproj")
        self.assertRegex(project, r"/\* iOS \*/ = \{\n\t+isa = PBXFileSystemSynchronizedRootGroup;")
        exceptions = re.search(r"membershipExceptions = \((.*?)\);", project, re.S)
        self.assertNotIn("PrivacyInfo.xcprivacy", exceptions.group(1) if exceptions else "")
        manifest = plistlib.loads(self.read("App", "iOS", "PrivacyInfo.xcprivacy").encode())
        self.assertFalse(manifest["NSPrivacyTracking"])
        reasons = {t["NSPrivacyAccessedAPIType"]: t["NSPrivacyAccessedAPITypeReasons"]
                   for t in manifest["NSPrivacyAccessedAPITypes"]}
        self.assertEqual(reasons, {"NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"]})

    def test_the_export_uploads_a_cloud_signed_internal_testflight_build(self):
        export = plistlib.loads(self.read(*release.IOS.export_options.split("/")).encode())
        self.assertEqual(export, {
            "method": "app-store-connect",
            "destination": "upload",
            "signingStyle": "automatic",
            "teamID": "4J6D7M7D79",
            # Keeps CFBundleVersion the workflow's run number.
            "manageAppVersionAndBuildNumber": False,
            "uploadSymbols": True,
            "testFlightInternalTestingOnly": release.IOS.testing == "internal",
        })

    def test_the_apps_know_the_same_bundle_ids_and_feeds(self):
        edition = self.read("Sources", "ShepherdProtocol", "ShepherdEdition.swift")
        for app in release.APPS.values():
            self.assertTrue(f'"{app.bundle_id}"' in edition, f"ShepherdEdition lacks {app.bundle_id}")
        updater = self.read("Sources", "ShepherdApp", "AppUpdater.swift")
        for f in release.FEEDS:
            self.assertTrue(f'"{f.file}"' in updater, f"UpdateChannel lacks {f.file}")


def build(version, state="VALID", expired=False, id=None):
    return release.AppStoreBuild(id or f"id-{version}", version, state, expired, f"2026-09-{int(version.split('.')[0]) % 28 + 1:02d}T10:00:00Z")


def versions(builds):
    return [b.version for b in builds]


class RetirePlanTests(unittest.TestCase):
    """Which TestFlight builds expire once a new one is uploaded."""

    def test_the_rule_table(self):
        #  builds (version, state[, expired]), awaited build -> status, kept, expired
        table = [
            ("only one build",
             [("100", "VALID")], None, "retire", "100", []),
            ("mixed versions keep the highest build number, not the newest upload",
             [("99", "VALID"), ("101", "VALID"), ("100", "VALID"), ("9", "VALID")], None, "retire", "101", ["100", "99", "9"]),
            ("already-expired builds are neither kept nor expired again",
             [("103", "VALID", True), ("101", "VALID"), ("100", "VALID", True), ("99", "VALID")], None, "retire", "101", ["99"]),
            ("a newer build still processing is left alone",
             [("102", "PROCESSING"), ("101", "VALID"), ("100", "VALID")], None, "retire", "101", ["100"]),
            ("a newer build that failed is left alone",
             [("102", "FAILED"), ("101", "VALID"), ("100", "VALID")], None, "retire", "101", ["100"]),
            ("an older build still processing may become installable, so it expires",
             [("101", "VALID"), ("100", "PROCESSING")], None, "retire", "101", ["100"]),
            ("older builds that never processed are never installable, so they stay",
             [("101", "VALID"), ("100", "FAILED"), ("99", "INVALID"), ("98", "VALID")], None, "retire", "101", ["98"]),
            ("no processed build expires nothing",
             [("101", "PROCESSING"), ("100", "FAILED")], None, "none", None, []),
            ("no builds at all expires nothing",
             [], None, "none", None, []),
            ("the awaited build still processing waits",
             [("101", "PROCESSING"), ("100", "VALID"), ("99", "VALID")], "101", "wait", None, []),
            ("the awaited build not uploaded yet waits",
             [("100", "VALID"), ("99", "VALID")], "101", "wait", None, []),
            ("the awaited build that failed expires nothing",
             [("101", "FAILED"), ("100", "VALID"), ("99", "VALID")], "101", "failed", None, []),
            ("the awaited build that was invalid expires nothing",
             [("101", "INVALID"), ("100", "VALID")], "101", "failed", None, []),
            ("the awaited build once processed is kept",
             [("101", "VALID"), ("100", "VALID"), ("99", "VALID")], "101", "retire", "101", ["100", "99"]),
            ("a newer processed build than the awaited one wins",
             [("102", "VALID"), ("101", "VALID"), ("100", "VALID")], "101", "retire", "102", ["101", "100"]),
            ("a newer processing build than the awaited one is left alone",
             [("102", "PROCESSING"), ("101", "VALID"), ("100", "VALID")], "101", "retire", "101", ["100"]),
            ("an expired awaited build is as good as missing",
             [("101", "VALID", True), ("100", "VALID")], "101", "wait", None, []),
            ("an awaited build a later run already expired is superseded, so nothing waits",
             [("102", "VALID"), ("101", "VALID", True), ("100", "VALID")], "101", "retire", "102", ["100"]),
            ("an awaited build still processing under a newer processed one is superseded",
             [("102", "VALID"), ("101", "PROCESSING"), ("100", "VALID")], "101", "retire", "102", ["101", "100"]),
            ("an awaited build that failed under a newer processed one is superseded",
             [("102", "VALID"), ("101", "FAILED"), ("100", "VALID")], "101", "retire", "102", ["100"]),
            ("a newer build that is only processing does not supersede the awaited one",
             [("102", "PROCESSING"), ("101", "PROCESSING"), ("100", "VALID")], "101", "wait", None, []),
            ("dotted build numbers compare numerically",
             [("1.10", "VALID"), ("1.9", "VALID"), ("1.2", "VALID")], None, "retire", "1.10", ["1.9", "1.2"]),
        ]
        for name, rows, awaited, status, kept, expired in table:
            with self.subTest(name):
                builds = [build(r[0], r[1], len(r) > 2 and r[2]) for r in rows]
                plan = release.retire_plan(builds, awaited)
                self.assertEqual(plan.status, status)
                self.assertEqual(plan.keep.version if plan.keep else None, kept)
                self.assertEqual(versions(plan.expire), expired)
                self.assertTrue(plan.reason)
                if plan.status == "retire":
                    live = [b for b in builds if not b.expired]
                    self.assertEqual(sorted(versions([plan.keep, *plan.expire, *plan.left])), sorted(versions(live)))

    def test_nothing_numbered_at_or_above_the_kept_build_ever_expires(self):
        builds = [build(str(n), state) for n in range(90, 110)
                  for state in (("VALID", "PROCESSING", "FAILED", "INVALID")[n % 4],)]
        plan = release.retire_plan(builds)
        self.assertTrue(all(b.number < plan.keep.number for b in plan.expire))

    def test_a_build_number_that_is_not_one_is_left_alone(self):
        plan = release.retire_plan([build("101"), release.AppStoreBuild("odd", "1.0b", "VALID"), build("100")])
        self.assertEqual((plan.keep.version, versions(plan.expire), versions(plan.left)), ("101", ["100"], ["1.0b"]))
        with self.assertRaises(ValueError):
            release.retire_plan([], "latest")


def der_int(value):
    value = value.lstrip(b"\0") or b"\0"
    if value[0] & 0x80:
        value = b"\0" + value
    return b"\x02" + bytes([len(value)]) + value


def der_signature(r, s):
    body = der_int(r) + der_int(s)
    return b"\x30" + bytes([len(body)]) + body


class SignatureTests(unittest.TestCase):
    """OpenSSL writes ECDSA signatures as DER; a JWT carries raw r||s."""

    def test_known_vectors(self):
        r, s = bytes(range(1, 33)), bytes(range(33, 65))
        der = bytes.fromhex("3044" "0220" + r.hex() + "0220" + s.hex())
        self.assertEqual(release.der_signature_to_raw(der), r + s)

    def test_a_high_bit_integer_arrives_as_33_bytes_and_leaves_as_32(self):
        r, s = b"\xff" * 32, b"\x80" + b"\x01" * 31
        der = bytes.fromhex("3046" "022100" + r.hex() + "022100" + s.hex())
        self.assertEqual(release.der_signature_to_raw(der), r + s)

    def test_short_integers_are_padded_with_leading_zeros(self):
        for r, s in ((b"\x01", b"\x7f" * 31), (b"\x00" * 3 + b"\x42" * 29, b"\x05"), (b"\x00" * 32, b"\x00" * 32)):
            with self.subTest(r=r.hex(), s=s.hex()):
                raw = release.der_signature_to_raw(der_signature(r, s))
                self.assertEqual(raw, r.rjust(32, b"\0") + s.rjust(32, b"\0"))
                self.assertEqual(len(raw), 64)

    def test_long_form_lengths_are_read(self):
        r, s = b"\x80" * 32, b"\x81" * 32
        body = der_int(r) + der_int(s)
        self.assertEqual(release.der_signature_to_raw(b"\x30\x81" + bytes([len(body)]) + body), r + s)

    def test_malformed_signatures_are_refused(self):
        good = der_signature(b"\x11" * 32, b"\x22" * 32)
        bad = {
            "empty": b"",
            "not a sequence": b"\x31" + good[1:],
            "sequence too long": good[:1] + bytes([good[1] + 1]) + good[2:],
            "truncated": good[:-1],
            "trailing bytes": good[:1] + bytes([good[1] + 1]) + good[2:] + b"\x00",
            "not an integer": good[:2] + b"\x03" + good[3:],
            "negative": der_signature(b"\x11" * 32, b"\x22" * 32).replace(b"\x02\x20\x11", b"\x02\x20\x91", 1),
            "too large": der_signature(b"\x11" * 33, b"\x22" * 32),
            "zero length integer": b"\x30\x04\x02\x00\x02\x00",
            "one integer": b"\x30\x22" + der_int(b"\x11" * 32),
        }
        for name, der in bad.items():
            with self.subTest(name), self.assertRaises(ValueError):
                release.der_signature_to_raw(der)


def b64url_decode(part):
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


class TokenTests(unittest.TestCase):
    """The ES256 JWT the App Store Connect API takes."""

    def test_the_header_and_payload_and_the_signature_over_them(self):
        r, s = b"\x80" + b"\x01" * 31, b"\x02" * 32
        signed = []

        def sign(data):
            signed.append(data)
            return der_signature(r, s)

        token = release.app_store_connect_token("KEY123", "issuer-uuid", 1_800_000_000, sign)
        header, payload, signature = token.split(".")
        self.assertEqual(json.loads(b64url_decode(header)), {"alg": "ES256", "kid": "KEY123", "typ": "JWT"})
        self.assertEqual(json.loads(b64url_decode(payload)), {
            "iss": "issuer-uuid", "iat": 1_800_000_000, "exp": 1_800_000_900, "aud": "appstoreconnect-v1"})
        self.assertEqual(signed, [f"{header}.{payload}".encode()])
        self.assertEqual(b64url_decode(signature), r + s)
        self.assertNotIn("=", token)

    def test_a_token_never_outlives_twenty_minutes(self):
        for lifetime in (0, 1201, -5):
            with self.subTest(lifetime=lifetime), self.assertRaises(ValueError):
                release.app_store_connect_token("k", "i", 0, lambda _: b"", lifetime)

    def test_a_token_asks_for_less_than_the_limit_so_clock_skew_is_not_refused(self):
        self.assertLessEqual(release.TOKEN_LIFETIME, release.JWT_LIFETIME - 60)

    def test_the_token_source_renews_a_token_before_it_expires(self):
        now = [1000.0]
        calls = []

        def sign(data):
            calls.append(data)
            return der_signature(b"\x01" * 32, b"\x02" * 32)

        token = release.token_source("k", "i", sign, clock=lambda: now[0])
        first = token()
        now[0] += 700
        self.assertEqual(token(), first)
        now[0] += 100   # 800 s old: inside the two-minute margin of a 900 s token
        self.assertNotEqual(token(), first)
        self.assertEqual(len(calls), 2)

    @unittest.skipUnless(shutil.which("openssl"), "needs the openssl CLI")
    def test_the_openssl_signer_makes_a_signature_the_key_verifies(self):
        with tempfile.TemporaryDirectory() as d:
            key, public = make_p8(d)
            token = release.app_store_connect_token("k", "i", 1_800_000_000, release.openssl_signer(key))
            self.assertTrue(verify_token(token, public, d))
            tampered = token.rsplit(".", 1)[0] + "x." + token.rsplit(".", 1)[1]
            self.assertFalse(verify_token(tampered, public, d))

    def test_a_signer_that_fails_says_so_without_the_key(self):
        with tempfile.TemporaryDirectory() as d:
            missing = os.path.join(d, "AuthKey.p8")
            with self.assertRaises(release.AppStoreConnectError):
                release.openssl_signer(missing)(b"data")


def make_p8(directory):
    pem, key, public = (os.path.join(directory, n) for n in ("ec.pem", "AuthKey.p8", "public.pem"))
    for args in (["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", pem],
                 ["pkcs8", "-topk8", "-nocrypt", "-in", pem, "-out", key],
                 ["ec", "-in", pem, "-pubout", "-out", public]):
        subprocess.run(["openssl", *args], check=True, capture_output=True)
    return key, public


def verify_token(token, public, directory):
    signing_input, signature = token.rsplit(".", 1)
    raw = b64url_decode(signature)
    path = os.path.join(directory, "signature.der")
    with open(path, "wb") as f:
        f.write(der_signature(raw[:32], raw[32:]))
    result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", public, "-signature", path],
                            input=signing_input.encode(), capture_output=True)
    return result.returncode == 0


API = "https://api.example.test"


class FakeOpener:
    """Answers the client's requests from a table of (method, path) -> (status, body)."""

    def __init__(self, routes):
        self.routes = routes
        self.requests = []

    def __call__(self, request):
        url = urllib.parse.urlsplit(request.full_url)
        body = json.loads(request.data) if request.data else None
        self.requests.append((request.get_method(), request.full_url, dict(request.header_items()), body))
        key = (request.get_method(), url.path + ("?" + url.query if url.query else ""))
        for (method, prefix), answer in self.routes.items():
            if key[0] == method and key[1].startswith(prefix):
                status, payload = answer(body) if callable(answer) else answer
                return status, json.dumps(payload).encode() if payload is not None else b""
        return 404, json.dumps({"errors": [{"detail": f"no route for {key}"}]}).encode()


def build_json(version, state="VALID", expired=False):
    return {"type": "builds", "id": f"id-{version}",
            "attributes": {"version": version, "processingState": state, "expired": expired,
                           "uploadedDate": "2026-09-25T10:00:00-07:00"}}


class AppStoreConnectClientTests(unittest.TestCase):
    def client(self, routes):
        opener = FakeOpener(routes)
        return release.AppStoreConnect(lambda: "TOKEN", API, opener), opener

    def test_the_app_is_found_by_its_exact_bundle_id(self):
        client, opener = self.client({("GET", "/v1/apps?"): (200, {"data": [
            {"id": "wrong", "attributes": {"bundleId": "com.bailycase.shepherd.ios.widget"}},
            {"id": "123", "attributes": {"bundleId": "com.bailycase.shepherd.ios"}}]})})
        self.assertEqual(client.app_id("com.bailycase.shepherd.ios"), "123")
        method, url, headers, _ = opener.requests[0]
        self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlsplit(url).query),
                         {"filter[bundleId]": ["com.bailycase.shepherd.ios"], "fields[apps]": ["bundleId"]})
        self.assertEqual(headers["Authorization"], "Bearer TOKEN")

    def test_no_app_is_an_error(self):
        client, _ = self.client({("GET", "/v1/apps?"): (200, {"data": []})})
        with self.assertRaises(release.AppStoreConnectError):
            client.app_id("com.bailycase.shepherd.ios")

    def test_builds_follow_every_next_page(self):
        client, opener = self.client({
            ("GET", "/v1/builds?cursor=2"): (200, {"data": [build_json("98"), build_json("97", expired=True)],
                                                   "links": {"next": None}}),
            ("GET", "/v1/builds?"): (200, {"data": [build_json("100", "PROCESSING"), build_json("99")],
                                           "links": {"next": f"{API}/v1/builds?cursor=2"}}),
        })
        builds = client.builds("123")
        self.assertEqual([(b.id, b.version, b.processing_state, b.expired) for b in builds],
                         [("id-100", "100", "PROCESSING", False), ("id-99", "99", "VALID", False),
                          ("id-98", "98", "VALID", False), ("id-97", "97", "VALID", True)])
        first = urllib.parse.parse_qs(urllib.parse.urlsplit(opener.requests[0][1]).query)
        self.assertEqual(first, {"filter[app]": ["123"], "filter[expired]": ["false"], "sort": ["-uploadedDate"],
                                 "limit": ["200"], "fields[builds]": ["version,processingState,expired,uploadedDate"]})
        self.assertEqual(len(opener.requests), 2)

    def test_a_next_page_elsewhere_never_gets_the_token(self):
        client, opener = self.client({("GET", "/v1/builds?"): (200, {
            "data": [], "links": {"next": "https://elsewhere.example/v1/builds?cursor=2"}})})
        with self.assertRaises(release.AppStoreConnectError):
            client.builds("123")
        self.assertEqual(len(opener.requests), 1)

    def test_a_redirect_is_refused_so_the_token_never_follows_it(self):
        seen = {"elsewhere": []}

        class Elsewhere(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                seen["elsewhere"].append(self.headers.get("Authorization"))
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"{}")

        elsewhere = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Elsewhere)

        class Redirecting(Elsewhere):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{elsewhere.server_port}/v1/apps")
                self.send_header("Content-Length", "0")
                self.end_headers()

        api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Redirecting)
        for server in (elsewhere, api):
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
        client = release.AppStoreConnect(lambda: "TOKEN", f"http://127.0.0.1:{api.server_port}")
        with self.assertRaises(release.AppStoreConnectError) as caught:
            client.app_id("com.bailycase.shepherd.ios")
        self.assertIn("302", str(caught.exception))
        self.assertEqual(seen["elsewhere"], [])

    def test_a_next_page_that_loops_is_an_error(self):
        client, _ = self.client({("GET", "/v1/builds?"): (200, {
            "data": [], "links": {"next": f"{API}/v1/builds?cursor=2"}})})
        with self.assertRaises(release.AppStoreConnectError):
            client.builds("123")

    def test_expiring_patches_the_build(self):
        client, opener = self.client({("PATCH", "/v1/builds/id-99"): (200, {"data": build_json("99", expired=True)})})
        client.expire(build("99"))
        method, url, headers, body = opener.requests[0]
        self.assertEqual((method, url), ("PATCH", f"{API}/v1/builds/id-99"))
        self.assertEqual(body, {"data": {"type": "builds", "id": "id-99", "attributes": {"expired": True}}})
        self.assertEqual(headers["Content-type"], "application/json")

    def test_errors_carry_the_apis_detail_and_whether_to_retry(self):
        for status, transient in ((403, False), (409, False), (429, True), (500, True), (503, True)):
            with self.subTest(status=status):
                client, _ = self.client({("GET", "/v1/apps?"): (status, {"errors": [{"detail": "nope"}]})})
                with self.assertRaises(release.AppStoreConnectError) as caught:
                    client.app_id("com.bailycase.shepherd.ios")
                self.assertIn("nope", str(caught.exception))
                self.assertIn(str(status), str(caught.exception))
                self.assertNotIn("TOKEN", str(caught.exception))
                self.assertEqual(caught.exception.transient, transient)


class FakeClient:
    """Serves one build list per poll, then repeats the last."""

    def __init__(self, polls, fail_expiring=()):
        self.polls = list(polls)
        self.fail_expiring = set(fail_expiring)
        self.expired = []

    def app_id(self, bundle_id):
        assert bundle_id == release.IOS.bundle_id
        return "123"

    def builds(self, app_id):
        poll = self.polls.pop(0) if len(self.polls) > 1 else self.polls[0]
        if isinstance(poll, Exception):
            raise poll
        return poll

    def expire(self, b):
        if b.version in self.fail_expiring:
            raise release.AppStoreConnectError("HTTP 409: nope")
        self.expired.append(b.version)


class RetireTests(unittest.TestCase):
    def run_retire(self, client, **options):
        clock = [0.0]
        lines = []
        status = release.retire_testflight(client, release.IOS.bundle_id, clock=lambda: clock[0],
                                           sleep=lambda s: clock.__setitem__(0, clock[0] + s),
                                           log=lines.append, **options)
        return status, lines, clock[0]

    def test_waits_for_the_upload_to_process_then_expires_the_older_builds(self):
        client = FakeClient([[build("99")], [build("100", "PROCESSING"), build("99")],
                             [build("100"), build("99"), build("98")]])
        status, lines, elapsed = self.run_retire(client, waiting_for="100", interval=45, timeout=2700)
        self.assertEqual((status, client.expired, elapsed), (0, ["99", "98"], 90))
        self.assertIn("Kept build 100", "\n".join(lines))
        self.assertTrue(any(l.startswith("Expired build 99") for l in lines))

    def test_a_dry_run_expires_nothing_and_says_what_it_would(self):
        client = FakeClient([[build("100"), build("99")]])
        status, lines, _ = self.run_retire(client, dry_run=True)
        self.assertEqual((status, client.expired), (0, []))
        self.assertIn("Would expire build 99 (VALID, uploaded 2026-09-16T10:00:00Z)", lines)

    def test_gives_up_after_the_timeout_and_expires_nothing(self):
        client = FakeClient([[build("100", "PROCESSING"), build("99")]])
        status, lines, elapsed = self.run_retire(client, waiting_for="100", interval=45, timeout=2700)
        self.assertEqual((status, client.expired), (0, []))
        self.assertLessEqual(elapsed, 2700)
        self.assertTrue(lines[-1].startswith("::warning") and "Nothing was expired" in lines[-1])

    def test_an_upload_that_failed_processing_expires_nothing(self):
        client = FakeClient([[build("100", "FAILED"), build("99")]])
        status, lines, _ = self.run_retire(client, waiting_for="100")
        self.assertEqual((status, client.expired), (0, []))
        self.assertTrue(lines[-1].startswith("::warning"))

    def test_without_a_build_to_wait_for_it_keeps_the_newest_processed_one_at_once(self):
        client = FakeClient([[build("101", "PROCESSING"), build("100"), build("99")]])
        status, lines, elapsed = self.run_retire(client)
        self.assertEqual((status, client.expired, elapsed), (0, ["99"], 0))
        self.assertIn("Left build 101", "\n".join(lines))

    def test_a_transient_error_while_waiting_is_retried(self):
        client = FakeClient([release.AppStoreConnectError("HTTP 503", transient=True), [build("100"), build("99")]])
        status, _, _ = self.run_retire(client, waiting_for="100", interval=30)
        self.assertEqual((status, client.expired), (0, ["99"]))

    def test_a_permanent_error_stops_the_run(self):
        client = FakeClient([release.AppStoreConnectError("HTTP 401"), [build("100")]])
        with self.assertRaises(release.AppStoreConnectError):
            self.run_retire(client, waiting_for="100")

    def test_a_build_that_could_not_expire_fails_the_run_after_the_rest(self):
        client = FakeClient([[build("100"), build("99"), build("98")]], fail_expiring={"99"})
        status, lines, _ = self.run_retire(client)
        self.assertEqual((status, client.expired), (1, ["98"]))
        self.assertTrue(any(l.startswith("::error") and "build 99" in l for l in lines))


class FakeAppStoreConnect(http.server.BaseHTTPRequestHandler):
    """A local App Store Connect for the CLI: one app, two pages of builds, and PATCH."""

    def log_message(self, *args):
        pass

    def answer(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        state = self.server.state
        state["tokens"].append(self.headers.get("Authorization", ""))
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        base = f"http://127.0.0.1:{self.server.server_port}"
        if url.path == "/v1/apps" and query.get("filter[bundleId]") == [release.IOS.bundle_id]:
            return self.answer(200, {"data": [{"type": "apps", "id": "app-1",
                                               "attributes": {"bundleId": release.IOS.bundle_id}}]})
        if url.path == "/v1/builds" and query.get("cursor") == ["2"]:
            return self.answer(200, {"data": [build_json("98")], "links": {}})
        if url.path == "/v1/builds" and query.get("filter[app]") == ["app-1"]:
            state["polls"] += 1
            newest = build_json("101", "PROCESSING" if state["polls"] == 1 else "VALID")
            return self.answer(200, {"data": [newest, build_json("100"), build_json("99")],
                                     "links": {"next": f"{base}/v1/builds?cursor=2"}})
        self.answer(404, {"errors": [{"detail": f"no route for {self.path}"}]})

    def do_PATCH(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.state["patches"].append((self.path, body))
        self.answer(200, {"data": body["data"]})


@unittest.skipUnless(shutil.which("openssl"), "needs the openssl CLI")
class RetireCommandTests(unittest.TestCase):
    """retire-testflight end to end: a real key, the openssl signer, and a local API."""

    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeAppStoreConnect)
        self.server.state = {"tokens": [], "polls": 0, "patches": []}
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.key, self.public = make_p8(self.dir)

    def retire(self, *args, env=None):
        environment = {**os.environ, "APP_STORE_CONNECT_KEY_ID": "KEY123", "APP_STORE_CONNECT_ISSUER_ID": "issuer-uuid"}
        environment.update(env or {})
        return subprocess.run(
            [sys.executable, os.path.join(ROOT, "scripts", "release.py"), "retire-testflight",
             "--key-file", self.key, "--api", f"http://127.0.0.1:{self.server.server_port}",
             "--interval", "0.01", "--timeout", "30", *args],
            capture_output=True, text=True, env=environment, timeout=60)

    def test_a_dry_run_waits_for_the_upload_then_names_what_it_would_expire(self):
        result = self.retire("--wait-for-build", "101", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout
        self.assertIn("Waiting: build 101 (PROCESSING", out)
        self.assertIn("Kept build 101 (VALID", out)
        for version in ("100", "99", "98"):
            self.assertIn(f"Would expire build {version} (VALID", out)
        self.assertIn("::notice title=TestFlight::Kept build 101; would expire 3 older builds.", out)
        self.assertEqual(self.server.state["patches"], [])
        self.assertGreaterEqual(self.server.state["polls"], 2)
        with open(self.key) as f:
            key_text = f.read()
        tokens = self.server.state["tokens"]
        for secret in [key_text.strip(), *{t.removeprefix("Bearer ") for t in tokens}]:
            self.assertNotIn(secret, out + result.stderr)
        header, payload, _ = tokens[0].removeprefix("Bearer ").split(".")
        self.assertEqual(json.loads(b64url_decode(header)), {"alg": "ES256", "kid": "KEY123", "typ": "JWT"})
        claims = json.loads(b64url_decode(payload))
        self.assertEqual((claims["iss"], claims["aud"], claims["exp"] - claims["iat"]),
                         ("issuer-uuid", "appstoreconnect-v1", release.TOKEN_LIFETIME))
        self.assertTrue(verify_token(tokens[0].removeprefix("Bearer "), self.public, self.dir))

    def test_a_real_run_patches_every_older_build(self):
        result = self.retire("--wait-for-build", "101")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.state["patches"], [
            (f"/v1/builds/id-{v}", {"data": {"type": "builds", "id": f"id-{v}", "attributes": {"expired": True}}})
            for v in ("100", "99", "98")])
        self.assertIn("Expired build 98", result.stdout)

    def test_without_the_key_id_and_issuer_it_refuses(self):
        result = self.retire("--dry-run", env={"APP_STORE_CONNECT_KEY_ID": ""})
        self.assertEqual(result.returncode, 64)
        self.assertEqual(self.server.state["tokens"], [])

    def test_a_build_number_that_is_not_one_is_refused(self):
        result = self.retire("--wait-for-build", "101; rm -rf /")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.server.state["tokens"], [])


class RetireWorkflowTests(unittest.TestCase):
    """release.yml's retire-testflight job runs only after the testflight job uploads."""

    def block(self, text, key, indent=""):
        m = re.search(r"^%s%s:\n((?:%s[ ].*\n|\n)*)" % (indent, re.escape(key), indent), text, re.M)
        self.assertIsNotNone(m, key)
        return m.group(1)

    def setUp(self):
        with open(os.path.join(ROOT, ".github", "workflows", "release.yml"), encoding="utf-8") as f:
            self.release = f.read()
        self.jobs = self.block(self.release, "jobs")
        self.testflight = self.block(self.jobs, "testflight", "  ")
        self.job = self.block(self.jobs, "retire-testflight", "  ")

    def test_no_workflow_waits_on_workflow_run_which_fires_only_from_the_default_branch(self):
        directory = os.path.join(ROOT, ".github", "workflows")
        for name in sorted(os.listdir(directory)):
            with open(os.path.join(directory, name), encoding="utf-8") as f:
                self.assertNotRegex(f.read(), r"(?m)^\s+workflow_run:", name)

    def test_it_runs_only_after_the_testflight_job_uploaded_on_nightlys_release_path(self):
        self.assertIn("needs: [plan, testflight]", self.job)
        condition = " ".join(re.search(r"^    if: >-\n((?:      .*\n)+)", self.job, re.M).group(1).split())
        testflight_if = re.search(r"^    if: (.*)$", self.testflight, re.M).group(1)
        self.assertIn(testflight_if, condition)
        self.assertIn("fromJSON(needs.plan.outputs.plan).ios", condition)
        self.assertIn("needs.testflight.result == 'success'", condition)
        # Only a push to nightly (with the key) plans an upload.
        self.assertTrue(release.plan("refs/heads/nightly", "202609250000", asc_key=True)["ios"])
        for ref in ("refs/tags/v1.2.3", "refs/tags/v1.2.3-beta.1", "refs/heads/master"):
            self.assertFalse(release.plan(ref, "202609250000", asc_key=True)["ios"], ref)

    def test_it_runs_on_linux_and_reads_the_repo_without_writing_it(self):
        self.assertRegex(self.job, r"(?m)^    runs-on: ubuntu-latest$")
        self.assertRegex(self.job, r"(?m)^    timeout-minutes: 60$")
        permissions = self.block(self.job, "permissions", "    ")
        self.assertEqual(re.findall(r"^      (\S+): (\S+)", permissions, re.M), [("contents", "read")])
        self.assertNotIn(": write", self.job)
        concurrency = self.block(self.job, "concurrency", "    ")
        self.assertIn("group: testflight-retire", concurrency)
        self.assertIn("cancel-in-progress: false", concurrency)

    def test_it_uses_only_the_testflight_upload_secrets(self):
        self.assertEqual(set(re.findall(r"secrets\.(\w+)", self.job)), set(release.IOS_SECRETS))

    def test_it_waits_for_the_build_the_testflight_job_uploaded(self):
        self.assertIn("BUILD: ${{ github.run_number }}", self.testflight)
        self.assertIn("BUILD: ${{ github.run_number }}", self.job)
        self.assertIn('release.py retire-testflight --key-file "$RUNNER_TEMP/asc/AuthKey.p8"', self.job)
        self.assertIn('--timeout 2700 --interval 45 --wait-for-build "$BUILD"', self.job)
        self.assertNotIn("--dry-run", self.job)

    def test_the_key_is_written_privately_and_always_removed(self):
        self.assertIn("umask 077", self.job)
        self.assertIn('"$RUNNER_TEMP/asc/AuthKey.p8"', self.job)
        self.assertIn("BEGIN PRIVATE KEY", self.job)
        self.assertRegex(self.job, r"- name: Remove the App Store Connect key\n\s+if: always\(\)\n\s+run: rm -rf \"\$RUNNER_TEMP/asc\"")


if __name__ == "__main__":
    unittest.main()

"""Tests for scripts/release.py, the logic behind .github/workflows/release.yml.

Run: python3 -m unittest discover -s Tests/Release -v
"""
import contextlib
import importlib.util
import io
import json
import os
import plistlib
import re
import sys
import tempfile
import unittest

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
        project = self.read("Shepherd.xcodeproj", "project.pbxproj")
        self.assertIn("/* PrivacyInfo.xcprivacy in Resources */,", project)
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


if __name__ == "__main__":
    unittest.main()

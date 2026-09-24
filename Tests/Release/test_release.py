"""Tests for scripts/release.py, the logic behind .github/workflows/release.yml.

Run: python3 -m unittest discover -s Tests/Release -v
"""
import contextlib
import importlib.util
import io
import os
import plistlib
import re
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_spec = importlib.util.spec_from_file_location("release", os.path.join(ROOT, "scripts", "release.py"))
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

    def test_a_nightly_needs_a_well_formed_stamp(self):
        with self.assertRaises(ValueError):
            release.plan("refs/heads/nightly", "2026-09-23")

    def test_the_two_apps_never_share_a_bundle_name_or_asset(self):
        main, nightly = release.plan("refs/tags/v1.0.0", STAMP), release.plan("refs/heads/nightly", STAMP)
        for key in ("bundle_id", "product", "dmg", "dsyms", "volume", "scheme", "configuration"):
            with self.subTest(key=key):
                self.assertNotEqual(main[key], nightly[key])


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
            # Old rc and nightly installs of Shepherd read the beta feed under their own tag.
            for alias, channel in (("appcast-rc.xml", "rc"), ("appcast-nightly.xml", "nightly")):
                with self.subTest(alias=alias):
                    xml = read(alias)
                    self.assertEqual(xml, sources["beta"].replace("<sparkle:channel>beta<", f"<sparkle:channel>{channel}<"))
                    self.assertEqual(xml.count(f"<sparkle:channel>{channel}</sparkle:channel>"), 2)
                    self.assertNotIn("<sparkle:channel>beta<", xml)
                    self.assertNotIn("Shepherd-Nightly", xml)


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

    def test_each_app_has_its_scheme(self):
        for app in release.APPS.values():
            with self.subTest(app=app.key):
                scheme = self.read("Shepherd.xcodeproj", "xcshareddata", "xcschemes", f"{app.scheme}.xcscheme")
                self.assertIn(f'<ArchiveAction\n      buildConfiguration = "{app.configuration}"', scheme)

    def test_info_plist_takes_the_feed_from_the_configuration(self):
        info = plistlib.loads(self.read("App", "Info.plist").encode())
        self.assertEqual(info["SUFeedURL"], release.REPOSITORY_PAGES + "$(SHEPHERD_APPCAST)")

    def test_the_apps_know_the_same_bundle_ids_and_feeds(self):
        edition = self.read("Sources", "ShepherdProtocol", "ShepherdEdition.swift")
        for app in release.APPS.values():
            self.assertTrue(f'"{app.bundle_id}"' in edition, f"ShepherdEdition lacks {app.bundle_id}")
        updater = self.read("Sources", "ShepherdApp", "AppUpdater.swift")
        for f in release.FEEDS:
            self.assertTrue(f'"{f.file}"' in updater, f"UpdateChannel lacks {f.file}")


if __name__ == "__main__":
    unittest.main()

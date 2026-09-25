#!/usr/bin/env python3
"""Release plumbing for .github/workflows/release.yml, kept out of the YAML so it can be
tested (Tests/Release/test_release.py) and run locally.

Shepherd ships as two Mac apps from one workflow:

  Shepherd          tag vX.Y.Z (stable) or vX.Y.Z-beta.N (beta)
  Shepherd Nightly  every push to the nightly branch: its own bundle id, name, feed and DMG

The same push to nightly also uploads the iOS client (Shepherd iOS) to TestFlight for internal
testing, when an App Store Connect key is configured. No other trigger uploads it yet.

Release candidates are retired: an rc tag builds nothing. Feed names and bundle ids are a
contract with the apps (UpdateChannel and ShepherdEdition in Sources/).

usage:
  release.py plan <ref> <stamp> [<attempt> [<published-tag>]] [--asc-key]
                                        the build for a pushed ref, as plan=<json> for $GITHUB_OUTPUT;
                                        --asc-key says the App Store Connect key is configured
  release.py route                      tags on stdin (newest first) -> "tag asset archive feeds"
  release.py latest <feed>              tags on stdin (newest first) -> the newest tag in <feed>
  release.py feeds                      "dir channel" per feed generate_appcast builds
  release.py fix-urls <appcast> <dir>   point a feed's archives at their per-tag release assets
  release.py deltas <dir> <tag>         name a feed's deltas for upload to <tag> and point the
                                        feed at them; prints the files to upload
  release.py publish <casts> <pages>    write every gh-pages feed, legacy aliases included
  release.py verify-app <app> <app-key> [version]  check a built app is the app it claims to be
  release.py verify-ios <app> <build>   check an archived iOS app before it is uploaded
"""
from __future__ import annotations

import json
import os
import plistlib
import re
import sys
import urllib.parse
from dataclasses import dataclass

REPOSITORY_PAGES = "https://bailycase.github.io/shepherd/"


@dataclass(frozen=True)
class App:
    key: str
    name: str
    bundle_id: str
    scheme: str
    configuration: str
    dmg: str
    appcast: str

    @property
    def product(self) -> str:
        return f"{self.name}.app"

    @property
    def dsyms(self) -> str:
        return self.dmg.removesuffix(".dmg") + "-dSYMs.zip"


APPS = {
    "main": App("main", "Shepherd", "com.bailycase.shepherd", "Shepherd (Prod)", "Release",
                "Shepherd.dmg", "appcast.xml"),
    "nightly": App("nightly", "Shepherd Nightly", "com.bailycase.shepherd.nightly", "Shepherd (Nightly)",
                   "Nightly", "Shepherd-Nightly.dmg", "appcast-shepherd-nightly.xml"),
}


@dataclass(frozen=True)
class Feed:
    dir: str       # casts/<dir>, one generate_appcast run
    file: str      # the published name on gh-pages
    channel: str   # sparkle:channel on every item; "" leaves them on the default channel
    app: str


# Pre-release feeds are supersets: beta also carries stable, so a beta rider still gets a newer
# stable hotfix. Shepherd Nightly's feed carries only Shepherd Nightly.
FEEDS = [
    Feed("stable", "appcast.xml", "", "main"),
    Feed("beta", "appcast-beta.xml", "beta", "main"),
    Feed("shepherd-nightly", "appcast-shepherd-nightly.xml", "", "nightly"),
]

# Feeds that Shepherd builds already installed still read. Each is the beta feed with its
# channel tags removed: Sparkle shows untagged items whatever channels a build allows, and the
# first nightly builds read appcast-nightly.xml while allowing none. So every such build updates
# to a Shepherd beta or stable whose launch migration moves it to Beta. Neither ever carries
# Shepherd Nightly: a main-app build must never be offered another bundle.
LEGACY_ALIASES = [
    ("appcast-rc.xml", "beta"),
    ("appcast-nightly.xml", "beta"),
]

@dataclass(frozen=True)
class IOSApp:
    name: str
    bundle_id: str
    scheme: str
    configuration: str
    export_options: str
    testing: str   # the TestFlight audience a build of this lane reaches

    @property
    def product(self) -> str:
        return f"{self.name}.app"


# The nightly lane only. Beta tags (external testing) and stable tags (the App Store) come later.
IOS = IOSApp("Shepherd iOS", "com.bailycase.shepherd.ios", "Shepherd iOS", "Release",
             "App/iOS/ExportOptions.plist", "internal")
IOS_SECRETS = ("APP_STORE_CONNECT_KEY_ID", "APP_STORE_CONNECT_ISSUER_ID", "APP_STORE_CONNECT_KEY_P8")

STABLE = re.compile(r"^v\d+\.\d+\.\d+$")
BETA = re.compile(r"^v\d+\.\d+\.\d+-beta\.\d+$")
RC = re.compile(r"^v\d+\.\d+\.\d+-rc\.\d+$")
NIGHTLY = re.compile(r"^nightly-\d{12}$")
STAMP = re.compile(r"^\d{12}$")
NIGHTLY_BRANCH = "refs/heads/nightly"


def plan(ref: str, stamp: str, attempt: int = 1, published: str = "", asc_key: bool = False) -> dict:
    """What a push of `ref` builds. `stamp` (UTC yyyymmddHHMM) names a nightly. `attempt` is
    the workflow run's attempt, and `published` the nightly-* tag already on the pushed commit,
    if any. `asc_key` says the App Store Connect key the iOS upload signs with is configured."""
    mac = _plan_mac(ref, stamp, attempt, published)
    return {**mac, **_plan_ios(ref, mac, asc_key)}


def _plan_ios(ref: str, mac: dict, asc_key: bool) -> dict:
    """The iOS client rides the nightly lane: whenever Shepherd Nightly builds, it goes to
    TestFlight internal testing too. It never gates the Mac build, and is skipped (with a
    reason the workflow prints) when the key is missing."""
    if ref != NIGHTLY_BRANCH:
        return {"ios": False, "ios_reason": "only a push to nightly uploads the iOS client to TestFlight"}
    if not mac["build"]:
        return {"ios": False, "ios_reason": mac["reason"]}
    if not asc_key:
        return {"ios": False, "ios_reason": "TestFlight upload skipped: " + ", ".join(IOS_SECRETS)
                + " are not all set. The Mac release is unaffected"}
    return {
        "ios": True,
        "ios_name": IOS.name,
        "ios_bundle_id": IOS.bundle_id,
        "ios_scheme": IOS.scheme,
        "ios_configuration": IOS.configuration,
        "ios_product": IOS.product,
        "ios_export_options": IOS.export_options,
        "ios_testing": IOS.testing,
    }


def _plan_mac(ref: str, stamp: str, attempt: int, published: str) -> dict:
    if ref.startswith("refs/tags/"):
        tag = ref.removeprefix("refs/tags/")
        if STABLE.match(tag):
            return _build(APPS["main"], "stable", tag.removeprefix("v"), tag, prerelease=False)
        if BETA.match(tag):
            return _build(APPS["main"], "beta", tag.removeprefix("v"), tag, prerelease=True)
        if RC.match(tag):
            return {"build": False, "reason": f"{tag}: release candidates are retired; tag a beta "
                    "(vX.Y.Z-beta.N) or a release (vX.Y.Z) instead"}
        return {"build": False, "reason": f"{tag}: not a release tag (vX.Y.Z or vX.Y.Z-beta.N)"}
    if ref == NIGHTLY_BRANCH:
        if not STAMP.match(stamp):
            raise ValueError(f"bad nightly stamp {stamp!r}; expected yyyymmddHHMM")
        if attempt > 1 and published:
            # A re-run keeps the run number, which is the build number, and plans a new stamp.
            # A second release of one build puts two archives with one CFBundleVersion in
            # Shepherd Nightly's feed, and generate_appcast refuses the whole step until one
            # ages out. (A tag's re-run stops at gh release create instead.)
            return {"build": False, "reason": f"this run already published {published}; a re-run "
                    "would reuse its build number. Push to nightly to ship a new build"}
        return _build(APPS["nightly"], "nightly", f"0.0.0-nightly.{stamp}", f"nightly-{stamp}", prerelease=True)
    if ref.startswith("refs/heads/"):
        # A manual run on another branch would ship that branch to every Shepherd Nightly.
        return {"build": False, "reason": f"{ref}: only the nightly branch ships Shepherd Nightly"}
    return {"build": False, "reason": f"{ref}: neither a tag nor a branch"}


def _build(app: App, channel: str, version: str, tag: str, prerelease: bool) -> dict:
    if app.key == "nightly":
        notes = (f"{app.name} builds every push to the nightly branch and is the least tested. "
                 f"It installs beside Shepherd with its own agents, settings and data. Download "
                 f"{app.dmg} and drag {app.name} to Applications; updates arrive automatically via Sparkle.")
    else:
        notes = (f"Download {app.dmg} and drag {app.name} to Applications. "
                 "Updates arrive automatically via Sparkle.")
    return {
        "build": True,
        "app": app.key,
        "name": app.name,
        "bundle_id": app.bundle_id,
        "channel": channel,
        "version": version,
        "tag": tag,
        "scheme": app.scheme,
        "configuration": app.configuration,
        "product": app.product,
        "dmg": app.dmg,
        "dsyms": app.dsyms,
        "volume": app.name,
        "title": f"{app.name} {tag}",
        "prerelease": prerelease,
        "notes": notes,
    }


def route(tag: str) -> tuple[str, str, list[str]] | None:
    """The release asset a tag's feed items come from, its staged archive name, and the feed
    directories it lands in. A nightly-* release lands in Shepherd Nightly's feed only through
    Shepherd-Nightly.dmg: nightlies from before the split carry Shepherd.dmg and drop out."""
    if STABLE.match(tag):
        app, feeds = APPS["main"], ["stable", "beta"]
    elif BETA.match(tag):
        app, feeds = APPS["main"], ["beta"]
    elif NIGHTLY.match(tag):
        app, feeds = APPS["nightly"], ["shepherd-nightly"]
    else:
        return None
    return app.dmg, staged_archive(app.dmg, tag), feeds


def staged_archive(asset: str, tag: str) -> str:
    """generate_appcast needs unique archive names in a directory: Shepherd.dmg of v1.2.3 is
    staged as Shepherd-v1.2.3.dmg. fix_urls maps it back to download/v1.2.3/Shepherd.dmg."""
    stem, ext = os.path.splitext(asset)
    return f"{stem}-{tag}{ext}"


def latest(feed: str, tags: list[str]) -> str | None:
    for tag in tags:
        routed = route(tag)
        if routed and feed in routed[2]:
            return tag
    return None


def fix_urls(xml: str, feed_dir: str) -> str:
    """generate_appcast writes each archive's URL as prefix + staged name; point it at the
    tag's own asset instead (download/Shepherd-v1.2.3.dmg -> download/v1.2.3/Shepherd.dmg)."""
    feed = next(f for f in FEEDS if f.dir == feed_dir)
    stem, ext = os.path.splitext(APPS[feed.app].dmg)
    pattern = re.compile(r"download/%s-([^\"/]+)%s\"" % (re.escape(stem), re.escape(ext)))
    return pattern.sub(lambda m: f"download/{m.group(1)}/{stem}{ext}\"", xml)


def delta_asset_name(name: str) -> str:
    """generate_appcast names a delta after the app ("Shepherd Nightly63-61.delta"), and GitHub
    rewrites spaces in asset names, so a delta is uploaded under a name without them."""
    return re.sub(r"[^A-Za-z0-9._-]", "-", name)


def point_deltas(xml: str, tag: str, names: list[str]) -> str:
    """Deltas are uploaded to the feed's newest release under their asset names; point the
    feed's delta URLs (raw or percent-encoded, as generate_appcast wrote them) there."""
    for name in names:
        for written in {name, urllib.parse.quote(name)}:
            xml = xml.replace(f'download/{written}"', f'download/{tag}/{delta_asset_name(name)}"')
    return xml


def untag(xml: str) -> str:
    """Moves every item to Sparkle's default channel, which no allowed-channels set hides."""
    return re.sub(r"\s*<sparkle:channel>[^<]*</sparkle:channel>", "", xml)


def publish(casts: str, pages: str) -> list[str]:
    """Copies each generated feed to its gh-pages name and writes the legacy aliases."""
    written = []
    generated = {}
    for feed in FEEDS:
        with open(os.path.join(casts, feed.dir, "appcast.xml"), encoding="utf-8") as f:
            generated[feed.dir] = f.read()
        _write(os.path.join(pages, feed.file), generated[feed.dir])
        written.append(feed.file)
    for file, source in LEGACY_ALIASES:
        _write(os.path.join(pages, file), untag(generated[source]))
        written.append(file)
    return written


def _write(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def verify_app(path: str, key: str, version: str | None = None) -> list[str]:
    """Problems that would ship one app under the other's identity. Empty when the build is
    the app `key` says it is."""
    app = APPS[key]
    problems = []
    if os.path.basename(os.path.normpath(path)) != app.product:
        problems.append(f"bundle is named {os.path.basename(os.path.normpath(path))!r}, expected {app.product!r}")
    info_path = os.path.join(path, "Contents", "Info.plist")
    try:
        with open(info_path, "rb") as f:
            info = plistlib.load(f)
    except OSError as error:
        return problems + [f"no Info.plist: {error}"]
    expected = {
        "CFBundleIdentifier": app.bundle_id,
        "CFBundleName": app.name,
        "CFBundleDisplayName": app.name,
        "SUFeedURL": REPOSITORY_PAGES + app.appcast,
    }
    if version is not None:
        expected["CFBundleShortVersionString"] = version
    for key_name, value in expected.items():
        if info.get(key_name) != value:
            problems.append(f"{key_name} is {info.get(key_name)!r}, expected {value!r}")
    if not info.get("SUPublicEDKey"):
        problems.append("SUPublicEDKey is missing")
    executable = info.get("CFBundleExecutable")
    if not executable or not os.path.isfile(os.path.join(path, "Contents", "MacOS", executable)):
        problems.append(f"CFBundleExecutable {executable!r} is not in Contents/MacOS")
    return problems


VERSION_STRING = re.compile(r"^\d+(\.\d+){0,2}$")


def verify_ios(path: str, build: str) -> list[str]:
    """Problems App Store Connect would reject, or that would upload the wrong app, found in the
    archived app before it is signed and sent. Empty when it is ready."""
    problems = []
    if os.path.basename(os.path.normpath(path)) != IOS.product:
        problems.append(f"bundle is named {os.path.basename(os.path.normpath(path))!r}, expected {IOS.product!r}")
    try:
        with open(os.path.join(path, "Info.plist"), "rb") as f:
            info = plistlib.load(f)
    except OSError as error:
        return problems + [f"no Info.plist: {error}"]
    expected = {
        "CFBundleIdentifier": IOS.bundle_id,
        "CFBundleVersion": build,
        # Without it every build waits at Missing Compliance until answered by hand.
        "ITSAppUsesNonExemptEncryption": False,
    }
    for key_name, value in expected.items():
        if info.get(key_name) != value:
            problems.append(f"{key_name} is {info.get(key_name)!r}, expected {value!r}")
    short = info.get("CFBundleShortVersionString")
    if not isinstance(short, str) or not VERSION_STRING.match(short):
        # A Mac nightly's 0.0.0-nightly.<stamp> is refused (ITMS-90060).
        problems.append(f"CFBundleShortVersionString {short!r} is not one to three integers")
    if not os.path.isfile(os.path.join(path, "PrivacyInfo.xcprivacy")):
        problems.append("PrivacyInfo.xcprivacy is missing")
    executable = info.get("CFBundleExecutable")
    if not executable or not os.path.isfile(os.path.join(path, executable)):
        problems.append(f"CFBundleExecutable {executable!r} is not in the bundle")
    return problems


def _tags_from_stdin() -> list[str]:
    return [line.strip() for line in sys.stdin if line.strip()]


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 64
    command, args = argv[0], argv[1:]
    if command == "plan" and 2 <= len([a for a in args if a != "--asc-key"]) <= 4:
        asc_key = "--asc-key" in args
        args = [a for a in args if a != "--asc-key"]
        ref, stamp = args[:2]
        attempt = int(args[2]) if len(args) > 2 else 1
        published = args[3] if len(args) > 3 else ""
        print("plan=" + json.dumps(plan(ref, stamp, attempt, published, asc_key), sort_keys=True))
    elif command == "route" and not args:
        for tag in _tags_from_stdin():
            routed = route(tag)
            if routed:
                asset, archive, feeds = routed
                print(tag, asset, archive, ",".join(feeds))
    elif command == "latest" and len(args) == 1:
        tag = latest(args[0], _tags_from_stdin())
        if tag:
            print(tag)
    elif command == "feeds" and not args:
        for feed in FEEDS:
            print(feed.dir, feed.channel or "-")
    elif command == "fix-urls" and len(args) == 2:
        _rewrite(args[0], lambda xml: fix_urls(xml, args[1]))
    elif command == "deltas" and len(args) == 2:
        directory, tag = args
        names = sorted(n for n in os.listdir(directory) if n.endswith(".delta"))
        _rewrite(os.path.join(directory, "appcast.xml"), lambda xml: point_deltas(xml, tag, names))
        for name in names:
            path = os.path.join(directory, delta_asset_name(name))
            os.replace(os.path.join(directory, name), path)
            print(path)
    elif command == "publish" and len(args) == 2:
        print("\n".join(publish(*args)))
    elif command == "verify-app" and len(args) in (2, 3):
        problems = verify_app(*args)
        for problem in problems:
            print(f"::error::{args[0]}: {problem}", file=sys.stderr)
        if problems:
            return 1
        print(f"{args[0]} is {APPS[args[1]].name} ({APPS[args[1]].bundle_id})")
    elif command == "verify-ios" and len(args) == 2:
        problems = verify_ios(*args)
        for problem in problems:
            print(f"::error::{args[0]}: {problem}", file=sys.stderr)
        if problems:
            return 1
        print(f"{args[0]} is {IOS.name} ({IOS.bundle_id}) build {args[1]}")
    else:
        print(__doc__, file=sys.stderr)
        return 64
    return 0


def _rewrite(path: str, change) -> None:
    with open(path, encoding="utf-8") as f:
        xml = f.read()
    _write(path, change(xml))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

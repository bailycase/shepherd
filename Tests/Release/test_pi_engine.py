"""Tests for scripts/pi_engine.py (the pi engine Shepherd ships) and the pieces that carry it into
a release: the Xcode phase, the engine's entitlements, scripts/sign-app.sh and release.yml.

Run: python3 -m unittest discover -s Tests/Release -v

Nothing here reaches the network or a real pi: staging runs against archives built in memory.
"""
import base64
import copy
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_spec = importlib.util.spec_from_file_location("pi_engine", os.path.join(ROOT, "scripts", "pi_engine.py"))
assert _spec is not None and _spec.loader is not None
pi_engine = importlib.util.module_from_spec(_spec)
sys.modules["pi_engine"] = pi_engine
_spec.loader.exec_module(pi_engine)

NODE_VERSION = "24.21.0"
PI_VERSION = "0.87.1"


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def thin_macho(arch, version=NODE_VERSION):
    cputype = {"arm64": 0x0100000C, "x86_64": 0x01000007}[arch]
    return b"\xcf\xfa\xed\xfe" + struct.pack("<I", cputype) + b"\0" * 24 + f"node v{version}\0".encode()


def fat_macho(slices):
    """What `lipo -create` makes of thin slices: a big-endian fat header, then each slice."""
    header = struct.pack(">II", 0xCAFEBABE, len(slices))
    offset = 4096
    entries, body = b"", b""
    for data in slices.values():
        cputype = struct.unpack("<I", data[4:8])[0]
        entries += struct.pack(">iiIII", cputype, 0, offset + len(body), len(data), 12)
        body += data
    return (header + entries).ljust(offset, b"\0") + body


def targz(files, prefix="package/", extra=()):
    """An npm-style tarball of {path: bytes} under `prefix`; `extra` adds raw TarInfo members."""
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz") as tar:
        for name, data in files.items():
            info = tarfile.TarInfo(prefix + name)
            info.size = len(data)
            info.mode = 0o755
            tar.addfile(info, io.BytesIO(data))
        for info, data in extra:
            tar.addfile(info, io.BytesIO(data) if data is not None else None)
    return out.getvalue()


def tarxz(files):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:xz") as tar:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return out.getvalue()


def sri(data):
    return "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode()


class Fixture:
    """Archives shaped like the real ones (Node's darwin tarballs, pi's and its modules' npm
    tarballs), and a pin that names them."""

    def __init__(self, pi_extra=(), pi_files=None, node_version=NODE_VERSION, engines=">=22.19.0",
                 shrinkwrap_jiti="2.7.0"):
        shrinkwrap = {"packages": {
            "": {"name": "@earendil-works/pi-coding-agent"},
            "node_modules/@earendil-works/chord": {"version": "0.87.1", "license": "MIT"},
            "node_modules/jiti": {"version": shrinkwrap_jiti, "license": "MIT"},
            "node_modules/@silvia-odwyer/photon-node": {"version": "0.3.4", "license": "Apache-2.0"},
            "node_modules/esbuild": {"version": "0.28.2", "license": "MIT"},
            "node_modules/@esbuild/darwin-arm64": {"version": "0.28.2", "license": "MIT"},
            "node_modules/undici": {"version": "8.10.2", "license": "MIT"},
        }}
        self.pi_files = pi_files if pi_files is not None else {
            "package.json": json.dumps({"name": "@earendil-works/pi-coding-agent", "version": PI_VERSION,
                                        "author": {"name": "Pi Author"}, "license": "MIT",
                                        "engines": {"node": engines}}).encode(),
            "README.md": b"readme", "CHANGELOG.md": b"changes",
            "docs/rpc.md": b"docs", "examples/extensions/hello.ts": b"example",
            "dist/bundle/cli.js": b"#!/usr/bin/env node\n", "dist/bundle/chunks/a.js": b"chunk",
            "dist/modes/interactive/theme/dark.json": b"{}", "dist/modes/interactive/assets/logo.png": b"png",
            "dist/core/export-html/template.html": b"<html>", "dist/core/export-html/template.css": b"css",
            "dist/core/export-html/template.js": b"js", "dist/core/export-html/vendor/marked.min.js": b"js",
            # Not shipped: the modular build, its maps and types, and the shrinkwrap itself.
            "dist/cli.js": b"modular", "dist/cli.js.map": b"map", "dist/index.d.ts": b"types",
            "dist/core/export-html/index.js": b"modular", "npm-shrinkwrap.json": json.dumps(shrinkwrap).encode(),
        }
        self.archives = {
            "pi": targz(self.pi_files, extra=pi_extra),
            "@earendil-works/chord": targz({
                "package.json": json.dumps({"name": "@earendil-works/chord", "version": "0.87.1",
                                            "license": "MIT", "author": "Chord Author"}).encode(),
                "README.md": b"chord", "dist/context/index.js": b"export {}", "dist/index.js": b"import 'esbuild'",
                "src/index.ts": b"src"}),
            "jiti": targz({"package.json": json.dumps({"name": "jiti", "version": "2.7.0"}).encode(),
                           "LICENSE": b"MIT License\n\nCopyright (c) jiti", "lib/jiti.cjs": b"cjs"}),
            "@silvia-odwyer/photon-node": targz({
                "package.json": json.dumps({"name": "@silvia-odwyer/photon-node", "version": "0.3.4"}).encode(),
                "LICENSE.md": b"Apache License", "photon_rs_bg.wasm": b"\0asm"}),
        }
        folder = f"node-v{node_version}-darwin-arm64/"
        self.node = tarxz({folder + "bin/node": thin_macho("arm64", node_version),
                           folder + "LICENSE": b"Node.js is licensed for use as follows:",
                           folder + "include/node/node.h": b"header"})
        self.pin = {
            "node": {"version": node_version, "dist": f"https://nodejs.org/dist/v{node_version}/", "archives": {
                "arm64": {"file": f"node-v{node_version}-darwin-arm64.tar.xz",
                          "sha256": hashlib.sha256(self.node).hexdigest()}}},
            "pi": {"name": "@earendil-works/pi-coding-agent", "version": PI_VERSION,
                   "tarball": f"https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-{PI_VERSION}.tgz",
                   "integrity": sri(self.archives["pi"])},
            "modules": {},
        }
        versions = {"@earendil-works/chord": "0.87.1", "jiti": "2.7.0", "@silvia-odwyer/photon-node": "0.3.4"}
        for name, version in versions.items():
            base = name.split("/")[-1]
            self.pin["modules"][name] = {"version": version,
                                         "tarball": f"https://registry.npmjs.org/{name}/-/{base}-{version}.tgz",
                                         "integrity": sri(self.archives[name])}
        self.requests = []

    def urls(self):
        node = self.pin["node"]
        shasums = "".join(f"{a['sha256']}  {a['file']}\n" for a in node["archives"].values())
        urls = {node["dist"] + "SHASUMS256.txt": shasums.encode()}
        urls[node["dist"] + node["archives"]["arm64"]["file"]] = self.node
        urls[self.pin["pi"]["tarball"]] = self.archives["pi"]
        for name, module in self.pin["modules"].items():
            urls[module["tarball"]] = self.archives[name]
        return urls

    def opener(self, overrides=None):
        urls = {**self.urls(), **(overrides or {})}

        def open_url(url):
            self.requests.append(url)
            return io.BytesIO(urls[url])
        return open_url

    def stage(self, scratch, **overrides):
        pin_path = os.path.join(scratch, "pin.json")
        with open(pin_path, "w") as f:
            json.dump(self.pin, f)
        out = os.path.join(scratch, "staged")
        pi_engine.stage(os.path.join(scratch, "cache"), out, pin_path=pin_path, opener=self.opener(overrides))
        return out


def listing(root):
    return sorted(os.path.relpath(os.path.join(d, f), root) for d, _, files in os.walk(root) for f in files)


class PinTests(unittest.TestCase):
    """scripts/pi-engine-pin.json: Node 24 LTS for Apple silicon, and pi with the three modules its
    bundle loads, each by version and hash."""

    def test_the_checked_in_pin_is_usable(self):
        self.assertEqual(pi_engine.pin_problems(pi_engine.load_pin()), [])

    def test_it_pins_node_24_lts_for_arm64_only_and_pi_0_87_1(self):
        pin = pi_engine.load_pin()
        self.assertEqual(pin["node"]["version"].split(".")[0], "24")
        self.assertEqual(list(pin["node"]["archives"]), ["arm64"])
        self.assertEqual((pin["pi"]["name"], pin["pi"]["version"]), ("@earendil-works/pi-coding-agent", "0.87.1"))
        self.assertEqual(sorted(pin["modules"]), ["@earendil-works/chord", "@silvia-odwyer/photon-node", "jiti"])

    def test_a_pin_that_could_not_be_verified_or_would_not_run_is_refused(self):
        good = pi_engine.load_pin()
        cases = {
            "an odd node line": lambda p: p["node"].update(version="25.0.0",
                                                            dist="https://nodejs.org/dist/v25.0.0/"),
            "a node too old for pi": lambda p: p["node"].update(version="22.18.0",
                                                                 dist="https://nodejs.org/dist/v22.18.0/"),
            "another download site": lambda p: p["node"].update(dist="https://example.com/dist/"),
            "an x86_64 archive too": lambda p: p["node"]["archives"].update(x86_64={
                "file": "node-v24.21.0-darwin-x64.tar.xz", "sha256": "0" * 64}),
            "no arm64 archive": lambda p: p["node"]["archives"].pop("arm64"),
            "a short sha256": lambda p: p["node"]["archives"]["arm64"].update(sha256="abc"),
            "an archive for another version": lambda p: p["node"]["archives"]["arm64"].update(
                file="node-v24.0.0-darwin-arm64.tar.xz"),
            "a sha1 integrity": lambda p: p["pi"].update(integrity="sha1-AAAA"),
            "another registry": lambda p: p["pi"].update(tarball="https://example.com/pi.tgz"),
            "an extra module": lambda p: p["modules"].update(esbuild=dict(p["modules"]["jiti"])),
            "a missing module": lambda p: p["modules"].pop("jiti"),
        }
        for name, change in cases.items():
            with self.subTest(name):
                pin = copy.deepcopy(good)
                change(pin)
                self.assertTrue(pi_engine.pin_problems(pin))

    def test_nodejs_orgs_shasums_must_list_each_pinned_archive(self):
        pin = pi_engine.load_pin()
        listed = "".join(f"{a['sha256']}  {a['file']}\n" for a in pin["node"]["archives"].values())
        self.assertEqual(pi_engine.node_shasums_problems(pin, listed + "0" * 64 + "  other.tar.gz\n"), [])
        self.assertEqual(len(pi_engine.node_shasums_problems(pin, "0" * 64 + "  other.tar.gz\n")), 1)
        self.assertEqual(len(pi_engine.node_shasums_problems(pin, listed.replace(listed[:4], "ffff", 1))), 1)


class FetchTests(unittest.TestCase):
    def test_a_cached_download_that_still_matches_is_reused_without_the_network(self):
        with tempfile.TemporaryDirectory() as scratch:
            dest = os.path.join(scratch, "a.tgz")
            with open(dest, "wb") as f:
                f.write(b"cached")

            def refuse(url):
                raise AssertionError("no download expected")
            self.assertEqual(pi_engine.fetch("https://x/a.tgz", dest, lambda p: True, opener=refuse), dest)

    def test_a_download_that_does_not_match_is_refused_and_never_cached(self):
        with tempfile.TemporaryDirectory() as scratch:
            dest = os.path.join(scratch, "a.tgz")
            with self.assertRaises(pi_engine.EngineError):
                pi_engine.fetch("https://x/a.tgz", dest, lambda p: False, opener=lambda url: io.BytesIO(b"tampered"))
            self.assertEqual(os.listdir(scratch), [])

    def test_offline_staging_needs_the_cache(self):
        with tempfile.TemporaryDirectory() as scratch:
            with self.assertRaises(pi_engine.EngineError):
                pi_engine.fetch("https://x/a.tgz", os.path.join(scratch, "a.tgz"), lambda p: True, offline=True)


class StageTests(unittest.TestCase):
    """What staging keeps of each archive, and what it refuses."""

    def test_it_stages_node_for_arm64_and_only_the_files_pi_needs(self):
        fixture = Fixture()
        with tempfile.TemporaryDirectory() as scratch:
            out = fixture.stage(scratch)
            engine = "Resources/pi-engine/"
            self.assertEqual(listing(out), sorted([
                "Helpers/node", "inputs.xcfilelist", "outputs.xcfilelist", "pin.json",
                *(engine + f for f in (
                    "package.json", "README.md", "CHANGELOG.md", "docs/rpc.md", "examples/extensions/hello.ts",
                    "dist/bundle/cli.js", "dist/bundle/chunks/a.js", "dist/modes/interactive/theme/dark.json",
                    "dist/modes/interactive/assets/logo.png", "dist/core/export-html/template.html",
                    "dist/core/export-html/template.css", "dist/core/export-html/template.js",
                    "dist/core/export-html/vendor/marked.min.js",
                    "node_modules/@earendil-works/chord/package.json", "node_modules/@earendil-works/chord/README.md",
                    "node_modules/@earendil-works/chord/dist/context/index.js",
                    "node_modules/jiti/package.json", "node_modules/jiti/LICENSE", "node_modules/jiti/lib/jiti.cjs",
                    "node_modules/@silvia-odwyer/photon-node/package.json",
                    "node_modules/@silvia-odwyer/photon-node/LICENSE.md",
                    "node_modules/@silvia-odwyer/photon-node/photon_rs_bg.wasm",
                    "LICENSE", "NODE-LICENSE", "THIRD-PARTY-NOTICES")),
            ]))
            self.assertEqual(set(pi_engine.slices(os.path.join(out, "Helpers/node"))), {"arm64"})
            self.assertEqual(pi_engine.verify(out, fixture.pin), [])

    def test_files_are_plain_and_only_node_is_executable(self):
        fixture = Fixture()
        with tempfile.TemporaryDirectory() as scratch:
            out = fixture.stage(scratch)
            for path in listing(out):
                mode = os.stat(os.path.join(out, path)).st_mode & 0o777
                self.assertEqual(mode, 0o755 if path == "Helpers/node" else 0o644, path)

    def test_the_stamp_is_the_pin_it_was_staged_from(self):
        fixture = Fixture()
        with tempfile.TemporaryDirectory() as scratch:
            out = fixture.stage(scratch)
            with open(os.path.join(scratch, "pin.json")) as a, open(os.path.join(out, "pin.json")) as b:
                self.assertEqual(a.read(), b.read())

    def test_the_licences_name_pi_node_and_every_bundled_package_but_esbuild(self):
        fixture = Fixture()
        with tempfile.TemporaryDirectory() as scratch:
            out = fixture.stage(scratch)
            engine = os.path.join(out, "Resources", "pi-engine")
            with open(os.path.join(engine, "LICENSE")) as f:
                licence = f.read()
            self.assertIn("MIT License", licence)
            self.assertIn("Copyright (c) Pi Author", licence)
            with open(os.path.join(engine, "NODE-LICENSE")) as f:
                self.assertEqual(f.read(), "Node.js is licensed for use as follows:")
            with open(os.path.join(engine, "THIRD-PARTY-NOTICES")) as f:
                notices = f.read()
            self.assertIn("undici 8.10.2  MIT", notices)
            self.assertNotIn("esbuild", notices.split("not shipped.")[1])
            self.assertIn("Copyright (c) jiti", notices)
            self.assertIn("Apache License", notices)
            self.assertIn("Copyright (c) Chord Author", notices)

    def test_the_file_lists_declare_every_file_the_xcode_phase_reads_and_every_path_it_writes(self):
        fixture = Fixture()
        with tempfile.TemporaryDirectory() as scratch:
            out = fixture.stage(scratch)
            staged = [p for p in listing(out) if not p.endswith(".xcfilelist")]
            with open(os.path.join(out, "inputs.xcfilelist")) as f:
                inputs = f.read().split()
            with open(os.path.join(out, "outputs.xcfilelist")) as f:
                outputs = f.read().split()
            self.assertEqual(sorted(inputs), sorted(f"$(SRCROOT)/.build/pi-engine/{p}" for p in staged))
            contents = "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/"
            for path in staged:
                if path != "pin.json":
                    self.assertIn(contents + path, outputs)
            for folder in ("Helpers", "Resources/pi-engine", "Resources/pi-engine/dist/bundle/chunks",
                           "Resources/pi-engine/node_modules/@earendil-works"):
                self.assertIn(contents + folder, outputs)
            self.assertNotIn(contents + "Resources", outputs, "the phase never creates Resources/")

    def test_restaging_reuses_the_cache(self):
        fixture = Fixture()
        with tempfile.TemporaryDirectory() as scratch:
            fixture.stage(scratch)
            count = len(fixture.requests)
            fixture.stage(scratch)
            self.assertEqual(len(fixture.requests), count)

    def test_a_tampered_download_stops_staging(self):
        fixture = Fixture()
        with tempfile.TemporaryDirectory() as scratch:
            with self.assertRaises(pi_engine.EngineError):
                fixture.stage(scratch, **{fixture.pin["pi"]["tarball"]: fixture.archives["jiti"]})
            self.assertFalse(os.path.exists(os.path.join(scratch, "staged")))

    def test_links_and_paths_outside_the_package_are_refused(self):
        link = tarfile.TarInfo("package/dist/bundle/evil.js")
        link.type = tarfile.SYMTYPE
        link.linkname = "/etc/passwd"
        climb = tarfile.TarInfo("package/../../evil.js")
        climb.size = 1
        for extra in ([(link, None)], [(climb, b"x")]):
            with self.subTest(extra[0][0].name), tempfile.TemporaryDirectory() as scratch:
                with self.assertRaises(pi_engine.EngineError):
                    Fixture(pi_extra=extra).stage(scratch)

    def test_a_pi_that_needs_a_newer_node_is_refused(self):
        with tempfile.TemporaryDirectory() as scratch:
            with self.assertRaisesRegex(pi_engine.EngineError, "needs node"):
                Fixture(engines=">=26.0.0").stage(scratch)

    def test_a_module_pi_does_not_resolve_to_is_refused(self):
        with tempfile.TemporaryDirectory() as scratch:
            with self.assertRaisesRegex(pi_engine.EngineError, "shrinkwrap"):
                Fixture(shrinkwrap_jiti="2.6.0").stage(scratch)


class VerifyTests(unittest.TestCase):
    """verify-app's engine checks, against a staged tree with one thing wrong."""

    def setUp(self):
        self.fixture = Fixture()
        self.scratch = tempfile.mkdtemp()
        self.out = self.fixture.stage(self.scratch)
        self.engine = os.path.join(self.out, "Resources", "pi-engine")

    def tearDown(self):
        shutil.rmtree(self.scratch)

    def write(self, relative, data=b"x"):
        path = os.path.join(self.engine, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)

    def assertOneProblem(self, mentioning):
        problems = pi_engine.verify(self.out, self.fixture.pin)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn(mentioning, problems[0])

    def test_esbuild_does_not_ship(self):
        self.write("node_modules/esbuild/package.json", json.dumps({"name": "esbuild"}).encode())
        problems = pi_engine.verify(self.out, self.fixture.pin)
        self.assertTrue(any("esbuild" in p for p in problems), problems)

    def test_another_platforms_prebuilds_do_not_ship(self):
        self.write("node_modules/jiti/prebuilds/linux-x64/addon.txt")
        self.assertOneProblem("prebuilds")

    def test_a_native_addon_does_not_ship(self):
        self.write("node_modules/jiti/addon.node")
        self.assertOneProblem("addon.node")

    def test_node_is_the_only_mach_o(self):
        self.write("dist/bundle/helper", thin_macho("arm64"))
        self.assertOneProblem("native code")

    def test_a_module_the_bundle_does_not_load_does_not_ship(self):
        self.write("node_modules/undici/package.json", json.dumps({"name": "undici", "version": "8.10.2"}).encode())
        self.assertOneProblem("node_modules/undici")

    def test_node_is_arm64_only_at_the_pinned_version(self):
        node = os.path.join(self.out, "Helpers", "node")
        for data, mentioning in ((fat_macho({"arm64": thin_macho("arm64"), "x86_64": thin_macho("x86_64")}),
                                  "has an x86_64 slice"),
                                 (thin_macho("x86_64"), "has no arm64 slice"),
                                 (thin_macho("arm64", "24.20.0"), "arm64 slice is not node")):
            with self.subTest(mentioning):
                with open(node, "wb") as f:
                    f.write(data)
                self.assertTrue(any(mentioning in p for p in pi_engine.verify(self.out, self.fixture.pin)), mentioning)
        with open(node, "wb") as f:
            f.write(fat_macho({"arm64": thin_macho("arm64")}))
        self.assertEqual(pi_engine.verify(self.out, self.fixture.pin), [], "a fat file of one arm64 slice is fine")

    def test_the_pinned_pi_and_its_entry_and_licences_must_be_there(self):
        for relative, mentioning in (("dist/bundle/cli.js", "cli.js is missing"),
                                     ("NODE-LICENSE", "NODE-LICENSE is missing"),
                                     ("THIRD-PARTY-NOTICES", "THIRD-PARTY-NOTICES is missing")):
            with self.subTest(relative):
                path = os.path.join(self.engine, relative)
                with open(path, "rb") as f:
                    saved = f.read()
                os.remove(path)
                self.assertOneProblem(mentioning)
                with open(path, "wb") as f:
                    f.write(saved)
        pin = copy.deepcopy(self.fixture.pin)
        pin["pi"]["version"] = "0.88.0"
        problems = pi_engine.verify(self.out, pin)
        self.assertTrue(any("expected @earendil-works/pi-coding-agent 0.88.0" in p for p in problems), problems)

    def test_an_app_without_the_engine_says_so(self):
        with tempfile.TemporaryDirectory() as app:
            os.makedirs(os.path.join(app, "Contents"))
            problems = pi_engine.verify(app, self.fixture.pin)
            self.assertIn("Helpers/node is missing", problems)
            self.assertIn("Resources/pi-engine is missing", problems)


class LayoutContractTests(unittest.TestCase):
    """The engine's paths are a contract between the staging script, the Xcode phase that
    embeds it and the Swift locator that will start it."""

    def phase(self):
        project = read("Shepherd.xcodeproj", "project.pbxproj")
        m = re.search(r"/\* Embed pi engine \*/ = \{\n(.*?)\n\t\t\};", project, re.S)
        self.assertIsNotNone(m, "the Mac target has an Embed pi engine phase")
        return m.group(1)

    def test_the_mac_target_runs_the_phase_after_its_resources_in_every_configuration(self):
        project = read("Shepherd.xcodeproj", "project.pbxproj")
        target = re.search(r"/\* Shepherd \*/ = \{\n\t\t\tisa = PBXNativeTarget;.*?buildPhases = \((.*?)\);", project, re.S)
        phases = re.findall(r"/\* (.*?) \*/", target.group(1))
        self.assertEqual(phases[-1], "Embed pi engine")
        self.assertLess(phases.index("Resources"), phases.index("Embed pi engine"))
        # A target's phases run in every configuration; only a deployment-postprocessing phase
        # would skip Debug.
        self.assertIn("runOnlyForDeploymentPostprocessing = 0;", self.phase())

    def test_script_sandboxing_stays_on_and_the_phase_declares_what_it_touches(self):
        project = read("Shepherd.xcodeproj", "project.pbxproj")
        mac = [b for b in re.findall(r"isa = XCBuildConfiguration;\n(.*?)\n\t\t\};", project, re.S)
               if "INFOPLIST_FILE = App/Info.plist;" in b]
        self.assertEqual(len(mac), 3)
        for block in mac:
            self.assertIn("ENABLE_USER_SCRIPT_SANDBOXING = YES;", block)
        phase = self.phase()
        self.assertIn('"$(SRCROOT)/.build/pi-engine/inputs.xcfilelist"', phase)
        self.assertIn('"$(SRCROOT)/.build/pi-engine/outputs.xcfilelist"', phase)
        for path in ("scripts/pi-engine-pin.json", "scripts/sign-engine.sh", "App/Engine.entitlements"):
            self.assertIn(f'"$(SRCROOT)/{path}"', phase)
        self.assertNotIn("x86_64", phase)
        self.assertEqual(pi_engine.STAGED_IN_XCODE, "$(SRCROOT)/.build/pi-engine")
        self.assertEqual(pi_engine.DEFAULT_STAGED, os.path.join(pi_engine.ROOT, ".build", "pi-engine"))

    def test_the_phase_copies_the_staged_layout_checks_the_stamp_and_never_downloads(self):
        script = self.phase()
        self.assertIn(f'staged}}/{pi_engine.ENGINE}\\"', script)
        self.assertIn(f'staged}}/{pi_engine.NODE}\\"', script)
        self.assertIn('cmp -s \\"${SRCROOT}/scripts/pi-engine-pin.json\\" \\"${staged}/pin.json\\"', script)
        self.assertIn("scripts/sign-engine.sh", script)
        commands = [line for line in script.split("shellScript = ", 1)[1].split("\\n") if not line.startswith("#")]
        for fetcher in ("curl", "wget", "http", "npm ", "pi_engine.py stage\\\" ", "python3 scripts/pi_engine.py stage;"):
            for line in commands:
                self.assertNotIn(fetcher, line.replace("Run: python3 scripts/pi_engine.py stage", ""))

    def test_the_swift_locator_uses_the_same_paths(self):
        swift = read("Sources", "ShepherdSessions", "PiEngine.swift")
        for name, value in (("nodePath", pi_engine.NODE), ("packagePath", pi_engine.ENGINE), ("entryPath", pi_engine.ENTRY)):
            self.assertIn(f'public static let {name} = "{value}"', swift)


class EntitlementsTests(unittest.TestCase):
    """What node may do under the hardened runtime: JIT, and nothing else."""

    def test_node_gets_only_jit(self):
        self.assertEqual(plistlib.loads(read("App", "Engine.entitlements").encode()),
                         {"com.apple.security.cs.allow-jit": True})

    def test_there_is_one_engine_entitlements_file(self):
        self.assertEqual(sorted(n for n in os.listdir(os.path.join(ROOT, "App")) if n.startswith("Engine")),
                         ["Engine.entitlements"])


class SignAppTests(unittest.TestCase):
    def test_sign_app_takes_the_engine_entitlements_and_finds_node_addons(self):
        script = read("scripts", "sign-app.sh")
        self.assertIn("<entitlements.plist> [<engine.entitlements>]", script)
        self.assertIn("-name '*.node'", script)
        self.assertIn('sign-engine.sh"', script)

    @unittest.skipUnless(sys.platform == "darwin" and all(shutil.which(t) for t in ("codesign", "lipo", "cc")),
                         "needs macOS with codesign, lipo and a compiler")
    def test_node_is_signed_with_the_engine_entitlements(self):
        with tempfile.TemporaryDirectory() as scratch:
            app = os.path.join(scratch, "Shepherd.app")
            for folder in ("MacOS", "Helpers", "Resources/pi-engine"):
                os.makedirs(os.path.join(app, "Contents", folder))
            with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
                plistlib.dump({"CFBundleExecutable": "Shepherd", "CFBundleIdentifier": "com.example.engine-test"}, f)
            source = os.path.join(scratch, "main.c")
            with open(source, "w") as f:
                f.write("int main(void) { return 0; }\n")
            env = {**os.environ, "TMPDIR": scratch}
            for name in ("MacOS/Shepherd", "Helpers/node"):
                subprocess.run(["cc", "-arch", "arm64", "-o", os.path.join(app, "Contents", name), source], check=True, env=env)
            sign = [os.path.join(ROOT, "scripts", "sign-app.sh"), app, "-", os.path.join(ROOT, "App", "Shepherd.entitlements")]

            refused = subprocess.run(sign, capture_output=True, text=True, env=env)
            self.assertEqual(refused.returncode, 64, "an app carrying node needs the engine entitlements")

            subprocess.run(sign + [os.path.join(ROOT, "App", "Engine.entitlements")], check=True, capture_output=True, env=env)
            node = os.path.join(app, "Contents", "Helpers", "node")
            shown = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", node],
                                   capture_output=True, check=True).stdout
            self.assertEqual(set(plistlib.loads(shown)), {"com.apple.security.cs.allow-jit"})
            main = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml",
                                   os.path.join(app, "Contents", "MacOS", "Shepherd")], capture_output=True).stdout
            self.assertNotIn(b"allow-jit", main, "the app never gets the engine's entitlements")


class ReleaseWorkflowTests(unittest.TestCase):
    """release.yml stages the engine before building, keeps node unstripped and signs it with
    the engine's entitlements."""

    def steps(self):
        workflow = read(".github", "workflows", "release.yml")
        job = workflow.split("\n  release:\n", 1)[1].split("\n  testflight:\n", 1)[0]
        return re.findall(r"\n      - (?:name: (.*?)\n|uses:.*?\n)(.*?)(?=\n      - |\Z)", job, re.S)

    def step(self, name):
        for title, body in self.steps():
            if title == name:
                return body
        self.fail(f"release.yml has no step named {name!r}")

    def test_staging_runs_before_the_build_with_downloads_cached_by_the_pin(self):
        names = [title for title, _ in self.steps()]
        self.assertLess(names.index("Stage the pi engine"), names.index("Build ${{ env.APP_NAME }}"))
        self.assertIn("python3 scripts/pi_engine.py stage", self.step("Stage the pi engine"))
        cache = self.step("Cache the pi engine's downloads")
        self.assertIn("path: .build/pi-engine-cache", cache)
        self.assertIn("hashFiles('scripts/pi-engine-pin.json')", cache)

    def test_a_cached_build_from_another_pin_is_never_restored(self):
        self.assertIn("'scripts/pi-engine-pin.json') }}", self.step("Cache DerivedData"))

    def test_the_verified_app_is_the_one_signed_and_node_is_never_stripped(self):
        names = [title for title, _ in self.steps()]
        self.assertLess(names.index("Verify the app's identity"), names.index("Sign"))
        strip = self.step("Strip debug symbols")
        self.assertIn('"$PRODUCTS/$PRODUCT/Contents/MacOS/"*', strip)
        self.assertNotIn("Helpers", strip.split("run:", 1)[1])

    def test_signing_passes_the_engine_entitlements(self):
        sign = self.step("Sign")
        self.assertIn("App/Shepherd.entitlements \\\n            App/Engine.entitlements\n", sign)
        self.assertNotIn("x86_64", sign)


if __name__ == "__main__":
    unittest.main()


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("codesign") and shutil.which("clang")
                     and shutil.which("lipo"), "needs macOS's codesign, clang and lipo")
class SignEngineTests(unittest.TestCase):
    """sign-engine.sh signs an arm64 node as node, and refuses any other slice."""

    def compile(self, work, *archs):
        source = os.path.join(work, "main.c")
        with open(source, "w") as f:
            f.write("int main(void) { return 0; }\n")
        node = os.path.join(work, "node")
        arch_flags = [flag for arch in archs for flag in ("-arch", arch)]
        subprocess.run(["clang", *arch_flags, "-o", node, source], check=True, capture_output=True)
        return node

    def sign(self, node, work):
        return subprocess.run([os.path.join(ROOT, "scripts", "sign-engine.sh"), node, "-",
                               os.path.join(ROOT, "App", "Engine.entitlements")],
                              capture_output=True, text=True, env={**os.environ, "TMPDIR": work})

    def test_node_is_signed_with_the_identifier_node(self):
        # A Developer ID seal on the app pins the identifier of nested code, so node signed under
        # a temporary file's name failed the app's verification.
        with tempfile.TemporaryDirectory() as work:
            node = self.compile(work, "arm64")
            signed = self.sign(node, work)
            self.assertEqual(signed.returncode, 0, signed.stderr)
            shown = subprocess.run(["codesign", "-dv", node], capture_output=True, text=True, check=True).stderr
            self.assertEqual(re.findall(r"^Identifier=(.+)$", shown, re.M), ["node"])
            subprocess.run(["codesign", "--verify", "--strict", node], check=True, capture_output=True)

    def test_a_node_with_an_x86_64_slice_is_refused_untouched(self):
        for archs in (("arm64", "x86_64"), ("x86_64",)):
            with self.subTest(archs=archs), tempfile.TemporaryDirectory() as work:
                node = self.compile(work, *archs)
                with open(node, "rb") as f:
                    built = f.read()
                refused = self.sign(node, work)
                self.assertEqual(refused.returncode, 65, refused.stderr)
                self.assertIn("arm64 only", refused.stderr)
                with open(node, "rb") as f:
                    self.assertEqual(f.read(), built)

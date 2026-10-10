#!/usr/bin/env python3
"""The pi engine Shepherd ships: Node, Pi's bundle and SDK, pinned by scripts/pi-engine-pin.json.

Staging downloads Node from nodejs.org and pi's tarballs from the npm registry, checks every
download against the pin, and writes the tree the app carries:

  Helpers/node                      Node's darwin-arm64 binary as published: Shepherd runs on
                                    Apple silicon only
  Resources/pi-engine/              Pi's package.json, dist (bundle and modular SDK), assets,
                                    docs, examples and locked SDK dependencies, plus LICENSE,
                                    NODE-LICENSE and THIRD-PARTY-NOTICES
  pin.json                          a copy of the pin it was staged from (the Xcode phase's stamp)
  inputs.xcfilelist, outputs.xcfilelist
                                    node/stamp paths for the sandboxed signing phase. Xcode copies
                                    Resources/pi-engine as a native folder resource

No npm and no package scripts: tarballs are unpacked here with tarfile, so nothing in them runs
(stronger than npm's --ignore-scripts). Downloads are cached by name and reused only while they
still match the pin. The Mac target's "Embed pi engine" Run Script phase copies the staged tree
into Contents/ and never downloads.

usage:
  pi_engine.py stage [--cache DIR] [--out DIR] [--offline]
                                   download (or reuse), verify and stage the engine
  pi_engine.py verify <App.app|staged dir>
                                   check an app's (or a staged) engine against the pin
  pi_engine.py check-pin           check the pin file's shape, offline
"""
from __future__ import annotations

import base64
import datetime
import fnmatch
import hashlib
import http.client
import json
import mmap
import os
import re
import shutil
import socket
import struct
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PIN = os.path.join(ROOT, "scripts", "pi-engine-pin.json")
DEFAULT_CACHE = os.path.join(ROOT, ".build", "pi-engine-cache")
DEFAULT_STAGED = os.path.join(ROOT, ".build", "pi-engine")

# Paths inside an app's Contents/ (and inside a staged tree). Contents/MacOS is avoided on
# purpose: release.yml strips everything there, and node must ship unstripped.
NODE = "Helpers/node"
ENGINE = "Resources/pi-engine"
ENTRY = "dist/cli.js"
STAMP = "pin.json"
INPUTS = "inputs.xcfilelist"
OUTPUTS = "outputs.xcfilelist"
STAGED_IN_XCODE = "$(SRCROOT)/.build/pi-engine"
CONTENTS_IN_XCODE = "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)"
LICENSES = ("LICENSE", "NODE-LICENSE", "THIRD-PARTY-NOTICES")

# The one architecture Shepherd ships. x86_64 is named only to report a slice that must not ship.
ARCHITECTURE = "arm64"
CPU_TYPES = {0x0100000C: "arm64", 0x01000007: "x86_64"}

# What of pi's package ships. "dir/**" keeps a whole tree. pi finds its themes, export
# templates and interactive assets under dist/ beside the bundle (config.js getThemesDir and
# friends), and its system prompt points the model at README.md, docs/ and examples/.
PI_KEEP = (
    "package.json",
    "README.md",
    "CHANGELOG.md",
    "docs/**",
    "examples/**",
    "dist/**",
)

# Detached extension runners import the modular SDK outside Pi's bundle loader. Keep its
# locked dependency tree, including nested versions. Chord's root/context exports need no
# esbuild; its optional bundler API is not supported. No native compiler or platform packages
# ship. QuickJS's side modules are unused WebAssembly named like native libraries.
REQUIRED_MODULES = {
    "jiti", "@silvia-odwyer/photon-node", "quickjs-wasi", "typebox",
    "@earendil-works/pi-agent-core", "@earendil-works/pi-ai",
    "@earendil-works/pi-tui", "@earendil-works/chord",
}
MODULE_KEEP = {
    "quickjs-wasi": ("package.json", "quickjs.wasm", "dist/**"),
    "@earendil-works/pi-tui": ("package.json", "dist/**", "LICENSE*", "LICENCE*"),
}


def module_name(install_path: str) -> str:
    """A pinned npm install location, including nested node_modules, never an arbitrary path."""
    package = r"(?:@[a-z0-9._-]+/)?[a-z0-9._-]+"
    if (not re.fullmatch(package + r"(?:/node_modules/" + package + r")*", install_path)
            or any(part in (".", "..") for part in install_path.split("/"))):
        raise EngineError(f"invalid module install path: {install_path!r}")
    return install_path.rsplit("node_modules/", 1)[-1]

# What the bundle resolves inside a module by name at runtime, so the module is useless without
# it: pi finds the QuickJS binary with `require.resolve("quickjs-wasi/quickjs.wasm")` when a
# codemode script runs, and the image worker finds photon's WebAssembly beside its JavaScript.
MODULE_REQUIRED = {
    "@silvia-odwyer/photon-node": ("photon_rs_bg.wasm",),
    "quickjs-wasi": ("quickjs.wasm",),
}

# Never inside the engine: native code (Node is the only Mach-O, and it lives in Helpers/),
# esbuild, or package-manager leftovers.
FORBIDDEN_NAMES = ("*.node", "*.dylib", "*.so", "*.dll", "*.exe", ".bin", "esbuild", "@esbuild", "prebuilds")

MIT = """MIT License

Copyright (c) {holder}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""


class EngineError(Exception):
    pass


# The pin


def load_pin(path: str = PIN) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _version(text: str) -> tuple[int, ...] | None:
    parts = text.split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        return None
    return tuple(int(p) for p in parts)


def _is_sri(value: object) -> bool:
    if not isinstance(value, str) or not value.startswith("sha512-"):
        return False
    try:
        return len(base64.b64decode(value.removeprefix("sha512-"), validate=True)) == 64
    except ValueError:
        return False


def pin_problems(pin: dict) -> list[str]:
    """Everything wrong with the pin's shape. Empty for a usable pin."""
    problems = []
    node = pin.get("node", {})
    version = _version(str(node.get("version", "")))
    if version is None:
        problems.append(f"node.version {node.get('version')!r} is not X.Y.Z")
    elif version[0] % 2 or version < (22, 19, 0):
        problems.append(f"node {node['version']} is not an LTS line pi supports (even major, 22.19 or later)")
    if node.get("dist") != f"https://nodejs.org/dist/v{node.get('version')}/":
        problems.append(f"node.dist {node.get('dist')!r} is not nodejs.org's folder for the pinned version")
    archives = node.get("archives", {})
    if list(archives) != [ARCHITECTURE]:
        problems.append(f"node.archives covers {list(archives)}, expected {[ARCHITECTURE]} (Apple silicon only)")
    for arch, archive in archives.items():
        expected = f"node-v{node.get('version')}-darwin-{arch}.tar.xz"
        if archive.get("file") != expected:
            problems.append(f"node.archives.{arch}.file is {archive.get('file')!r}, expected {expected!r}")
        digest = archive.get("sha256", "")
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            problems.append(f"node.archives.{arch}.sha256 is not a SHA-256")
    if spec := pin.get("patch"):
        if not isinstance(spec, dict) or spec.get("file") != "pi-engine-patches/skills.json" or not re.fullmatch(r"[0-9a-f]{64}", str(spec.get("sha256", ""))):
            problems.append("patch must name pi-engine-patches/skills.json and its SHA-256")
    pi = pin.get("pi", {})
    problems += _package_problems("pi", pi.get("name", ""), pi)
    modules = pin.get("modules", {})
    if missing := REQUIRED_MODULES - set(modules):
        problems.append(f"missing SDK modules: {sorted(missing)}")
    for location, module in modules.items():
        try:
            name = module_name(location)
        except EngineError as error:
            problems.append(str(error))
            continue
        if name == "esbuild" or name.startswith("@esbuild/"):
            problems.append(f"modules.{location}: esbuild must not ship")
        problems += _package_problems(f"modules.{location}", name, module)
    return problems


def _package_problems(where: str, name: str, package: dict) -> list[str]:
    problems = []
    if _version(str(package.get("version", ""))) is None:
        problems.append(f"{where}.version {package.get('version')!r} is not X.Y.Z")
    base = name.split("/")[-1]
    expected = f"https://registry.npmjs.org/{name}/-/{base}-{package.get('version')}.tgz"
    if not name or package.get("tarball") != expected:
        problems.append(f"{where}.tarball {package.get('tarball')!r}, expected {expected!r}")
    if not _is_sri(package.get("integrity")):
        problems.append(f"{where}.integrity is not a sha512 integrity string")
    return problems


# Downloads


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def integrity_of(path: str) -> str:
    digest = hashlib.sha512()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return "sha512-" + base64.b64encode(digest.digest()).decode()


def fetch(url: str, dest: str, matches, offline: bool = False, opener=urllib.request.urlopen) -> str:
    """`dest`, downloaded from `url` unless a cached copy already `matches`. A download that
    doesn't match is deleted and refused, so the cache only ever holds verified files."""
    if os.path.isfile(dest) and matches(dest):
        return dest
    if offline:
        raise EngineError(f"{os.path.basename(dest)} is not in the cache (or no longer matches the pin), and --offline")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    fd, partial = tempfile.mkstemp(dir=os.path.dirname(dest), prefix=".download-")
    try:
        with os.fdopen(fd, "wb") as out:
            for attempt in range(1, 4):
                out.seek(0)
                out.truncate()
                response = None
                complete = False
                try:
                    while True:
                        # Only opening/reading the response may retry, never filesystem writes.
                        try:
                            if response is None:
                                response = opener(url, timeout=60)
                            block = response.read(1 << 20)
                        except (OSError, http.client.IncompleteRead) as error:
                            reason = error.reason if isinstance(error, urllib.error.URLError) else error
                            if isinstance(error, urllib.error.HTTPError):
                                transient = error.code in (408, 429, 500, 502, 503, 504)
                                error.close()
                            else:
                                transient = isinstance(reason, (TimeoutError, ConnectionError, http.client.IncompleteRead)) or (
                                    isinstance(reason, socket.gaierror) and reason.errno == socket.EAI_AGAIN)
                            if not transient or attempt == 3:
                                raise EngineError(f"download {url} failed on attempt {attempt}/3: {error}") from error
                            break
                        if not block:
                            complete = True
                            break
                        out.write(block)
                finally:
                    if response is not None:
                        response.close()
                if complete:
                    break
        if not matches(partial):
            raise EngineError(f"{url} does not match the pin")
        os.replace(partial, dest)
    finally:
        if os.path.exists(partial):
            os.remove(partial)
    return dest


def node_shasums_problems(pin: dict, shasums: str) -> list[str]:
    """Whether nodejs.org's SHASUMS256.txt lists each pinned archive with the pinned hash."""
    listed = {}
    for line in shasums.splitlines():
        parts = line.split()
        if len(parts) == 2:
            listed[parts[1]] = parts[0]
    problems = []
    for arch, archive in pin["node"]["archives"].items():
        if listed.get(archive["file"]) != archive["sha256"]:
            problems.append(f"SHASUMS256.txt lists {archive['file']} as {listed.get(archive['file'])!r}, "
                            f"but the pin says {archive['sha256']!r}")
    return problems


def _text(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def download_all(pin: dict, cache: str, offline: bool = False, opener=urllib.request.urlopen) -> dict:
    """Every pinned download, verified, as {"node": path, "pi": path, "modules": {name: path}}."""
    node = pin["node"]
    downloads = os.path.join(cache, "downloads")
    fetch(node["dist"] + "SHASUMS256.txt", os.path.join(downloads, f"node-v{node['version']}-SHASUMS256.txt"),
          lambda path: not node_shasums_problems(pin, _text(path)), offline, opener)
    result = {"modules": {}}
    archive = node["archives"][ARCHITECTURE]
    result["node"] = fetch(node["dist"] + archive["file"], os.path.join(downloads, archive["file"]),
                           lambda path: sha256_of(path) == archive["sha256"], offline, opener)
    packages = [("pi", pin["pi"])] + [(name, module) for name, module in pin["modules"].items()]
    for name, package in packages:
        # Scoped packages can share a tarball basename (e.g. retry and @types/retry).
        filename = name.replace("/", "__") + "-" + os.path.basename(package["tarball"])
        path = fetch(package["tarball"], os.path.join(downloads, filename),
                     lambda p, want=package["integrity"]: integrity_of(p) == want, offline, opener)
        if name == "pi":
            result["pi"] = path
        else:
            result["modules"][name] = path
    return result


# Unpacking


def _kept(relative: str, rules) -> bool:
    for rule in rules:
        if rule == "**":
            return True
        if rule.endswith("/**"):
            if relative.startswith(rule[:-2]):
                return True
        elif fnmatch.fnmatchcase(relative, rule) and relative.count("/") == rule.count("/"):
            return True
    return False


def package_files(archive: str, rules) -> dict[str, bytes]:
    """Kept regular files under an npm tarball's single root (usually package/, but @types
    archives use their package name). Links, devices, multiple roots and traversal are refused."""
    files = {}
    root = None
    with tarfile.open(archive, "r:*") as tar:
        for member in tar.getmembers():
            name = member.name
            if name.startswith("/") or ".." in name.split("/"):
                raise EngineError(f"{os.path.basename(archive)}: unsafe path {name!r}")
            if member.isdir():
                continue
            if not member.isfile():
                raise EngineError(f"{os.path.basename(archive)}: {name!r} is not a regular file")
            top, _, relative = name.partition("/")
            root = root or top
            if top != root or not relative:
                raise EngineError(f"{os.path.basename(archive)}: {name!r} is outside {root}/")
            # Some npm archives repeat a file as both dist/x and ./dist/x. Xcode treats
            # those as one output, so normalize before building its sandbox file lists.
            relative = os.path.normpath(relative)
            if _kept(relative, rules):
                data = tar.extractfile(member)
                assert data is not None
                contents = data.read()
                if relative in files and files[relative] != contents:
                    raise EngineError(f"{os.path.basename(archive)}: conflicting duplicate {relative!r}")
                files[relative] = contents
    return files


def node_files(archive: str, version: str) -> tuple[bytes, bytes]:
    """`bin/node` and `LICENSE` from Node's darwin-arm64 archive."""
    prefix = f"node-v{version}-darwin-{ARCHITECTURE}/"
    with tarfile.open(archive, "r:*") as tar:
        found = {}
        for wanted in ("bin/node", "LICENSE"):
            member = tar.getmember(prefix + wanted)
            if not member.isfile():
                raise EngineError(f"{os.path.basename(archive)}: {wanted} is not a regular file")
            data = tar.extractfile(member)
            assert data is not None
            found[wanted] = data.read()
    return found["bin/node"], found["LICENSE"]


# Staging


def notices(pin: dict, shrinkwrap: dict, module_licences: dict[str, tuple[str, str]]) -> str:
    """THIRD-PARTY-NOTICES: every package pi's shrinkwrap resolves (the bundler strips their
    licence comments from dist/bundle), then the full texts the shipped modules carry."""
    lines = [
        f"Third-party notices for pi {pin['pi']['version']} as shipped in Shepherd",
        "",
        "pi's bundle (Resources/pi-engine/dist/bundle) compiles in the packages below, resolved by",
        "pi's npm-shrinkwrap.json. esbuild and its platform packages are not shipped.",
        "",
    ]
    for key, package in sorted(shrinkwrap.get("packages", {}).items()):
        if not key:
            continue
        name = key.rsplit("node_modules/", 1)[-1]
        if name == "esbuild" or name.startswith("@esbuild/"):
            continue
        lines.append(f"  {name} {package.get('version', '?')}  {package.get('license', 'UNKNOWN')}")
    lines.append("")
    for name, (file, text) in sorted(module_licences.items()):
        lines += ["=" * 72, f"{name} ({file})", "=" * 72, "", text.rstrip(), ""]
    return "\n".join(lines) + "\n"


def _author(package: dict) -> str:
    author = package.get("author")
    if isinstance(author, dict):
        author = author.get("name")
    if not isinstance(author, str) or not author.strip():
        raise EngineError(f"{package.get('name')} names no author for its MIT notice")
    return author.strip()


def engine_patch(pin: dict) -> dict | None:
    spec = pin.get("patch")
    if spec is None:
        return None
    path = os.path.join(ROOT, "scripts", spec["file"])
    if sha256_of(path) != spec["sha256"]:
        raise EngineError("engine patch differs from the pin; update its hash and restage")
    with open(path, encoding="utf-8") as f:
        patch = json.load(f)
    if patch["version"] != pin["pi"]["version"]:
        raise EngineError("engine patch does not match the pinned pi version")
    for change in patch["files"]:
        if "source" in change:
            source = os.path.join(os.path.dirname(path), change["source"])
            if sha256_of(source) != change["after"]:
                raise EngineError("engine patch source differs from its pinned hash")
    return patch


def apply_patch(files: dict[str, bytes], pin: dict) -> None:
    patch = engine_patch(pin)
    for change in (patch or {}).get("files", []):
        path = change["path"]
        original = files.get(path, b"")
        if hashlib.sha256(original).hexdigest() != change["before"]:
            raise EngineError(f"engine patch source mismatch: {path}")
        text = original.decode("utf-8")
        if "source" in change:
            text = _text(os.path.join(ROOT, "scripts", "pi-engine-patches", change["source"]))
        for edit in change.get("edits", []):
            if text.count(edit["old"]) != 1:
                raise EngineError(f"engine patch anchor mismatch: {path}")
            text = text.replace(edit["old"], edit["new"])
        result = text.encode("utf-8")
        if hashlib.sha256(result).hexdigest() != change["after"]:
            raise EngineError(f"engine patch result mismatch: {path}")
        files[path] = result


def build_tree(pin: dict, downloads: dict) -> dict[str, bytes]:
    """The staged tree as {relative path: bytes}, node included."""
    tree: dict[str, bytes] = {}
    pi = package_files(downloads["pi"], PI_KEEP + ("npm-shrinkwrap.json",))
    manifest = json.loads(pi["package.json"])
    if (manifest.get("name"), manifest.get("version")) != (pin["pi"]["name"], pin["pi"]["version"]):
        raise EngineError(f"pi's tarball is {manifest.get('name')} {manifest.get('version')}, not the pinned one")
    engines = manifest.get("engines", {}).get("node", "")
    minimum = _version(engines.removeprefix(">=")) if engines.startswith(">=") else None
    if minimum is None or _version(pin["node"]["version"]) < minimum:
        raise EngineError(f"pi {pin['pi']['version']} needs node {engines!r}; the pin has {pin['node']['version']}")
    if ENTRY not in pi:
        raise EngineError(f"pi's tarball has no {ENTRY}")
    shrinkwrap = json.loads(pi.pop("npm-shrinkwrap.json", b"{}"))
    expected = {
        key.removeprefix("node_modules/") for key, value in shrinkwrap.get("packages", {}).items()
        if key and not value.get("dev") and not value.get("optional") and key != "node_modules/esbuild"
    }
    if set(pin["modules"]) != expected:
        raise EngineError(f"SDK modules differ from pi's shrinkwrap: missing {sorted(expected - set(pin['modules']))}, "
                          f"extra {sorted(set(pin['modules']) - expected)}")
    apply_patch(pi, pin)
    for relative, data in pi.items():
        tree[f"{ENGINE}/{relative}"] = data

    licences = {}
    for location, module in pin["modules"].items():
        name = module_name(location)
        keep = MODULE_KEEP.get(name, ("**",))
        files = package_files(downloads["modules"][location], keep + ("LICENSE*", "LICENCE*"))
        meta = json.loads(files["package.json"])
        if (meta.get("name"), meta.get("version")) != (name, module["version"]):
            raise EngineError(f"{name}'s tarball is {meta.get('name')} {meta.get('version')}, not the pinned one")
        locked = shrinkwrap.get("packages", {}).get(f"node_modules/{location}", {})
        if locked.get("version") != module["version"] or locked.get("integrity", module["integrity"]) != module["integrity"]:
            raise EngineError(f"{name} {module['version']} is not what pi's shrinkwrap resolves ({locked.get('version')})")
        texts = sorted(f for f in files if f.upper().startswith(("LICENSE", "LICENCE")))
        if texts:
            licences[location] = (texts[0], files[texts[0]].decode("utf-8"))
        elif meta.get("license") == "MIT":
            licences[location] = ("MIT, from package.json", MIT.format(holder=_author(meta)))
        elif name.startswith("@aws-sdk/") and meta.get("license") == "Apache-2.0":
            # Some AWS tarballs omit the shared license. Use the text from their pinned core.
            text = package_files(downloads["modules"]["@aws-sdk/core"], ("LICENSE",))["LICENSE"]
            licences[location] = ("Apache-2.0, from @aws-sdk/core/LICENSE", text.decode("utf-8"))
        else:
            raise EngineError(f"{name} ships no licence text")
        for relative, data in files.items():
            if _kept(relative, keep):
                tree[f"{ENGINE}/node_modules/{location}/{relative}"] = data

    tree[NODE], tree[f"{ENGINE}/NODE-LICENSE"] = node_files(downloads["node"], pin["node"]["version"])
    # pi's tarball carries no LICENSE; package.json says MIT and names the author.
    tree[f"{ENGINE}/LICENSE"] = MIT.format(holder=_author(manifest)).encode()
    tree[f"{ENGINE}/THIRD-PARTY-NOTICES"] = notices(pin, shrinkwrap, licences).encode()
    return tree


def file_lists() -> tuple[str, str]:
    """Only Node and the stamp belong to the sandboxed phase. Xcode copies the SDK as a
    folder resource, avoiding thousands of sandbox-exec arguments for its individual files."""
    inputs = [f"{STAGED_IN_XCODE}/{path}" for path in (STAMP, NODE)]
    outputs = [f"{CONTENTS_IN_XCODE}/{path}" for path in ("Helpers", NODE)]
    return "\n".join(inputs) + "\n", "\n".join(outputs) + "\n"


def write_tree(tree: dict[str, bytes], pin_text: str, out: str) -> None:
    """Writes the tree beside `out` and swaps it in, so `out` is never half staged. Files are
    0644 and node 0755, whatever the archives said."""
    parent = os.path.dirname(os.path.abspath(out))
    os.makedirs(parent, exist_ok=True)
    staging = tempfile.mkdtemp(dir=parent, prefix=".pi-engine-")
    os.chmod(staging, 0o755)
    try:
        for relative, data in tree.items():
            path = os.path.join(staging, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(data)
            os.chmod(path, 0o755 if relative == NODE else 0o644)
        inputs, outputs = file_lists()
        for name, text in ((INPUTS, inputs), (OUTPUTS, outputs), (STAMP, pin_text)):
            with open(os.path.join(staging, name), "w", encoding="utf-8") as f:
                f.write(text)
        old = None
        if os.path.exists(out):
            old = tempfile.mkdtemp(dir=parent, prefix=".pi-engine-old-")
            os.rmdir(old)
            os.replace(out, old)
        os.replace(staging, out)
        if old:
            shutil.rmtree(old)
    finally:
        if os.path.exists(staging):
            shutil.rmtree(staging)


def stage(cache: str = DEFAULT_CACHE, out: str = DEFAULT_STAGED, offline: bool = False, pin_path: str = PIN,
          opener=urllib.request.urlopen) -> None:
    with open(pin_path, encoding="utf-8") as f:
        pin_text = f.read()
    pin = json.loads(pin_text)
    problems = pin_problems(pin)
    if problems:
        raise EngineError("the pin is not usable: " + "; ".join(problems))
    downloads = download_all(pin, cache, offline, opener)
    write_tree(build_tree(pin, downloads), pin_text, out)
    problems = verify(out, pin)
    if problems:
        raise EngineError("the staged engine fails verification: " + "; ".join(problems))


# Verification


def slices(path: str) -> dict[str, tuple[int, int]]:
    """A Mach-O file's architectures, as {arch: (offset, size)}. Empty if it isn't Mach-O."""
    with open(path, "rb") as f:
        head = f.read(8)
        if len(head) < 8:
            return {}
        if head[:4] == b"\xca\xfe\xba\xbe":
            count = struct.unpack(">I", head[4:8])[0]
            found = {}
            for _ in range(count):
                cputype, _sub, offset, size, _align = struct.unpack(">iiIII", f.read(20))
                found[CPU_TYPES.get(cputype & 0xFFFFFFFF, hex(cputype & 0xFFFFFFFF))] = (offset, size)
            return found
        if head[:4] == b"\xcf\xfa\xed\xfe":
            cputype = struct.unpack("<I", head[4:8])[0]
            return {CPU_TYPES.get(cputype, hex(cputype)): (0, os.path.getsize(path))}
    return {}


def _slice_mentions(path: str, offset: int, size: int, needle: bytes) -> bool:
    with open(path, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
        return data.find(needle, offset, offset + size) >= 0


def verify(root: str, pin: dict | None = None) -> list[str]:
    """Problems with the engine under `root`: an app bundle, its Contents/, or a staged tree.
    Empty when node is arm64 only, at the pinned version, Pi and its SDK modules
    are the pinned ones (each with the file the runtime resolves in it), nothing else is in
    node_modules, nothing native or esbuild is in the engine, and the licences are there."""
    pin = pin or load_pin()
    if os.path.isdir(os.path.join(root, "Contents")):
        root = os.path.join(root, "Contents")
    problems = []
    try:
        patch = engine_patch(pin)
        for change in (patch or {}).get("files", []):
            path = os.path.join(root, ENGINE, change["path"])
            if not os.path.isfile(path) or sha256_of(path) != change["after"]:
                problems.append(f"engine patch missing or modified: {change['path']}")
    except (EngineError, OSError, KeyError, ValueError) as error:
        problems.append(str(error))
    node = os.path.join(root, NODE)
    if not os.path.isfile(node):
        problems.append(f"{NODE} is missing")
    else:
        found = slices(node)
        if not found:
            problems.append(f"{NODE} is not a Mach-O file")
        elif ARCHITECTURE not in found:
            problems.append(f"{NODE} has no {ARCHITECTURE} slice")
        elif not _slice_mentions(node, *found[ARCHITECTURE], f"v{pin['node']['version']}\0".encode()):
            problems.append(f"{NODE}'s {ARCHITECTURE} slice is not node {pin['node']['version']}")
        for arch in sorted(set(found) - {ARCHITECTURE}):
            problems.append(f"{NODE} has an {arch} slice; Shepherd ships for Apple silicon only")
        if not os.access(node, os.X_OK):
            problems.append(f"{NODE} is not executable")
    engine = os.path.join(root, ENGINE)
    if not os.path.isdir(engine):
        return problems + [f"{ENGINE} is missing"]
    problems += _package_version(engine, pin["pi"]["name"], pin["pi"]["version"], ENGINE)
    for entry in (ENTRY, "dist/index.js"):
        if not os.path.isfile(os.path.join(engine, entry)):
            problems.append(f"{ENGINE}/{entry} is missing")
    for name in LICENSES:
        if not os.path.isfile(os.path.join(engine, name)):
            problems.append(f"{ENGINE}/{name} is missing")
    modules = os.path.join(engine, "node_modules")
    present = installed_modules(modules)
    for extra in sorted(present - set(pin["modules"])):
        problems.append(f"node_modules/{extra} is not pinned")
    for location, module in pin["modules"].items():
        name = module_name(location)
        if location not in present:
            problems.append(f"node_modules/{location} is missing")
        else:
            problems += _package_version(os.path.join(modules, location), name, module["version"], f"node_modules/{location}")
            for required in MODULE_REQUIRED.get(name, ()):
                if not os.path.isfile(os.path.join(modules, location, required)):
                    problems.append(f"node_modules/{location}/{required} is missing")
    for directory, dirs, files in os.walk(engine):
        for entry in dirs + files:
            if any(fnmatch.fnmatchcase(entry, pattern) for pattern in FORBIDDEN_NAMES):
                problems.append(f"{os.path.relpath(os.path.join(directory, entry), root)} must not ship")
        for entry in files:
            path = os.path.join(directory, entry)
            if not os.path.islink(path) and slices(path):
                problems.append(f"{os.path.relpath(path, root)} is native code; only {NODE} may be")
    return problems


def installed_modules(directory: str) -> set[str]:
    """List package locations, retaining nested dependency versions rather than flattening them."""
    found = set()
    if not os.path.isdir(directory):
        return found
    for name in os.listdir(directory):
        names = [f"{name}/{sub}" for sub in os.listdir(os.path.join(directory, name))] if name.startswith("@") else [name]
        for package in names:
            found.add(package)
            nested = installed_modules(os.path.join(directory, package, "node_modules"))
            found.update(f"{package}/node_modules/{child}" for child in nested)
    return found


def _package_version(directory: str, name: str, version: str, where: str) -> list[str]:
    try:
        with open(os.path.join(directory, "package.json"), encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, ValueError) as error:
        return [f"{where}/package.json is unreadable: {error}"]
    if (manifest.get("name"), manifest.get("version")) != (name, version):
        return [f"{where} is {manifest.get('name')} {manifest.get('version')}, expected {name} {version}"]
    return []


def main(argv: list[str]) -> int:
    if argv[:1] == ["stage"]:
        args = argv[1:]
        options = {"--cache": DEFAULT_CACHE, "--out": DEFAULT_STAGED}
        offline = "--offline" in args
        args = [a for a in args if a != "--offline"]
        while args:
            if len(args) < 2 or args[0] not in options:
                print(__doc__, file=sys.stderr)
                return 64
            options[args[0]] = os.path.abspath(args[1])
            args = args[2:]
        started = datetime.datetime.now()
        try:
            stage(options["--cache"], options["--out"], offline)
        except (EngineError, OSError) as error:
            print(f"error: {error}", file=sys.stderr)
            return 1
        pin = load_pin()
        seconds = (datetime.datetime.now() - started).total_seconds()
        print(f"staged node {pin['node']['version']} and pi {pin['pi']['version']} in {options['--out']} ({seconds:.1f}s)")
    elif argv[:1] == ["verify"] and len(argv) == 2:
        problems = verify(argv[1])
        for problem in problems:
            print(f"::error::{argv[1]}: {problem}", file=sys.stderr)
        if problems:
            return 1
        pin = load_pin()
        print(f"{argv[1]} carries node {pin['node']['version']} and pi {pin['pi']['version']}")
    elif argv == ["check-pin"]:
        problems = pin_problems(load_pin())
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1 if problems else 0
    else:
        print(__doc__, file=sys.stderr)
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

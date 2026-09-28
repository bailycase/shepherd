"""Execute Release's publication shell against fake gh/Sparkle and a scratch git remote."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/release.yml").read_text()


def shell_step(name):
    block = WORKFLOW.split(f"      - name: {name}\n", 1)[1]
    block = block.split("        run: |\n", 1)[1]
    lines = []
    for line in block.splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line[10:] if line else "")
    return "set -euo pipefail\n" + "\n".join(lines).replace("${{ github.repository }}", "fixture/shepherd")


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state = self.root / "releases.json"
        self.log = self.root / "gh.log"
        self.remote = self.root / "remote.git"
        self.git("init", "--bare", str(self.remote))
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "FAKE_RELEASES": str(self.state), "FAKE_LOG": str(self.log),
                    "SPARKLE_PRIVATE_KEY": "fixture-not-secret", "TAG": "trigger", "GH_TOKEN": "fake"}
        self.program("gh", '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]; state=Path(os.environ['FAKE_RELEASES']); releases=json.loads(state.read_text())
with open(os.environ['FAKE_LOG'],'a') as f: f.write(json.dumps(args)+'\\n')
if args[:2]==['release','list']:
 print('\\n'.join(r['tag'] for r in releases if not r.get('draft')))
elif args[:2]==['release','view']:
 r=next(r for r in releases if r['tag']==args[2]); assets=[{'name':r.get('asset','Shepherd.dmg')}]
 if 'policy' in r: assets.append({'name':'shepherd-appcast.json'})
 print(json.dumps({'isDraft':r.get('draft',False),'assets':assets}))
elif args[:2]==['release','download']:
 r=next(r for r in releases if r['tag']==args[2]); asset=args[args.index('-p')+1]
 if r.get('downloadFails'): sys.exit(23)
 content=json.dumps(r['policy']) if asset=='shepherd-appcast.json' else r['tag']
 Path(args[args.index('-O')+1]).write_text(content)
elif args[:2]==['release','delete']:
 releases=[r for r in releases if r['tag']!=args[2]]; state.write_text(json.dumps(releases))
elif args[:2]==['release','create']:
 archive=os.environ['DMG']
 if archive not in args[3:] or not Path(archive).is_file(): sys.exit(24)
 policy=json.loads(Path('shepherd-appcast.json').read_text())
 releases.append({'tag':args[2],'draft':'--draft' in args,'policy':policy}); state.write_text(json.dumps(releases))
elif args[:2]==['release','edit']:
 r=next(r for r in releases if r['tag']==args[2]); r['draft']=False; state.write_text(json.dumps(releases))
elif args[:2]==['release','upload']: pass
else: raise RuntimeError(args)
''')
        self.program("swift", '''#!/bin/sh
[ "$*" = "package resolve --force-resolved-versions" ] || exit 42
if [ -n "${FAKE_GATE:-}" ]; then
  touch "$FAKE_GATE/entered"
  n=0
  until [ -f "$FAKE_GATE/released" ]; do
    n=$((n+1)); [ "$n" -lt 500 ] || exit 43
    sleep 0.01
  done
fi
mkdir -p .build/artifacts/Sparkle/bin
cp "$FAKE_GENERATOR" .build/artifacts/Sparkle/bin/generate_appcast
''')
        generator = self.program("generator", '''#!/usr/bin/env python3
import sys
from pathlib import Path
args=sys.argv[1:]; target=Path(args[args.index('-o')+1]); directory=Path(args[-1])
items=''.join('<item><title>'+p.read_text()+'</title><sparkle:version>1</sparkle:version><enclosure url="'+p.name+'"/></item>' for p in sorted(directory.glob('*.dmg')))
target.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'+items+'</channel></rss>')
''')
        self.env["FAKE_GENERATOR"] = str(generator)

    def program(self, name, text):
        file = self.bin / name
        file.write_text(text)
        file.chmod(0o700)
        return file

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout

    def publish(self, releases, expected=0):
        self.state.write_text(json.dumps(releases))
        checkout = self.root / ("publisher-" + str(len(list(self.root.glob('publisher-*')))))
        self.git("clone", str(self.remote), str(checkout))
        self.git("config", "user.email", "fixture@example.invalid", cwd=checkout)
        self.git("config", "user.name", "fixture", cwd=checkout)
        (checkout / "seed").write_text("fixture")
        self.git("add", "seed", cwd=checkout)
        self.git("commit", "--allow-empty", "-m", "fixture", cwd=checkout)
        (checkout / "scripts").mkdir()
        for file in ("release.py", "pi_engine.py"):
            shutil.copyfile(ROOT / "scripts" / file, checkout / "scripts" / file)
        temp = checkout / "temp"
        temp.mkdir()
        result = subprocess.run(["bash", "-c", shell_step("Update appcasts")], cwd=checkout,
                                env={**self.env, "RUNNER_TEMP": str(temp)}, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def feeds(self):
        return self.git("--git-dir", str(self.remote), "show", "gh-pages:appcast-beta.xml")

    def test_coalesced_publisher_regenerates_all_completed_tagged_releases(self):
        # These are successive owners of the workflow's single publication slot. Waiting
        # triggers may be replaced, but neither owner's tag limits its input snapshot.
        self.publish([{"tag": "v1.0.0"}])
        self.publish([{"tag": "v1.2.0-beta.1"}, {"tag": "v1.1.0"}, {"tag": "v1.0.0"},
                      {"tag": "v2.0.0", "draft": True}])
        xml = self.feeds()
        for tag in ("v1.0.0", "v1.1.0", "v1.2.0-beta.1"):
            self.assertIn(tag, xml)
        self.assertNotIn("v2.0.0", xml)

    def test_publisher_takes_its_release_snapshot_after_entering_its_job(self):
        gate = self.root / 'gate'
        gate.mkdir()
        self.env['FAKE_GATE'] = str(gate)
        failures = []
        def run():
            try:
                self.publish([{'tag': 'v1.0.0'}])
            except BaseException as error:
                failures.append(error)
        worker = threading.Thread(target=run)
        worker.start()
        try:
            deadline = time.monotonic() + 5
            while not (gate / 'entered').exists():
                if time.monotonic() > deadline:
                    self.fail('publisher never entered its setup gate')
                time.sleep(0.01)
            # Another tagged build completes while the admitted publisher prepares its tools.
            self.state.write_text(json.dumps([{'tag': 'v1.1.0'}, {'tag': 'v1.0.0'}]))
        finally:
            (gate / 'released').touch()
            worker.join(timeout=20)
        self.assertFalse(worker.is_alive())
        if failures:
            raise failures[0]
        self.assertIn('v1.1.0', self.feeds())
        self.assertIn('v1.0.0', self.feeds())

    def test_release_upload_is_draft_first_and_records_signing_eligibility(self):
        (self.root / "Shepherd.dmg").write_bytes(b"fixture archive")
        for identity, eligible in [("-", False), ("", False), ("Developer ID Application: Fixture", True)]:
            with self.subTest(identity=identity):
                self.state.write_text("[]")
                result = subprocess.run(["bash", "-c", shell_step("Publish release")], cwd=self.root,
                    env={**self.env, "SIGNING_IDENTITY": identity, "TAG": "v1.1.0", "TITLE": "Fixture", "NOTES": "fixture",
                         "PRERELEASE": "false", "CHANNEL": "stable", "DMG": "Shepherd.dmg", "DSYMS": "absent.zip"},
                    capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(self.state.read_text()), [{"tag": "v1.1.0", "draft": False,
                    "policy": {"version": 1, "tag": "v1.1.0", "eligible": eligible}}])
                calls = [json.loads(line) for line in self.log.read_text().splitlines()]
                self.assertIn("--draft", calls[-2])
                self.assertEqual(calls[-1], ["release", "edit", "v1.1.0", "--draft=false"])

    def test_a_missing_required_archive_never_publishes_a_release(self):
        self.state.write_text("[]")
        result = subprocess.run(["bash", "-c", shell_step("Publish release")], cwd=self.root,
            env={**self.env, "SIGNING_IDENTITY": "Developer ID Application: Fixture", "TAG": "v1.1.0",
                 "TITLE": "Fixture", "NOTES": "fixture", "PRERELEASE": "false", "CHANNEL": "stable",
                 "DMG": "missing.dmg", "DSYMS": "absent.zip"},
            capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 24, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.state.read_text()), [])
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertFalse(any(call[:2] == ["release", "edit"] for call in calls), calls)

    def test_new_ad_hoc_is_excluded_from_every_future_regeneration(self):
        self.publish([{"tag": "v1.1.0", "policy": {"version": 1, "tag": "v1.1.0", "eligible": False}},
                      {"tag": "v1.0.0"}])
        self.assertNotIn("v1.1.0", self.feeds())
        self.assertIn("v1.0.0", self.feeds())

    def test_bad_present_policy_or_download_never_overwrites_feeds(self):
        self.publish([{"tag": "v1.0.0"}])
        before = self.feeds()
        for extra in ({"policy": {"eligible": True}},
                      {"policy": {"version": True, "tag": "v1.1.0", "eligible": True}},
                      {"policy": {"version": 1, "tag": "wrong", "eligible": True}},
                      {"policy": {"version": 1, "tag": "v1.1.0", "eligible": "true"}}, {"downloadFails": True}):
            with self.subTest(extra=extra):
                self.publish([{"tag": "v1.1.0", **extra}, {"tag": "v1.0.0"}], expected=1 if 'policy' in extra else 23)
                self.assertEqual(self.feeds(), before)

    def test_pruning_happens_only_after_success_and_never_names_a_draft(self):
        releases = [{"tag": f"nightly-20261001000{n}", "asset": "Shepherd-Nightly.dmg"} for n in range(6, 0, -1)]
        releases.insert(0, {"tag": "nightly-draft", "draft": True})
        self.publish(releases)
        remaining = [r['tag'] for r in json.loads(self.state.read_text())]
        self.assertEqual(remaining, ["nightly-draft", "nightly-202610010006", "nightly-202610010005", "nightly-202610010004", "nightly-202610010003"])
        xml = self.git("--git-dir", str(self.remote), "show", "gh-pages:appcast-shepherd-nightly.xml")
        self.assertNotIn("nightly-202610010002", xml)
        self.assertIn("nightly-202610010006", xml)

    def test_push_failure_never_prunes_and_the_next_owner_reads_fresh_releases(self):
        self.publish([{"tag": "v1.0.0"}])
        before = self.feeds()
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o700)
        releases = [{"tag": f"nightly-20261001000{n}", "asset": "Shepherd-Nightly.dmg"} for n in range(6, 0, -1)]
        self.publish(releases + [{"tag": "v1.1.0"}, {"tag": "v1.0.0"}], expected=1)
        self.assertEqual(len(json.loads(self.state.read_text())), 8)
        self.assertEqual(self.feeds(), before)
        hook.unlink()
        self.publish(releases + [{"tag": "v1.2.0"}, {"tag": "v1.1.0"}, {"tag": "v1.0.0"}])
        for tag in ("v1.2.0", "v1.1.0", "v1.0.0"):
            self.assertIn(tag, self.feeds())

    def test_missing_sparkle_key_skips_publication_and_pruning(self):
        self.env['SPARKLE_PRIVATE_KEY'] = ''
        self.publish([{"tag": "v1.0.0"}])
        self.assertFalse(self.log.exists())
        self.assertEqual(list((self.remote / 'refs/heads').iterdir()), [])

    def test_only_publication_uses_the_shared_replaceable_slot(self):
        top = re.search(r'^concurrency:\n((?:  .*\n)+)', WORKFLOW, re.M).group(1)
        self.assertIn('github.ref', top)
        job = WORKFLOW.split('  publish-appcasts:\n')[1].split('  testflight:\n')[0]
        self.assertIn('needs: [plan, release]', job)
        self.assertIn('group: appcast-publication', job)
        self.assertIn('cancel-in-progress: false', job)
        build = WORKFLOW.split('  release:\n')[1].split('  publish-appcasts:\n')[0]
        self.assertNotIn('appcast-publication', build)
        self.assertNotIn('gh release delete', build)


if __name__ == '__main__':
    unittest.main()

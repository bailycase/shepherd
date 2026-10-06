"""Exercise the SDK from the staged/released engine, not a developer's npm install.

SHEPHERD_ENGINE_SMOKE=.build/pi-engine python3 -m unittest discover -s Tests/Release -p test_pi_engine_sdk.py
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.environ.get("SHEPHERD_ENGINE_SMOKE"), "requires a staged engine or app")
class EngineSDKTests(unittest.TestCase):
    def test_background_runners_can_import_host_peers_and_create_a_session(self):
        root = Path(os.environ["SHEPHERD_ENGINE_SMOKE"]).resolve()
        if (root / "Contents").is_dir():
            root /= "Contents"
        engine = root / "Resources/pi-engine"
        with tempfile.TemporaryDirectory() as scratch:
            env = {"PATH": "/usr/bin:/bin", "HOME": scratch, "TMPDIR": scratch,
                   "PI_CODING_AGENT_DIR": scratch, "PI_PACKAGE_DIR": str(engine), "PI_OFFLINE": "1"}
            result = subprocess.run(
                [str(root / "Helpers/node"), "--input-type=module", "-e", """
import assert from 'node:assert/strict';
const peers = [
  '@earendil-works/pi-coding-agent', '@earendil-works/pi-agent-core',
  '@earendil-works/pi-tui', '@earendil-works/pi-ai/compat',
  '@earendil-works/pi-ai/oauth', '@earendil-works/pi-ai/providers/all',
  'typebox', 'typebox/compile', 'typebox/value',
  '@earendil-works/chord', '@earendil-works/chord/context',
];
for (const peer of peers) await import(peer);
const pi = await import('@earendil-works/pi-coding-agent');
assert.equal(typeof pi.createAgentSession, 'function');
const resources = new pi.DefaultResourceLoader({
  cwd: process.env.HOME, agentDir: process.env.HOME,
  noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true,
});
await resources.reload();
const { session } = await pi.createAgentSession({
  cwd: process.env.HOME, agentDir: process.env.HOME,
  sessionManager: pi.SessionManager.inMemory(), resourceLoader: resources,
});
assert.ok(session);
await session.dispose();
console.log('SDK peers imported and child session created');
"""], cwd=engine, env=env, capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("SDK peers imported and child session created", result.stdout)


if __name__ == "__main__":
    unittest.main()

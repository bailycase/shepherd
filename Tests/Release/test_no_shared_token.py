"""Guard: no host accepts a token shared by every client.

Hosts take a device's own token, a paired Mac's own token, and (on `host.sock`) this app's own signed code. The old
`remote-token` file is never created or read, and the retired requests and Settings row stay gone. A test may still
name the file to prove a leftover one is ignored; Sources and App may not.

Run: python3 -m unittest discover -s Tests/Release -p 'test_no_shared_token.py' -v
"""
import os
import unittest
from pathlib import Path

ROOT = Path(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))

RETIRED = ["remote-token", "remoteTokenURL", "loadOrCreateRemoteToken", "retireSharedToken", "forgetLegacyClient",
           "fleetEnrollDevice", "fleetEstablish", "Stop accepting the shared token", "FleetSharedTokenStatus"]


def swift_sources(*folders):
    for folder in folders:
        for path in (ROOT / folder).rglob("*.swift"):
            yield path


class NoSharedToken(unittest.TestCase):
    def test_sources_and_the_ios_app_never_name_the_shared_token(self):
        found = []
        for path in swift_sources("Sources", "App"):
            text = path.read_text(encoding="utf-8")
            for name in RETIRED:
                # The protocol's `hello` doc and the refusal's own code name the retirement, not the file.
                if name in text:
                    found.append(f"{path.relative_to(ROOT)}: {name}")
        self.assertEqual(found, [], "the shared token is gone; use a device's or a Mac's own token")

    def test_the_refusal_says_what_to_do(self):
        text = (ROOT / "Sources/ShepherdProtocol/RemoteMessage.swift").read_text(encoding="utf-8")
        self.assertIn("This Mac no longer accepts the old shared token. Pair again with a code.", text)
        self.assertIn('sharedTokenRetiredCode = "shared_token_retired"', text)


if __name__ == "__main__":
    unittest.main()

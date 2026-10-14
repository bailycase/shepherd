"""The optional Sentry uploader never contacts a service during these tests."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sentry_symbols", ROOT / "scripts/upload-sentry-symbols.py")
uploader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uploader)


class SentrySymbolsTests(unittest.TestCase):
    def test_missing_configuration_does_not_download_or_upload(self):
        with patch.object(uploader.urllib.request, "urlopen") as download, patch.object(uploader.subprocess, "run") as run:
            uploader.upload("/unused", {})
            uploader.upload("/unused", {"SENTRY_AUTH_TOKEN": "test-only"})
        download.assert_not_called()
        run.assert_not_called()

    def test_only_verified_cli_uploads_symbols_with_a_timeout(self):
        environment = {key: "test-only" for key in
                       ("SENTRY_ORG", "SENTRY_PROJECT", "SENTRY_AUTH_TOKEN", "SHEPHERD_SENTRY_DSN")}
        data = b"test-cli"
        with tempfile.TemporaryDirectory() as directory:
            symbols = Path(directory) / "Shepherd.dSYM"
            symbols.mkdir()
            with patch.object(uploader.urllib.request, "urlopen", return_value=io.BytesIO(data)), \
                 patch.object(uploader, "CLI_SHA256", hashlib.sha256(data).hexdigest()), \
                 patch.object(uploader.subprocess, "run") as run:
                uploader.upload(directory, environment)
            args, kwargs = run.call_args
            self.assertEqual(args[0][1:], ["debug-files", "upload", "--wait", str(symbols)])
            self.assertEqual(kwargs["timeout"], 180)
            self.assertEqual(kwargs["env"]["SENTRY_AUTH_TOKEN"], "test-only")
            self.assertNotIn("test-only", args[0])
            with patch.object(uploader.urllib.request, "urlopen", return_value=io.BytesIO(data)), \
                 patch.object(uploader.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "checksum"):
                    uploader.upload(directory, environment)
            run.assert_not_called()

    def test_public_configuration_and_private_upload_credentials_stay_separate(self):
        plist = (ROOT / "App/Info.plist").read_text()
        build = (ROOT / ".github/workflows/release-build.yml").read_text()
        release = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("$(SHEPHERD_SENTRY_DSN)", plist)
        self.assertNotIn("SENTRY_AUTH_TOKEN", plist)
        self.assertIn('SHEPHERD_SENTRY_DSN="$SHEPHERD_SENTRY_DSN"', build)
        self.assertIn("SENTRY_AUTH_TOKEN:\n        required: false", build)
        self.assertIn("SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}", release)

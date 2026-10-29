from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/check-pinned-downloads.py"


class Handler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200 if self.path == "/published.zip" else 404)
        self.end_headers()

    def log_message(self, format, *args):
        pass


class CheckPinnedDownloadsTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def run_check(self, pins):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "dev-tools.env"
            path.write_text(pins)
            return subprocess.run(
                [sys.executable, SCRIPT, path], capture_output=True, text=True, check=False
            )

    def test_published_pins_pass(self):
        result = self.run_check(
            "SWIFTLINT_VERSION=0.65.1\n"
            f"OMNIWM_GHOSTTY_DOWNLOAD_URL={self.base}/published.zip\n"
            f"# OMNIWM_GHOSTTY_DOWNLOAD_URL={self.base}/v0.0.0/retired.zip\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_unpublished_pin_fails_and_names_the_key(self):
        result = self.run_check(
            f"OMNIWM_GHOSTTY_DOWNLOAD_URL={self.base}/published.zip\n"
            "OMNIWM_MALFORMED_DOWNLOAD_URL=github.com/missing-scheme.zip\n"
            f"OMNIWM_OTHER_DOWNLOAD_URL={self.base}/v9.9.9/missing.zip\n"
        )
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIn("OMNIWM_MALFORMED_DOWNLOAD_URL is not downloadable (unknown url type", result.stderr)
        self.assertIn("OMNIWM_OTHER_DOWNLOAD_URL is not downloadable (HTTP 404)", result.stderr)
        self.assertNotIn("OMNIWM_GHOSTTY_DOWNLOAD_URL", result.stderr)


if __name__ == "__main__":
    unittest.main()

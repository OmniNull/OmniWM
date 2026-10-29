from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / ".cache/flake-tools"
GOOD_SWIFT = (ROOT / "Sources/OmniWMIPC/IPCSocketPath.swift").read_text()


class MissingAsset(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(404)
        self.end_headers()

    def log_message(self, format, *args):
        pass


class PreCommitHookTests(unittest.TestCase):
    def make_repo(self):
        raw = tempfile.TemporaryDirectory()
        self.addCleanup(raw.cleanup)
        repo = Path(raw.name)
        (repo / "Scripts").mkdir()
        shutil.copy2(ROOT / "Scripts/check-pinned-downloads.py", repo / "Scripts")
        shutil.copytree(ROOT / ".githooks", repo / ".githooks")
        for name in (".swiftformat", ".swiftlint.yml", ".swift-version"):
            shutil.copy2(ROOT / name, repo / name)
        if TOOLS.exists():
            (repo / ".cache").mkdir()
            (repo / ".cache/flake-tools").symlink_to(TOOLS.resolve())
        env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}

        def git(*args):
            return subprocess.run(["git", *args], cwd=repo, env=env, capture_output=True, text=True, check=False)

        git("init", "-q")
        git("config", "core.hooksPath", ".githooks")
        git("add", ".swiftformat", ".swiftlint.yml", ".swift-version")
        return repo, git

    def commit(self, git):
        return git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "change")

    def test_unpublished_pin_warns_without_blocking_the_commit(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), MissingAsset)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        repo, git = self.make_repo()
        url = f"http://127.0.0.1:{server.server_port}/v9.9.9/GhosttyKit.zip"
        (repo / "Scripts/dev-tools.env").write_text(f"OMNIWM_GHOSTTY_DOWNLOAD_URL={url}\n")
        git("add", "Scripts/dev-tools.env")

        result = self.commit(git)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OMNIWM_GHOSTTY_DOWNLOAD_URL is not downloadable (HTTP 404)", result.stderr)
        self.assertIn("pre-commit: warning", result.stderr)
        self.assertEqual(git("rev-list", "--count", "HEAD").stdout.strip(), "1")

    @unittest.skipUnless((TOOLS / "bin/swiftformat").exists(), "needs make setup-tools")
    def test_swift_checks_read_the_staged_content(self):
        repo, git = self.make_repo()
        (repo / "Sources").mkdir()
        source = repo / "Sources/Socket.swift"
        source.write_text(GOOD_SWIFT.replace("    public static", "  public   static", 1))
        git("add", "Sources/Socket.swift")
        source.write_text(GOOD_SWIFT)

        result = self.commit(git)

        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(git("rev-parse", "--verify", "-q", "HEAD").returncode, 0)

    @unittest.skipUnless((TOOLS / "bin/swiftlint").exists(), "needs make setup-tools")
    def test_swiftlint_only_checks_the_sources_make_lint_covers(self):
        repo, git = self.make_repo()
        shutil.copy2(ROOT / "Package.swift", repo / "Package.swift")
        git("add", "Package.swift")

        result = self.commit(git)

        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()

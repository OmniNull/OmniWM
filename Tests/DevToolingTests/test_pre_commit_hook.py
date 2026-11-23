from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(os.environ.get("OMNIWM_DEV_TOOLS") or ROOT / ".cache/flake-tools")
GOOD_SWIFT = (ROOT / "Sources/OmniWMIPC/IPCSocketPath.swift").read_text()


class MissingAsset(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(404)
        self.end_headers()

    def log_message(self, format, *args):
        pass


class PreCommitHookTests(unittest.TestCase):
    def require_tools(self, *names):
        for name in names:
            tool = TOOLS / "bin" / name
            self.assertTrue(tool.is_file() and os.access(tool, os.X_OK),
                            f"{tool} is required; load the nix shell or run make setup-tools")

    def make_repo(self, dev_tools=None):
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
        env.pop("OMNIWM_DEV_TOOLS", None)
        if dev_tools is not None:
            env["OMNIWM_DEV_TOOLS"] = dev_tools

        def git(*args):
            return subprocess.run(["git", *args], cwd=repo, env=env, capture_output=True, text=True, check=False)

        git("init", "-q")
        git("config", "core.hooksPath", ".githooks")
        git("add", ".swiftformat", ".swiftlint.yml", ".swift-version")
        baseline = self.commit(git, "-c", "core.hooksPath=/dev/null")
        self.assertEqual(baseline.returncode, 0, baseline.stderr)
        return repo, git

    def commit(self, git, *options):
        return git(*options, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "change")

    def make_ipc_repo(self):
        self.require_tools("swiftformat")
        repo, git = self.make_repo()
        for script in ("generate_ipc_wire.py", "ipc_wire_models.py", "dev-tools.env"):
            shutil.copy2(ROOT / "Scripts" / script, repo / "Scripts")
        shutil.copytree(ROOT / "Sources/OmniWMIPC", repo / "Sources/OmniWMIPC")
        git("add", "Scripts", "Sources")
        baseline = self.commit(git, "-c", "core.hooksPath=/dev/null")
        self.assertEqual(baseline.returncode, 0, baseline.stderr)
        return repo, git

    def stage_model_comment(self, repo, git):
        with (repo / "Scripts/ipc_wire_models.py").open("a") as models:
            models.write("\n# comment only\n")
        result = git("add", "Scripts/ipc_wire_models.py")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_staged_whitespace_errors_and_conflict_markers(self):
        for content, error in (("word \n", "trailing whitespace"), ("<<<<<<< HEAD\n", "conflict marker")):
            with self.subTest(error=error):
                repo, git = self.make_repo()
                path = repo / "notes.txt"
                path.write_text(content)
                git("add", "notes.txt")
                path.write_text("clean\n")

                result = self.commit(git)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stdout + result.stderr)

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
        self.assertEqual(git("show", "HEAD:Scripts/dev-tools.env").stdout, f"OMNIWM_GHOSTTY_DOWNLOAD_URL={url}\n")

    def test_swift_checks_read_the_staged_content(self):
        self.require_tools("swiftformat", "swiftlint")
        repo, git = self.make_repo()
        (repo / "Sources").mkdir()
        source = repo / "Sources/Socket.swift"
        source.write_text(GOOD_SWIFT.replace("    public static", "  public   static", 1))
        git("add", "Sources/Socket.swift")
        source.write_text(GOOD_SWIFT)

        result = self.commit(git)

        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(git("cat-file", "-e", "HEAD:Sources/Socket.swift").returncode, 0)

    def test_swiftlint_only_checks_the_sources_make_lint_covers(self):
        self.require_tools("swiftformat", "swiftlint")
        repo, git = self.make_repo()
        shutil.copy2(ROOT / "Package.swift", repo / "Package.swift")
        git("add", "Package.swift")

        result = self.commit(git)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_relative_dev_tools_path_works_in_the_swift_snapshot(self):
        self.require_tools("swiftformat", "swiftlint")
        repo, git = self.make_repo(dev_tools=".cache/flake-tools")
        shutil.copy2(ROOT / "Package.swift", repo / "Package.swift")
        git("add", "Package.swift")

        result = self.commit(git)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_ipc_check_compares_the_staged_models_and_encoders(self):
        repo, git = self.make_ipc_repo()
        generated = repo / "Sources/OmniWMIPC/IPCJSONWriter+Models01.swift"
        original = generated.read_text()
        outdated = original.replace(f"begin({ord('{')})", f"begin({ord('[')})", 1)
        self.assertNotEqual(original, outdated)
        generated.write_text(outdated)
        git("add", str(generated))
        generated.write_text(original)

        result = self.commit(git)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Generated IPC wire files are stale: IPCJSONWriter+Models01.swift", result.stderr)

    def test_ipc_check_runs_when_only_swiftformat_configuration_changes(self):
        repo, git = self.make_ipc_repo()
        config = repo / ".swiftformat"
        original = config.read_text()
        config.write_text(original.replace("--indent 4", "--indent 2"))
        git("add", ".swiftformat")
        config.write_text(original)

        result = self.commit(git)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Generated IPC wire files are stale:", result.stderr)

    def test_ipc_check_ignores_intent_to_add_encoders(self):
        repo, git = self.make_ipc_repo()
        extra = "Sources/OmniWMIPC/IPCJSONWriter+Models99.swift"
        (repo / extra).write_text("// in progress\n")
        intent = git("add", "-N", extra)
        self.assertEqual(intent.returncode, 0, intent.stderr)
        self.stage_model_comment(repo, git)

        result = self.commit(git)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(extra, git("ls-tree", "-r", "--name-only", "HEAD").stdout.splitlines())

    def test_ipc_check_reads_encoders_outside_a_sparse_checkout(self):
        repo, git = self.make_ipc_repo()
        sparse = git("sparse-checkout", "set", "Scripts", ".githooks")
        self.assertEqual(sparse.returncode, 0, sparse.stderr)
        self.stage_model_comment(repo, git)

        result = self.commit(git)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((repo / "Sources/OmniWMIPC").exists())

    def test_ipc_check_rejects_a_formatter_that_differs_from_the_staged_pin(self):
        for stage_generator in (False, True):
            with self.subTest(stage_generator=stage_generator):
                repo, git = self.make_ipc_repo()
                pins = repo / "Scripts/dev-tools.env"
                original = pins.read_text()
                staged_version = "different-from-installed"
                pins.write_text("\n".join(
                    f"SWIFTFORMAT_VERSION={staged_version}" if line.startswith("SWIFTFORMAT_VERSION=") else line
                    for line in original.splitlines()
                ) + "\n")
                git("add", "Scripts/dev-tools.env")
                pins.write_text(original)
                if stage_generator:
                    self.stage_model_comment(repo, git)

                result = self.commit(git)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"SwiftFormat {staged_version} required", result.stderr)
                self.assertIn("make setup-tools", result.stderr)


if __name__ == "__main__":
    unittest.main()

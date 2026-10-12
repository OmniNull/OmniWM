import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile


SOURCE = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("omniwm_release", SOURCE / "Scripts/omniwm_release.py")
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="omniwm-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.version = "0.7.4"
        self.commit = "a" * 40
        self.original = "b" * 40
        self.head = self.commit
        self.remote_main = self.original
        self.remote_tag = None
        self.release = None
        self.download_error = False
        self.download_corrupt = False
        self.commands = []
        self.runner = Mock()
        self.runner.run.side_effect = self.run_command
        self.manager = RELEASE.ReleaseManager(RELEASE.Config(self.root, "OmniNull/OmniWM"), self.runner)
        self.manager.git = Mock(side_effect=self.git)
        self.manager.fetch = Mock()
        self.manager.verify_destinations = Mock()
        self.manager.verify_app_zip = Mock()
        self.manager.repo_state = Mock(return_value=RELEASE.RepoState("main", True, "", 1, 0, self.commit))
        self.manager.remote_tag_commit = Mock(side_effect=lambda tag: self.remote_tag)
        self.manager.local_tag_commit = Mock(return_value=self.commit)
        self.manager.github_release = Mock(side_effect=lambda tag: self.release)
        self.manager.latest_github_release_tag = Mock(return_value=self.manager.tag(self.version))
        scripts = self.root / "Scripts"
        scripts.mkdir()
        (scripts / "ghostty-preflight.sh").write_text("#!/bin/bash\nexit 0\n")
        self.framework = self.root / "Frameworks/GhosttyKit.xcframework"
        (self.framework / "macos-arm64/Headers").mkdir(parents=True)
        (self.framework / "Info.plist").write_text("framework metadata")
        (self.framework / "macos-arm64/Headers/ghostty.h").write_text("header")
        archive = self.framework / "macos-arm64/libghostty-internal.a"
        archive.write_bytes(b"library")
        self.paths = self.manager.asset_paths(self.version)
        self.paths["ghostty"].parent.mkdir()
        with zipfile.ZipFile(self.paths["ghostty"], "w") as zipped:
            for path in self.framework.rglob("*"):
                if path.is_file():
                    zipped.write(path, path.relative_to(self.framework.parent))
        self.zip_sha = RELEASE.sha256_file(self.paths["ghostty"])
        (scripts / "dev-tools.env").write_text(
            f"OMNIWM_GHOSTTY_DOWNLOAD_URL={self.manager.ghostty_release_url(self.version)}\n"
            f"OMNIWM_GHOSTTY_ZIP_SHA256={self.zip_sha}\n"
        )
        (scripts / "build-metadata.env").write_text(
            "OMNIWM_GHOSTTY_ARCHIVE_RELATIVE_PATH=Frameworks/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a\n"
            f"OMNIWM_GHOSTTY_ARCHIVE_SHA256={RELEASE.sha256_file(archive)}\n"
        )
        self.paths["app"].write_bytes(b"signed app fixture")
        self.paths["notes"].write_text("release notes\n")
        self.manifest = {
            "schema": RELEASE.MANIFEST_SCHEMA,
            "version": self.version,
            "tag": self.manager.tag(self.version),
            "previous_tag": "v0.7.3",
            "previous_version": "0.7.3",
            "build": 86,
            "state": "sealed",
            "sealed": True,
            "original_main_head": self.original,
            "release_commit": self.commit,
            "embedded_git_hash": self.commit[:8],
            "signing_identity": RELEASE.SIGNING_IDENTITY,
            "notarize_profile": RELEASE.NOTARIZE_PROFILE,
            "notarization": {"status": "verified", "stapled": True},
            "destinations": {"main_remote": "https://github.com/OmniNull/OmniWM.git", "github_repo": "OmniNull/OmniWM"},
            "assets": {
                name: {"path": str(self.paths[name]), "sha256": RELEASE.sha256_file(self.paths[name])}
                for name in ("app", "ghostty")
            },
            "notes_sha256": RELEASE.sha256_file(self.paths["notes"]),
            "published": {stage: False for stage in RELEASE.PUBLIC_STAGES},
            "release_url": None,
        }
        self.manager.save_manifest(self.manifest)

    def git(self, repo, *args, **kwargs):
        if args == ("rev-parse", "HEAD"):
            return self.head
        if args == ("rev-parse", "origin/main"):
            return self.remote_main
        if args == ("rev-parse", "--short", self.commit):
            return self.commit[:8]
        if args == ("branch", "--show-current"):
            return "main"
        if args == ("status", "--porcelain=v1"):
            return ""
        raise AssertionError(args)

    def run_command(self, args, **kwargs):
        command = [str(arg) for arg in args]
        self.commands.append(command)
        code = 0
        if command[0] == "curl":
            if self.download_error:
                raise RELEASE.ReleaseError("public dependency download failed: HTTP 404")
            destination = Path(command[command.index("--output") + 1])
            if self.download_corrupt:
                destination.write_bytes(b"wrong public dependency")
            else:
                shutil.copy2(self.paths["ghostty"], destination)
        elif command[:3] == ["ditto", "-x", "-k"]:
            with zipfile.ZipFile(command[3]) as zipped:
                zipped.extractall(command[4])
        elif command[:3] == ["gh", "release", "create"]:
            self.release = {
                "tagName": self.manifest["tag"],
                "name": f"OmniWM v{self.version}",
                "body": self.paths["notes"].read_text(),
                "url": f"https://github.com/OmniNull/OmniWM/releases/tag/{self.manifest['tag']}",
                "isDraft": False,
                "isPrerelease": False,
                "assets": [{"name": self.paths[name].name} for name in ("app", "ghostty")],
            }
        elif command[:3] == ["gh", "release", "download"]:
            destination = Path(command[command.index("--dir") + 1])
            for name in ("app", "ghostty"):
                shutil.copy2(self.paths[name], destination / self.paths[name].name)
        elif command[:3] == ["git", "push", "origin"]:
            if command[3] == "main":
                self.remote_main = self.commit
            else:
                self.remote_tag = self.commit
        elif command[:3] == ["git", "merge-base", "--is-ancestor"]:
            code = 0 if command[3] == self.remote_main else 1
        return subprocess.CompletedProcess(command, code, "", "")

    def command_index(self, prefix):
        return next(index for index, command in enumerate(self.commands) if command[:len(prefix)] == prefix)

    def source_build(self):
        directory = self.root / "source-build"
        directory.mkdir()
        shutil.copy2(self.paths["ghostty"], directory / "GhosttyKit.xcframework.zip")
        provenance = {
            "source_repository": "https://github.com/ghostty-org/ghostty.git",
            "source_revision": "c" * 40,
            "zig_version": "0.16.0",
            "zip_sha256": self.zip_sha,
            "framework_files": self.manager.framework_hashes(self.framework),
        }
        (directory / "provenance.json").write_text(json.dumps(provenance))
        return directory

    def test_source_build_installs_verified_files_and_pins_the_release_asset(self):
        directory = self.source_build()
        (self.framework / "macos-arm64/libghostty-internal.a").write_bytes(b"old library")
        self.runner.output.return_value = "arm64"
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
            self.manager.install_ghostty_build(self.version, directory)
        pins = self.manager.ghostty_pins()
        self.assertEqual(pins["OMNIWM_GHOSTTY_SOURCE_COMMIT"], "c" * 40)
        self.assertEqual(pins["OMNIWM_GHOSTTY_ZIG_VERSION"], "0.16.0")
        self.assertEqual(pins["OMNIWM_GHOSTTY_ZIP_SHA256"], self.zip_sha)
        self.assertEqual(pins["OMNIWM_GHOSTTY_DOWNLOAD_URL"], self.manager.ghostty_release_url(self.version))
        self.assertEqual((self.framework / "macos-arm64/libghostty-internal.a").read_bytes(), b"library")
        self.assertFalse(any(command[0] == "curl" for command in self.commands))

    def test_source_build_cannot_replace_a_local_developer_framework(self):
        directory = self.source_build()
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}):
            with self.assertRaisesRegex(RELEASE.ReleaseError, "disposable Actions runner"):
                self.manager.install_ghostty_build(self.version, directory)
        self.assertEqual(self.commands, [])

    def test_invalid_source_provenance_preserves_existing_framework_and_pins(self):
        directory = self.source_build()
        provenance_path = directory / "provenance.json"
        original = json.loads(provenance_path.read_text())
        before = self.manager.framework_hashes(self.framework)
        pins = self.manager.ghostty_pins()
        for field, value in (("zip_sha256", "0" * 64), ("framework_files", {}), ("source_repository", "https://example.com/fork.git")):
            with self.subTest(field=field), patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
                provenance_path.write_text(json.dumps({**original, field: value}))
                with self.assertRaises(RELEASE.ReleaseError):
                    self.manager.install_ghostty_build(self.version, directory)
                self.assertEqual(self.manager.framework_hashes(self.framework), before)
                self.assertEqual(self.manager.ghostty_pins(), pins)

    def test_github_write_access_accepts_reported_push_permission(self):
        self.runner.run.side_effect = None
        self.runner.run.return_value = subprocess.CompletedProcess([], 0, "true\n", "")
        self.assertTrue(self.manager.github_write_access("OmniNull/OmniWM")["ok"])
        self.assertEqual(self.runner.run.call_count, 1)

    def test_github_write_access_probes_installation_token_without_pushing(self):
        self.manager.remote_url = Mock(return_value="https://github.com/OmniNull/OmniWM.git")
        self.runner.run.side_effect = [
            subprocess.CompletedProcess([], 0, "unknown\n", ""),
            subprocess.CompletedProcess([], 0, "", "Everything up-to-date"),
        ]
        self.assertTrue(self.manager.github_write_access("OmniNull/OmniWM")["ok"])
        self.assertEqual(
            self.runner.run.call_args.args[0],
            ["git", "push", "--dry-run", "origin", "origin/main:refs/heads/main"],
        )

    def test_github_write_access_rejects_denied_installation_token(self):
        self.manager.remote_url = Mock(return_value="https://github.com/OmniNull/OmniWM.git")
        self.runner.run.side_effect = [
            subprocess.CompletedProcess([], 0, "unknown\n", ""),
            subprocess.CompletedProcess([], 128, "", "Write access to repository not granted"),
        ]
        access = self.manager.github_write_access("OmniNull/OmniWM")
        self.assertFalse(access["ok"])
        self.assertIn("Write access", access["detail"])
        self.assertIn("GH_TOKEN/GITHUB_TOKEN", access["detail"])
        self.assertIn("--dry-run", self.runner.run.call_args.args[0])

    def test_github_write_access_probes_false_actions_permission_without_pushing(self):
        self.manager.remote_url = Mock(return_value="https://github.com/OmniNull/OmniWM.git")
        for code, detail in ((0, "Everything up-to-date"), (128, "Write access to repository not granted")):
            with self.subTest(code=code), patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
                self.runner.run.reset_mock()
                self.runner.run.side_effect = [
                    subprocess.CompletedProcess([], 0, "false\n", ""),
                    subprocess.CompletedProcess([], code, "", detail),
                ]
                access = self.manager.github_write_access("OmniNull/OmniWM")
                self.assertEqual(access["ok"], code == 0)
                self.assertIn(detail, access["detail"])
                self.assertEqual(self.runner.run.call_count, 2)
                self.assertEqual(
                    self.runner.run.call_args.args[0],
                    ["git", "push", "--dry-run", "origin", "origin/main:refs/heads/main"],
                )

    def test_github_write_access_does_not_probe_other_repository(self):
        self.manager.remote_url = Mock(return_value="https://github.com/other/repo.git")
        for actions, output in (("false", "unknown\n"), ("true", "false\n")):
            with self.subTest(actions=actions), patch.dict(os.environ, {"GITHUB_ACTIONS": actions}):
                self.runner.run.reset_mock()
                self.runner.run.side_effect = None
                self.runner.run.return_value = subprocess.CompletedProcess([], 0, output, "")
                with self.assertRaisesRegex(RELEASE.ReleaseError, "does not match"):
                    self.manager.github_write_access("OmniNull/OmniWM")
                self.assertEqual(self.runner.run.call_count, 1)

    def test_github_write_access_rejects_user_denial_and_api_errors(self):
        for actions, code, output in (
            ("false", 0, "false\n"),
            ("false", 1, "null\n"),
            ("false", 0, ""),
            ("true", 1, "false\n"),
            ("true", 1, "unknown\n"),
            ("true", 0, ""),
        ):
            with self.subTest(actions=actions, code=code, output=output), patch.dict(os.environ, {"GITHUB_ACTIONS": actions}):
                self.runner.run.reset_mock()
                self.runner.run.side_effect = None
                self.runner.run.return_value = subprocess.CompletedProcess([], code, output, "")
                self.assertFalse(self.manager.github_write_access("OmniNull/OmniWM")["ok"])
                self.assertEqual(self.runner.run.call_count, 1)

    def smoke_test_app(self):
        app = self.root / "OmniWM.app"
        executable = app / "Contents/MacOS/OmniWM"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"app executable")
        return app

    def test_smoke_test_launches_by_default(self):
        process = self.runner.popen.return_value
        process.poll.return_value = None
        with patch.dict(os.environ, {}, clear=True), patch.object(RELEASE.time, "sleep"):
            self.manager.smoke_test(self.smoke_test_app())
        self.runner.popen.assert_called_once()
        process.terminate.assert_called_once()
        process.wait.assert_called_once_with(timeout=5)

    def test_smoke_test_reports_early_exit_output_tail(self):
        process = Mock()
        process.poll.return_value = 23
        process.returncode = 23

        def launch(args, **kwargs):
            kwargs["output"].write(b"old log line\n" * 2000 + b"app failed to connect to WindowServer\n")
            return process

        self.runner.popen.side_effect = launch
        with patch.dict(os.environ, {}, clear=True), patch.object(RELEASE.time, "sleep"):
            with self.assertRaisesRegex(RELEASE.ReleaseError, "with 23") as error:
                self.manager.smoke_test(self.smoke_test_app())
        self.assertIn("app failed to connect to WindowServer", str(error.exception))
        self.assertLess(len(str(error.exception)), 9000)
        process.terminate.assert_not_called()

    def test_config_requires_explicit_ci_checkout(self):
        for value in (None, "", str(self.root / "missing"), str(self.root)):
            with self.subTest(value=value), patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}, clear=True):
                if value is not None:
                    os.environ["OMNIWM_RELEASE_MAIN_REPO"] = value
                with self.assertRaisesRegex(RELEASE.ReleaseError, "OMNIWM_RELEASE_MAIN_REPO"):
                    RELEASE.Config.from_environment()

    def test_config_accepts_explicit_ci_git_checkout(self):
        subprocess.run(["git", "init", self.root], check=True, capture_output=True)
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "OMNIWM_RELEASE_MAIN_REPO": str(self.root)}, clear=True):
            self.assertEqual(RELEASE.Config.from_environment().main_repo, self.root)

    def test_config_rejects_invalid_git_directory_in_ci(self):
        (self.root / ".git").mkdir()
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "OMNIWM_RELEASE_MAIN_REPO": str(self.root)}, clear=True):
            with self.assertRaisesRegex(RELEASE.ReleaseError, "OMNIWM_RELEASE_MAIN_REPO"):
                RELEASE.Config.from_environment()

    def test_cli_reports_missing_ci_checkout_without_traceback(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}, clear=True), patch.object(
            RELEASE.sys, "argv", ["omniwm_release.py", "status", self.version]
        ), patch.object(RELEASE.sys, "stderr") as stderr:
            self.assertEqual(RELEASE.main(), 1)
        self.assertIn("OMNIWM_RELEASE_MAIN_REPO", "".join(call.args[0] for call in stderr.write.call_args_list))

    def test_config_keeps_local_default_checkout(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(RELEASE.Config.from_environment().main_repo, RELEASE.DEFAULT_MAIN_REPO)

    def test_smoke_test_requires_explicit_opt_out_and_logs_it(self):
        with patch.dict(os.environ, {"OMNIWM_RELEASE_SKIP_APP_LAUNCH": "1"}), patch("builtins.print") as log:
            self.manager.smoke_test(self.smoke_test_app())
        self.runner.popen.assert_not_called()
        self.assertIn("WARNING: skipping app launch smoke test", log.call_args.args[0])

    def test_smoke_test_opt_out_still_requires_executable(self):
        with patch.dict(os.environ, {"OMNIWM_RELEASE_SKIP_APP_LAUNCH": "1"}):
            with self.assertRaisesRegex(RELEASE.ReleaseError, "missing app executable"):
                self.manager.smoke_test(self.root / "missing.app")

    def test_smoke_test_rejects_invalid_opt_out(self):
        with patch.dict(os.environ, {"OMNIWM_RELEASE_SKIP_APP_LAUNCH": "true"}):
            with self.assertRaisesRegex(RELEASE.ReleaseError, "must be 0 or 1"):
                self.manager.smoke_test(self.smoke_test_app())
        self.runner.popen.assert_not_called()

    def app_zip_fixture(self):
        with zipfile.ZipFile(self.paths["app"], "w") as zipped:
            zipped.writestr(
                "OmniWM.app/Contents/Info.plist",
                plistlib.dumps({
                    "CFBundleShortVersionString": self.version,
                    "CFBundleVersion": str(self.manifest["build"]),
                    "OMNIWMGitHash": self.commit[:8],
                }),
            )
            zipped.writestr("OmniWM.app/Contents/MacOS/OmniWM", b"executable")
        self.manager.check_distribution = Mock()
        run_command = self.run_command

        def signed_command(args, **kwargs):
            result = run_command(args, **kwargs)
            if list(args)[:2] == ["codesign", "-dv"]:
                result.stderr = f"Authority={RELEASE.SIGNING_IDENTITY}\n"
            return result

        self.runner.run.side_effect = signed_command

    def test_app_zip_opt_out_keeps_distribution_signature_and_quarantine_checks(self):
        self.app_zip_fixture()
        with patch.dict(os.environ, {"OMNIWM_RELEASE_SKIP_APP_LAUNCH": "1"}):
            RELEASE.ReleaseManager.verify_app_zip(
                self.manager, self.paths["app"], version=self.version,
                build=self.manifest["build"], embedded_hash=self.commit[:8],
                signing_identity=RELEASE.SIGNING_IDENTITY,
            )
        self.assertEqual(self.manager.check_distribution.call_count, 2)
        self.assertTrue(self.manager.check_distribution.call_args.kwargs["verbose"])
        self.assertTrue(any(command[:2] == ["codesign", "-dv"] for command in self.commands))
        self.assertTrue(any(command[:3] == ["xattr", "-w", "com.apple.quarantine"] for command in self.commands))
        self.runner.popen.assert_not_called()

    def test_app_zip_opt_out_still_rejects_signing_identity_mismatch(self):
        self.app_zip_fixture()
        with patch.dict(os.environ, {"OMNIWM_RELEASE_SKIP_APP_LAUNCH": "1"}):
            with self.assertRaisesRegex(RELEASE.ReleaseError, "signing identity does not match"):
                RELEASE.ReleaseManager.verify_app_zip(
                    self.manager, self.paths["app"], version=self.version,
                    build=self.manifest["build"], embedded_hash=self.commit[:8],
                    signing_identity="wrong identity",
                )
        self.runner.popen.assert_not_called()

    def test_publish_downloads_pinned_asset_before_main(self):
        self.manager.publish(self.version, True)
        tag = self.command_index(["git", "push", "origin", self.manifest["tag"]])
        release = self.command_index(["gh", "release", "create"])
        download = self.command_index(["curl"])
        main = self.command_index(["git", "push", "origin", "main"])
        self.assertLess(tag, release)
        self.assertLess(release, download)
        self.assertLess(download, main)
        self.assertEqual(self.commands[download][-1], self.manager.ghostty_release_url(self.version))
        self.assertEqual(self.commands[download][1], "--disable")
        self.assertIn("--retry-all-errors", self.commands[download])
        self.assertEqual(self.commands[download][self.commands[download].index("--retry") + 1], "5")
        self.assertEqual(self.commands[download][self.commands[download].index("--retry-delay") + 1], "5")
        final = self.manager.load_manifest(self.version)
        self.assertEqual(final["state"], "published")
        self.assertTrue(all(final["published"].values()))

    def test_fresh_prepare_manifest_replays_every_public_checkpoint_idempotently(self):
        prepared = json.loads(json.dumps(self.manifest))
        prepared.update({"state": "prepared", "sealed": False, "notes_sha256": None})
        for completed in ("tag", "release", "main"):
            with self.subTest(completed=completed):
                self.commands.clear()
                self.remote_main = self.original
                self.remote_tag = None
                self.release = None
                checkpoint = json.loads(json.dumps(self.manifest))
                handlers = {
                    "tag": self.manager.ensure_tag_published,
                    "release": self.manager.ensure_release_published,
                    "main": self.manager.ensure_main_published,
                }
                for stage, handler in handlers.items():
                    handler(checkpoint)
                    if stage == completed:
                        break
                # A new runner downloads the original prepare artifact, not checkpoint.
                self.manager.save_manifest(prepared)
                self.manager.verify(self.version)
                self.manager.publish(self.version, True)
                self.assertEqual(self.remote_main, self.commit)
                self.assertEqual(self.manager.load_manifest(self.version)["state"], "published")
                self.assertEqual(sum(command[:3] == ["gh", "release", "create"] for command in self.commands), 1)
                for ref in (self.manifest["tag"], "main"):
                    self.assertEqual(sum(command == ["git", "push", "origin", ref] for command in self.commands), 1)

    def test_retry_after_successful_main_push_verifies_tag_and_release_without_push(self):
        self.manager.publish(self.version, True)
        self.commands.clear()
        self.manager.remote_tag_commit.reset_mock()
        self.manager.github_release.reset_mock()
        prepared = json.loads(json.dumps(self.manifest))
        prepared.update({"state": "prepared", "sealed": False, "notes_sha256": None})
        self.manager.save_manifest(prepared)
        self.manager.verify(self.version)
        self.manager.publish(self.version, True)
        self.assertFalse(any(command[:2] == ["git", "push"] for command in self.commands))
        self.manager.remote_tag_commit.assert_called_with(self.manifest["tag"])
        self.manager.github_release.assert_called_with(self.manifest["tag"])
        self.assertTrue(any(command[:3] == ["gh", "release", "download"] for command in self.commands))
        self.assertEqual(self.manager.load_manifest(self.version)["state"], "published")

    def test_unrelated_remote_main_fails_before_any_public_stage(self):
        self.remote_main = "c" * 40
        run_command = self.run_command

        def unrelated_main(args, **kwargs):
            if list(args)[:3] == ["git", "merge-base", "--is-ancestor"]:
                return subprocess.CompletedProcess(args, 1, "", "")
            return run_command(args, **kwargs)

        self.runner.run.side_effect = unrelated_main
        with self.assertRaisesRegex(RELEASE.ReleaseError, "origin/main has diverged"):
            self.manager.publish(self.version, True)
        self.assertIsNone(self.remote_tag)
        self.assertIsNone(self.release)
        self.assertFalse(any(command[:2] == ["git", "push"] for command in self.commands))

    def test_fresh_prepare_manifest_cannot_replace_already_published_notes(self):
        self.manager.ensure_tag_published(self.manifest)
        self.manager.ensure_release_published(self.manifest)
        prepared = json.loads(json.dumps(self.manifest))
        prepared.update({"state": "prepared", "sealed": False, "notes_sha256": None, "release_url": None})
        self.manager.save_manifest(prepared)
        self.paths["notes"].write_text("changed reviewed notes\n")
        self.manager.verify(self.version)
        with self.assertRaisesRegex(RELEASE.ReleaseError, "release notes mismatch"):
            self.manager.publish(self.version, True)
        self.assertEqual(self.remote_main, self.original)
        self.assertNotIn(["git", "push", "origin", "main"], self.commands)

    def test_public_download_failure_is_resumable_without_main_push(self):
        self.download_error = True
        with self.assertRaisesRegex(RELEASE.ReleaseError, "HTTP 404"):
            self.manager.publish(self.version, True)
        checkpoint = self.manager.load_manifest(self.version)
        self.assertEqual(checkpoint["state"], "published-release")
        self.assertEqual(checkpoint["published"], {"tag": True, "release": True, "main": False})
        self.assertEqual(self.remote_main, self.original)
        self.download_error = False
        self.manager.publish(self.version, True)
        self.assertEqual(self.remote_main, self.commit)
        self.assertEqual(sum(command[:3] == ["gh", "release", "create"] for command in self.commands), 1)

    def test_public_download_hash_mismatch_never_pushes_main(self):
        self.download_corrupt = True
        with self.assertRaisesRegex(RELEASE.ReleaseError, "ZIP hash mismatch"):
            self.manager.publish(self.version, True)
        self.assertEqual(self.remote_main, self.original)
        self.assertFalse(self.manager.load_manifest(self.version)["published"]["main"])

    def test_resume_after_tag_revalidates_release_and_dependency(self):
        self.remote_tag = self.commit
        self.manifest["published"]["tag"] = True
        self.manifest["state"] = "published-tag"
        self.manager.save_manifest(self.manifest)
        self.manager.publish(self.version, True)
        self.assertNotIn(["git", "push", "origin", self.manifest["tag"]], self.commands)
        self.assertLess(self.command_index(["curl"]), self.command_index(["git", "push", "origin", "main"]))

    def test_package_reuses_exact_pinned_zip(self):
        self.manager.create_zip = Mock(side_effect=AssertionError("must not repack"))
        self.manager.package_ghostty(self.version)
        self.assertEqual(RELEASE.sha256_file(self.paths["ghostty"]), self.zip_sha)
        self.assertFalse(any(command[0] == "curl" for command in self.commands))

    def test_candidate_zip_hash_drift_is_rejected_before_publication(self):
        with self.paths["ghostty"].open("ab") as archive:
            archive.write(b"changed")
        with self.assertRaisesRegex(RELEASE.ReleaseError, "ZIP hash mismatch"):
            self.manager.package_ghostty(self.version)
        self.assertIsNone(self.remote_tag)
        self.assertIsNone(self.release)

    def test_complete_framework_comparison_includes_headers(self):
        (self.framework / "macos-arm64/Headers/ghostty.h").write_text("different header")
        with self.assertRaisesRegex(RELEASE.ReleaseError, "contents differ"):
            self.manager.verify_ghostty_dependency(self.version)

    def test_existing_dependency_pin_uses_public_download(self):
        pins = self.root / "Scripts/dev-tools.env"
        url = self.manager.ghostty_release_url("0.7.3")
        pins.write_text(pins.read_text().replace(self.manager.ghostty_release_url(self.version), url))
        self.assertEqual(self.manager.verify_ghostty_dependency(self.version), url)
        self.assertEqual(self.commands[self.command_index(["curl"])][-1], url)

    def test_dirty_pins_cannot_replace_frozen_metadata(self):
        self.manager.git = Mock(return_value=" M Scripts/dev-tools.env")
        with self.assertRaisesRegex(RELEASE.ReleaseError, "frozen commit"):
            self.manager.verify_manifest(self.manifest, False)

    def test_abort_refuses_observed_public_stage_with_stale_flags(self):
        self.remote_tag = self.commit
        with self.assertRaisesRegex(RELEASE.ReleaseError, "any public stage"):
            self.manager.abort(self.version)
        self.assertTrue(self.paths["ghostty"].exists())
        self.assertTrue(self.manager.manifest_path(self.version).exists())

    def test_local_abort_preserves_pinned_dependency_for_retry(self):
        self.manager.abort(self.version)
        self.assertEqual(RELEASE.sha256_file(self.paths["ghostty"]), self.zip_sha)
        self.assertFalse(self.paths["app"].exists())
        self.assertFalse(self.manager.manifest_path(self.version).exists())

    def test_schema_three_history_retains_previous_stage_order(self):
        self.manifest["schema"] = 3
        self.manifest["state"] = "published"
        self.manifest["published"] = {"main": True, "tag": True, "release": True}
        self.manifest["release_url"] = "https://github.com/OmniNull/OmniWM/releases/tag/v0.7.4"
        self.manager.manifest_path(self.version).write_text(json.dumps(self.manifest))
        self.assertEqual(RELEASE.manifest_stages(self.manifest), ("main", "tag", "release"))
        self.assertTrue(self.manager.status(self.version))
        self.manager.fetch.assert_not_called()
        with self.assertRaisesRegex(RELEASE.ReleaseError, "historical manifests are read-only"):
            self.manager.publish(self.version, True)


if __name__ == "__main__":
    unittest.main()

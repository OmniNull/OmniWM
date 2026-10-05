import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("canary_release", SOURCE / "Scripts/canary_release.py")
canary_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(canary_release)


def run(args, cwd=None):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"{args} failed: {result.stderr}")
    return result


class GitRepo:
    def __init__(self, path):
        self.path = Path(path)

    def git(self, *args, date=None):
        env = dict(os.environ)
        if date:
            env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = date
        result = subprocess.run(
            ["git", "-C", str(self.path), *args],
            capture_output=True,
            text=True,
            env=env,
        )
        if result.returncode != 0:
            raise AssertionError(f"git {args} failed: {result.stderr}")
        return result.stdout.strip()

    def commit(self, message, date=None):
        self.git("commit", "--allow-empty", "-m", message, date=date)

    def tag(self, name, date=None):
        self.git("tag", name, date=date)

    def annotated_tag(self, name, date):
        self.git("tag", "-a", name, "-m", "release", date=date)


class CanaryReleaseTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = GitRepo(tempfile.mkdtemp(dir=self._tmp.name))
        self.repo.git("init", "-q", "--initial-branch=main")
        self.repo.git("config", "user.name", "Test")
        self.repo.git("config", "user.email", "test@example.com")

    def seed_release(self):
        self.repo.commit("c1", date="2026-01-01T12:00:00+00:00")
        self.repo.tag("v0.7.5")

    def test_no_tags_builds(self):
        self.repo.commit("c1")
        self.assertEqual(canary_release.check(str(self.repo.path), False)["should_skip"], "false")

    def test_head_on_stable_tag_skips(self):
        self.seed_release()
        result = canary_release.check(str(self.repo.path), False)
        self.assertEqual(result["should_skip"], "true")
        self.assertIn("v0.7.5", result["skip_reason"])

    def test_head_on_canary_tag_skips(self):
        self.seed_release()
        self.repo.commit("c2")
        self.repo.commit("c3")
        self.repo.tag("canary-20261005-0400")
        result = canary_release.check(str(self.repo.path), False)
        self.assertEqual(result["should_skip"], "true")
        self.assertIn("canary-20261005-0400", result["skip_reason"])

    def test_commit_after_every_tag_builds(self):
        self.seed_release()
        self.repo.commit("c2")
        self.repo.tag("canary-20261004-0400")
        self.repo.commit("c3")
        self.assertEqual(canary_release.check(str(self.repo.path), False)["should_skip"], "false")

    def test_commit_after_release_tag_builds(self):
        self.seed_release()
        self.repo.commit("c2")
        self.assertEqual(canary_release.check(str(self.repo.path), False)["should_skip"], "false")

    def test_force_overrides_skip(self):
        self.seed_release()
        self.assertEqual(canary_release.check(str(self.repo.path), True)["should_skip"], "false")

    def test_newest_tags_gate_independently(self):
        self.seed_release()
        self.repo.commit("c2")
        self.repo.tag("canary-20261004-0400")
        self.repo.commit("c3")
        self.repo.tag("v0.7.6")
        self.repo.commit("c4")
        self.assertEqual(canary_release.check(str(self.repo.path), False)["should_skip"], "false")
        self.repo.commit("c5")
        self.repo.tag("canary-20261005-0400")
        self.assertEqual(canary_release.check(str(self.repo.path), False)["should_skip"], "true")

    def test_annotated_release_tags_pick_newest_release_as_base(self):
        # Release tags are annotated, so committerdate is empty for them; the
        # base must fall back to the tagger date (creatordate), otherwise the
        # choice degrades to a lexicographic name comparison and picks
        # v0.7.9 over v0.7.10.
        self.repo.commit("c1")
        self.repo.annotated_tag("v0.7.9", date="2026-01-01T12:00:00")
        self.repo.commit("c2", date="2026-01-02T12:00:00")
        self.repo.annotated_tag("v0.7.10", date="2026-01-03T12:00:00")
        self.repo.commit("c3")
        text = canary_release.notes(str(self.repo.path))
        self.assertIn("Base tag: `v0.7.10`", text)

    def test_stable_release_after_canary_becomes_notes_base(self):
        self.seed_release()
        self.repo.commit("alpha", date="2026-01-02T12:00:00+00:00")
        self.repo.tag("canary-20261004-0400")
        self.repo.commit("release commit", date="2026-01-03T12:00:00+00:00")
        self.repo.annotated_tag("v0.7.6", date="2026-01-03T18:00:00+00:00")
        self.repo.commit("beta", date="2026-01-04T12:00:00+00:00")
        text = canary_release.notes(str(self.repo.path))
        # The canary tag predates the release that already covered "alpha",
        # so the notes must resume after v0.7.6 and repeat nothing.
        self.assertIn("Base tag: `v0.7.6`", text)
        self.assertIn("beta", text)
        self.assertNotIn(" alpha", text)

    def test_lightweight_tag_uses_commit_date_not_tag_creation_date(self):
        self.seed_release()
        self.repo.tag("canary-20261005-0400", date="2026-02-01T12:00:00+00:00")
        commit_date = int(self.repo.git("show", "-s", "--format=%ct", "HEAD"))
        self.assertEqual(
            canary_release.tags_with_create_dates(self.repo.path, canary_release.CANARY_GLOB),
            [(commit_date, "canary-20261005-0400")],
        )

    def test_canary_after_annotated_release_becomes_notes_base(self):
        self.repo.commit("released", date="2026-01-01T12:00:00+00:00")
        self.repo.annotated_tag("v0.7.5", date="2026-01-02T12:00:00+00:00")
        self.repo.commit("previous canary", date="2026-01-03T12:00:00+00:00")
        self.repo.tag("canary-20261004-0400")
        self.repo.commit("new feature", date="2026-01-04T12:00:00+00:00")
        text = canary_release.notes(self.repo.path)
        self.assertIn("Base tag: `canary-20261004-0400`", text)
        self.assertIn("new feature", text)
        self.assertNotIn("previous canary", text)
        self.assertNotIn("released", text)

    def test_diverged_tag_neither_skips_nor_becomes_notes_base(self):
        self.seed_release()
        self.repo.git("checkout", "-b", "other")
        self.repo.commit("other branch", date="2026-01-05T12:00:00+00:00")
        self.repo.annotated_tag("canary-20261005-0400", date="2026-01-06T12:00:00+00:00")
        self.repo.git("checkout", "main")
        self.repo.commit("main feature", date="2026-01-02T12:00:00+00:00")
        self.assertEqual(canary_release.check(self.repo.path, False)["should_skip"], "false")
        text = canary_release.notes(self.repo.path)
        self.assertIn("Base tag: `v0.7.5`", text)
        self.assertIn("main feature", text)
        self.assertNotIn("other branch", text)

    def test_head_before_released_commit_skips(self):
        self.seed_release()
        old_head = self.repo.git("rev-parse", "HEAD")
        self.repo.commit("already canaried", date="2026-01-02T12:00:00+00:00")
        self.repo.tag("canary-20261005-0400")
        self.repo.git("checkout", "--detach", old_head)
        result = canary_release.check(self.repo.path, False)
        self.assertEqual(result["should_skip"], "true")
        self.assertIn("canary-20261005-0400", result["skip_reason"])

    def test_notes_list_commits_since_previous_tag(self):
        self.seed_release()
        self.repo.commit("feature one")
        self.repo.commit("feature two")
        text = canary_release.notes(str(self.repo.path))
        self.assertIn("Base tag: `v0.7.5`", text)
        self.assertIn("### Changes since v0.7.5", text)
        self.assertIn("feature one", text)
        self.assertIn("feature two", text)
        self.assertNotIn("c1", text)

    def test_notes_without_any_tag_falls_back_to_recent_commits(self):
        self.repo.commit("first")
        text = canary_release.notes(str(self.repo.path))
        self.assertNotIn("Base tag", text)
        self.assertIn("Recent changes", text)
        self.assertIn("first", text)

    def test_non_commit_release_tag_fails_instead_of_looking_unreachable(self):
        self.seed_release()
        blob = self.repo.git("hash-object", "-w", str(SOURCE / "Scripts/canary_release.py"))
        self.repo.git("tag", "canary-invalid", blob)
        operations = (
            ("check", lambda: canary_release.check(self.repo.path, False)),
            ("notes", lambda: canary_release.notes(self.repo.path)),
        )
        for command, operation in operations:
            with self.subTest(command=command):
                with self.assertRaisesRegex(canary_release.CanaryError, "merge-base --is-ancestor .* failed"):
                    operation()

    def test_check_error_does_not_write_a_build_decision(self):
        self.seed_release()
        output = self.repo.path / "github-output.txt"
        blob = self.repo.git("hash-object", "-w", str(SOURCE / "Scripts/canary_release.py"))
        self.repo.git("tag", "canary-invalid", blob)
        result = subprocess.run(
            ["python3", str(SOURCE / "Scripts/canary_release.py"), "check",
             "--repo", str(self.repo.path), "--github-output", str(output)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("merge-base --is-ancestor", result.stderr)
        self.assertFalse(output.exists())

    def test_check_writes_github_output(self):
        self.seed_release()
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "github-output.txt"
            run(
                [
                    "python3",
                    str(SOURCE / "Scripts" / "canary_release.py"),
                    "check",
                    "--repo",
                    str(self.repo.path),
                    "--github-output",
                    str(output),
                ]
            )
            content = output.read_text()
        self.assertIn("should_skip=true", content)
        self.assertIn("skip_reason=HEAD ", content)


if __name__ == "__main__":
    unittest.main()

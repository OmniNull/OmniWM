from pathlib import Path
import os
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/restore-mtimes.py"


class RestoreMtimesTests(unittest.TestCase):
    def git(self, root, *arguments, at=None):
        env = dict(os.environ, GIT_AUTHOR_DATE=f"@{at} +0000", GIT_COMMITTER_DATE=f"@{at} +0000") if at else None
        command = ["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run(command + list(arguments), check=True, env=env)

    def commit(self, root, at, *files):
        for name in files:
            (root / name).write_text(f"{name} {at}\n")
        self.git(root, "add", *files)
        self.git(root, "commit", "-qm", str(at), at=at)

    def test_sources_take_the_time_of_the_last_commit_that_touched_them(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            self.commit(root, 1_000_000, "old.swift", "changed.swift")
            self.commit(root, 2_000_000, "changed.swift")
            subprocess.run([sys.executable, str(SCRIPT)], cwd=root, check=True)
            self.assertEqual(int((root / "old.swift").stat().st_mtime), 1_000_000)
            self.assertEqual(int((root / "changed.swift").stat().st_mtime), 2_000_000)

    def test_files_a_merge_brings_in_take_the_time_of_the_merge(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            started, branched, merged = 1_000_000, 2_000_000, 3_000_000
            subprocess.run(["git", "init", "-q", "-b", "main", str(root)], check=True)
            self.commit(root, started, "old.swift", "merged.swift")
            self.git(root, "switch", "-qc", "branch")
            self.commit(root, branched, "merged.swift")
            self.git(root, "switch", "-q", "main")
            self.git(root, "merge", "-q", "--no-ff", "-m", "merge", "branch", at=merged)
            subprocess.run([sys.executable, str(SCRIPT)], cwd=root, check=True)
            self.assertEqual(int((root / "old.swift").stat().st_mtime), started)
            self.assertEqual(int((root / "merged.swift").stat().st_mtime), merged)

    def test_files_changed_since_the_cached_build_are_newer_than_the_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cached, later = 1_000_000, 2_000_000
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            self.commit(root, cached, "old.swift", "changed.swift")
            cached_commit = subprocess.run(
                ["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True, check=True
            ).stdout.strip()
            self.commit(root, later, "changed.swift")
            started = time.time()
            subprocess.run([sys.executable, str(SCRIPT), f"swift-build-{cached_commit}"], cwd=root, check=True)
            self.assertEqual(int((root / "old.swift").stat().st_mtime), cached)
            self.assertGreaterEqual((root / "changed.swift").stat().st_mtime, started)

    def test_an_unknown_cached_build_rebuilds_every_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            self.commit(root, 1_000_000, "old.swift")
            started = time.time()
            subprocess.run([sys.executable, str(SCRIPT), "swift-build-unknown"], cwd=root, check=True)
            self.assertGreaterEqual((root / "old.swift").stat().st_mtime, started)


if __name__ == "__main__":
    unittest.main()

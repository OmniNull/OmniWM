from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/restore-mtimes.py"


class RestoreMtimesTests(unittest.TestCase):
    def commit(self, root, at, *files):
        for name in files:
            (root / name).write_text(f"{name} {at}\n")
        env = dict(os.environ, GIT_AUTHOR_DATE=f"@{at} +0000", GIT_COMMITTER_DATE=f"@{at} +0000")
        git = ["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run(git + ["add", *files], check=True)
        subprocess.run(git + ["commit", "-qm", str(at)], check=True, env=env)

    def test_sources_take_the_time_of_the_last_commit_that_touched_them(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            self.commit(root, 1_000_000, "old.swift", "changed.swift")
            self.commit(root, 2_000_000, "changed.swift")
            subprocess.run([sys.executable, str(SCRIPT)], cwd=root, check=True)
            self.assertEqual(int((root / "old.swift").stat().st_mtime), 1_000_000)
            self.assertEqual(int((root / "changed.swift").stat().st_mtime), 2_000_000)


if __name__ == "__main__":
    unittest.main()

from pathlib import Path
import json
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

    def build_package(self, root):
        targets = {
            "Core": ("regular", "Sources/Core", [], ["Generated"]),
            "App": ("regular", "Sources/App", ["Core"], []),
            "Other": ("regular", "Sources/Other", [], []),
            "AppTests": ("test", "Tests/AppTests", ["App"], []),
        }
        for _, folder, _, _ in targets.values():
            (root / folder).mkdir(parents=True)
        (root / "Sources/Core/Generated").mkdir()
        package = root.parent / "package.json"
        package.write_text(json.dumps({"targets": [
            {
                "name": name, "type": kind, "path": folder, "exclude": excluded,
                "dependencies": [{"byName": [needed, None]} for needed in needs],
            }
            for name, (kind, folder, needs, excluded) in targets.items()
        ]}))
        return package

    def date_after(self, change):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            cached, later = 1_000_000, 2_000_000
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            package = self.build_package(root)
            self.commit(
                root, cached, "Sources/Core/Layout.swift", "Sources/Core/Kept.swift", "Sources/Core/Strings.xcstrings",
                "Sources/Core/Generated/Table.swift", "Sources/App/Use.swift", "Sources/Other/Alone.swift",
                "Tests/AppTests/UseTests.swift",
            )
            cached_commit = subprocess.run(
                ["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True, check=True
            ).stdout.strip()
            change(root, later)
            started = time.time()
            subprocess.run(
                [sys.executable, str(SCRIPT), f"swift-build-{cached_commit}", str(package)], cwd=root, check=True
            )
            tracked = subprocess.run(
                ["git", "-C", str(root), "ls-files"], capture_output=True, text=True, check=True
            ).stdout.split()
            return {name: (root / name).stat().st_mtime for name in tracked}, started, cached

    def assert_dated(self, mtimes, started, cached, rebuilt, kept):
        for name in rebuilt:
            self.assertGreaterEqual(mtimes[name], started, name)
        for name in kept:
            self.assertEqual(int(mtimes[name]), cached, name)

    def test_targets_that_use_a_changed_target_rebuild_every_source(self):
        self.assert_dated(
            *self.date_after(lambda root, at: self.commit(root, at, "Sources/Core/Layout.swift")),
            rebuilt=["Sources/Core/Layout.swift", "Sources/App/Use.swift", "Tests/AppTests/UseTests.swift"],
            kept=["Sources/Core/Kept.swift", "Sources/Core/Strings.xcstrings", "Sources/Other/Alone.swift"],
        )

    def test_a_resource_change_rebuilds_no_other_target(self):
        self.assert_dated(
            *self.date_after(lambda root, at: self.commit(root, at, "Sources/Core/Strings.xcstrings")),
            rebuilt=["Sources/Core/Strings.xcstrings"],
            kept=["Sources/Core/Layout.swift", "Sources/App/Use.swift", "Tests/AppTests/UseTests.swift"],
        )

    def test_an_excluded_file_rebuilds_no_other_target(self):
        self.assert_dated(
            *self.date_after(lambda root, at: self.commit(root, at, "Sources/Core/Generated/Table.swift")),
            rebuilt=["Sources/Core/Generated/Table.swift"],
            kept=["Sources/Core/Layout.swift", "Sources/App/Use.swift", "Tests/AppTests/UseTests.swift"],
        )

    def test_a_file_moved_out_of_a_target_rebuilds_its_users(self):
        def move(root, at):
            self.git(root, "mv", "Sources/Core/Kept.swift", "Sources/Other/Kept.swift")
            self.git(root, "commit", "-qm", str(at), at=at)

        self.assert_dated(
            *self.date_after(move),
            rebuilt=["Sources/Other/Kept.swift", "Sources/App/Use.swift", "Tests/AppTests/UseTests.swift"],
            kept=["Sources/Core/Layout.swift", "Sources/Other/Alone.swift"],
        )

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

# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
STYLES = ROOT / "styles"
SCRIPT = ROOT / "Scripts/styles.py"


def files(folder):
    return {
        str(path.relative_to(folder)): (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mode & 0o777)
        for path in folder.rglob("*") if path.is_file()
    }


class StyleInstallTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="omniwm-styles-test-")
        self.addCleanup(temporary.cleanup)
        self.shell = Path(temporary.name) / "shell"
        self.names = sorted(path.name for path in STYLES.iterdir() if path.is_dir())
        self.assertTrue(self.names)

    def install(self, name):
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "install", name, "--to", str(self.shell)],
            capture_output=True, text=True, check=False,
        )

    def test_each_style_installs_unchanged_without_managed_files(self):
        for name in self.names:
            with self.subTest(style=name):
                source = STYLES / name
                result = self.install(name)
                self.assertEqual(result.returncode, 0, result.stderr)
                target = self.shell / name
                self.assertEqual(files(target), files(source))
                self.assertFalse((target / ".manifest.json").exists())

    def test_existing_style_is_never_overwritten(self):
        name = self.names[0]
        target = self.shell / name
        target.mkdir(parents=True)
        marker = target / "shell.toml"
        marker.write_text("local edits")
        before = files(target)
        result = self.install(name)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files(target), before)

    def test_unknown_style_does_not_create_the_destination(self):
        result = self.install("../default")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.shell.exists())


if __name__ == "__main__":
    unittest.main()

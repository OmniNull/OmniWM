import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class DevInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="omniwm-dev-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "Scripts"
        scripts.mkdir()
        source = Path(__file__).resolve().parents[2] / "Scripts" / "omniwm-dev.sh"
        self.script = scripts / source.name
        shutil.copy2(source, self.script)
        self.write_command(
            scripts / "package-app.sh",
            'mkdir -p "$OMNIWM_TEST_ROOT/dist/$OMNIWM_APP_NAME.app"\n'
            'printf built > "$OMNIWM_TEST_ROOT/dist/$OMNIWM_APP_NAME.app/new-build"\n',
        )
        tools = self.root / "tools"
        tools.mkdir()
        self.write_command(tools / "osascript", "printf '0\\n'\n")
        self.write_command(tools / "pgrep", "exit 1\n")
        self.write_command(tools / "sleep", "exit 0\n")
        self.write_command(tools / "open", 'touch "$OMNIWM_TEST_ROOT/opened"\n')
        self.config = self.root / "config"
        self.release_config = self.config / "omniwm"
        self.release_config.mkdir(parents=True)
        self.dev_config = self.config / "omniwm-dev"
        self.dev_app = self.root / "Applications" / "OmniWM Dev.app"
        self.environment = {
            **os.environ,
            "PATH": f"{tools}:{os.environ['PATH']}",
            "OMNIWM_TEST_ROOT": str(self.root),
            "OMNIWM_DEV_INSTALL_DIR": str(self.dev_app.parent),
            "OMNIWM_RELEASE_APP": str(self.root / "Release.app"),
            "XDG_CONFIG_HOME": str(self.config),
        }
        self.environment.pop("OMNIWM_DEV_APP_NAME", None)

    @staticmethod
    def write_command(path, body):
        path.write_text("#!/bin/bash\nset -eu\n" + body)
        path.chmod(0o755)

    def install(self):
        return subprocess.run(
            ["/bin/bash", str(self.script), "install"],
            env=self.environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_shutdown_timeout_preserves_installation_and_settings(self):
        self.dev_app.mkdir(parents=True)
        previous_build = self.dev_app / "previous-build"
        previous_build.write_text("installed")
        self.write_command(self.root / "tools" / "pgrep", "printf '123\\n'\n")

        result = self.install()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("still running", result.stderr)
        self.assertEqual(previous_build.read_text(), "installed")
        self.assertFalse(self.dev_config.exists())
        self.assertFalse((self.root / "opened").exists())

    def test_settings_are_copied_once_as_an_independent_file(self):
        original = self.root / "original-settings.luau"
        original.write_text("return { gaps = { size = 8 } }\n")
        (self.release_config / "settings.luau").symlink_to(original)

        result = self.install()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dev_app / "new-build").read_text(), "built")
        self.assertFalse((self.root / "dist" / self.dev_app.name).exists())
        dev_settings = self.dev_config / "settings.luau"
        self.assertFalse(dev_settings.is_symlink())
        self.assertEqual(dev_settings.read_text(), original.read_text())
        dev_settings.write_text("return { gaps = { size = 4 } }\n")
        previous_build = self.dev_app / "previous-build"
        previous_build.write_text("obsolete")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dev_app / "new-build").read_text(), "built")
        self.assertFalse((self.root / "dist" / self.dev_app.name).exists())
        self.assertFalse(previous_build.exists())
        self.assertEqual(dev_settings.read_text(), "return { gaps = { size = 4 } }\n")
        self.assertEqual(original.read_text(), "return { gaps = { size = 8 } }\n")

    def test_move_failure_stops_before_success_message_and_launch(self):
        self.write_command(self.root / "tools" / "mv", "exit 1\n")

        result = self.install()

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("omniwm-dev: installed", result.stdout)
        self.assertFalse((self.root / "opened").exists())
        self.assertEqual(
            (self.root / "dist" / self.dev_app.name / "new-build").read_text(), "built"
        )

    def test_only_old_release_settings_leaves_dev_to_use_defaults(self):
        (self.release_config / "settings.toml").write_text("[gaps]\nsize = 21\n")
        result = self.install()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.dev_config.is_dir())
        self.assertFalse((self.dev_config / "settings.luau").exists())
        self.assertTrue((self.root / "opened").exists())

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class MakeToolTests(unittest.TestCase):
    def test_dev_tools_runs_both_python_suites_and_propagates_failures(self):
        source = Path(__file__).resolve().parents[2]
        for failed_suite in (None, "DevToolingTests", "KittyControlTests"):
            with self.subTest(failed_suite=failed_suite), tempfile.TemporaryDirectory(prefix="omniwm make tests ") as temporary:
                root = Path(temporary)
                shutil.copy2(source / "Makefile", root / "Makefile")
                (root / "Scripts").mkdir()
                shutil.copy2(source / "Scripts/dev-tools.env", root / "Scripts/dev-tools.env")
                for suite in ("DevToolingTests", "KittyControlTests"):
                    tests = root / "Tests" / suite
                    tests.mkdir(parents=True)
                    (tests / "test_probe.py").write_text(
                        "import unittest\n\n"
                        "class ProbeTests(unittest.TestCase):\n"
                        "    def test_probe(self):\n"
                        f"        print('{suite} executed', flush=True)\n"
                        f"        self.assertNotEqual('{suite}', {failed_suite!r})\n"
                    )

                result = subprocess.run(["/usr/bin/make", "test-dev-tools"], cwd=root, text=True, capture_output=True, check=False)
                output = result.stdout + result.stderr
                self.assertIn("DevToolingTests executed", output)
                if failed_suite != "DevToolingTests":
                    self.assertIn("KittyControlTests executed", output)
                if failed_suite is None:
                    self.assertEqual(result.returncode, 0, output)
                else:
                    self.assertNotEqual(result.returncode, 0, output)

    def test_format_and_lint_use_pinned_tools_independently_of_inherited_path(self):
        source = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory(prefix="omniwm make tools ") as temporary:
            root = Path(temporary).resolve()
            shutil.copy2(source / "Makefile", root / "Makefile")
            (root / "Scripts").mkdir()
            shutil.copy2(source / "Scripts/dev-tools.env", root / "Scripts/dev-tools.env")
            versions = dict(
                line.split("=", 1)
                for line in (root / "Scripts/dev-tools.env").read_text().splitlines()
            )
            tools = root / ".cache/flake-tools/bin"
            tools.mkdir(parents=True)
            decoys = root / "system-tools"
            decoys.mkdir()
            for name in ("swiftformat", "swiftlint"):
                tool = tools / name
                tool.write_text(
                    "#!/bin/sh\n"
                    'case "$1" in\n'
                    f"  --version|version) printf '%s\\n' '{versions[name.upper() + '_VERSION']}' ;;\n"
                    f"  *) printf 'pinned {name}: %s\\n' \"$*\" ;;\n"
                    "esac\n"
                )
                tool.chmod(0o755)
                decoy = decoys / name
                decoy.write_text("#!/bin/sh\necho unexpected system tool >&2\nexit 99\n")
                decoy.chmod(0o755)

            for inherited_path in ("/usr/bin:/bin", f"{decoys}:/usr/bin:/bin"):
                with self.subTest(path=inherited_path):
                    result = subprocess.run(
                        ["/usr/bin/make", "format", "format-check", "lint", "lint-fix"],
                        cwd=root,
                        env={**os.environ, "PATH": inherited_path, "OMNIWM_DEV_TOOLS": ""},
                        text=True,
                        capture_output=True,
                        check=False,
                    )

                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    for invocation in (
                        "pinned swiftformat: .",
                        "pinned swiftformat: --lint .",
                        "pinned swiftlint: lint",
                        "pinned swiftlint: lint --fix",
                    ):
                        self.assertIn(invocation, result.stdout)

            shell_tools = root / "shell tools"
            tools.parent.rename(shell_tools)
            result = subprocess.run(
                ["/usr/bin/make", "format-check", "lint"],
                cwd=root,
                env={**os.environ, "PATH": "/usr/bin:/bin", "OMNIWM_DEV_TOOLS": str(shell_tools)},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("pinned swiftformat: --lint .", result.stdout)
            self.assertIn("pinned swiftlint: lint", result.stdout)

            shutil.copy2(source / "Scripts/doctor.sh", root / "Scripts")
            for name, body in (("uname", "echo fixture"), ("security", "exit 1")):
                command = decoys / name
                command.write_text(f"#!/bin/sh\n{body}\n")
                command.chmod(0o755)
            doctor = subprocess.run(
                ["/usr/bin/make", "doctor"], cwd=root, text=True, capture_output=True,
                env={**os.environ, "PATH": f"{decoys}:/usr/bin:/bin", "OMNIWM_DEV_TOOLS": shell_tools.name},
            )
            self.assertNotEqual(doctor.returncode, 0)
            self.assertIn("Building OmniWM requires macOS", doctor.stderr)
            for name in ("swiftformat", "swiftlint"):
                self.assertIn(f"{name}: {versions[name.upper() + '_VERSION']} ({shell_tools}/bin/{name})", doctor.stdout)

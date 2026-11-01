import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2]
CANARY_TAG = "canary-20261025-0415-100-2"


@unittest.skipUnless(sys.platform == "darwin", "App packaging uses macOS plist tools")
class PackageUpdateChannelTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="omniwm-package-channel-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "Scripts"
        scripts.mkdir()
        shutil.copy2(SOURCE / "Scripts/package-app.sh", scripts / "package-app.sh")
        self.command(scripts / "ghostty-preflight.sh", 'printf "%s\\n" "$OMNIWM_TEST_ROOT/lib"\n')
        (scripts / "localization.py").write_text("raise SystemExit(0)\n")
        tools = self.root / "tools"
        tools.mkdir()
        for name in ("make", "spctl", "syspolicy_check", "xcrun"):
            self.command(tools / name, "exit 0\n")
        self.command(tools / "lipo", 'if [[ "${2##*/}" == "${OMNIWM_TEST_WRONG_BINARY:-}" ]]; then\n'
                     '  echo arm64\nelse\n  echo "$OMNIWM_ARCH"\nfi\n')
        self.command(tools / "swift", 'printf "%s\\n" "$@" >> "$OMNIWM_TEST_ROOT/swift-args"\n'
                     'for arg in "$@"; do\n'
                     '  if [[ "$arg" == --show-bin-path ]]; then printf "%s\\n" "$OMNIWM_TEST_ROOT/build"; fi\n'
                     'done\n')
        self.command(tools / "ditto", 'for output in "$@"; do :; done\ntouch "$output"\n')
        self.command(tools / "codesign", 'if [[ -n "${OMNIWM_CANARY_TAG:-}" ]]; then\n'
                     '  plutil -extract OMNIWMCanaryTag raw "$OMNIWM_TEST_ROOT/dist/OmniWM.app/Contents/Info.plist" '
                     '>> "$OMNIWM_TEST_ROOT/signed-tags"\nfi\n')
        build = self.root / "build"
        build.mkdir()
        for name in ("OmniWM", "omniwmctl", "libOmniWMNowPlaying.dylib"):
            (build / name).touch()
        (build / "OmniWM_OmniWM.bundle").mkdir()
        resources = self.root / "Resources"
        (resources / "Licenses").mkdir(parents=True)
        (resources / "Licenses/Test.txt").touch()
        (resources / "AppIcon.icns").touch()
        luau = self.root / "Sources/OmniWMLuau"
        luau.mkdir(parents=True)
        for name in ("LICENSE.txt", "lua_LICENSE.txt"):
            (luau / name).touch()
        with (self.root / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleShortVersionString": "0.7.6", "CFBundleVersion": "88"}, handle)
        self.environment = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "OMNIWM_TEST_ROOT": str(self.root)}
        for key in ("OMNIWM_CANARY_TAG", "OMNIWM_APP_NAME", "OMNIWM_BUNDLE_ID", "OMNIWM_ARCH"):
            self.environment.pop(key, None)

    @staticmethod
    def command(path, source):
        path.write_text("#!/bin/bash\nset -eu\n" + source)
        path.chmod(0o755)

    def package(self, tag=None, **extra):
        environment = {**self.environment, **extra}
        if tag is not None:
            environment["OMNIWM_CANARY_TAG"] = tag
        return subprocess.run(
            ["bash", str(self.root / "Scripts/package-app.sh"), "release", "true"],
            cwd=self.root, env=environment, text=True, capture_output=True,
        )

    def packaged_info(self):
        with (self.root / "dist/OmniWM.app/Contents/Info.plist").open("rb") as handle:
            return plistlib.load(handle)

    def test_canary_identity_is_embedded_before_signing_without_changing_stable_version(self):
        result = self.package(CANARY_TAG)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.packaged_info()["OMNIWMCanaryTag"], CANARY_TAG)
        self.assertEqual(self.packaged_info()["CFBundleShortVersionString"], "0.7.6")
        self.assertEqual(set((self.root / "signed-tags").read_text().splitlines()), {CANARY_TAG})

    def test_stable_package_has_no_canary_identity(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("OMNIWMCanaryTag", self.packaged_info())

    def test_invalid_canary_identity_stops_before_building(self):
        result = self.package("v0.7.6")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid Canary release tag", result.stderr)
        self.assertFalse((self.root / "dist").exists())

    def test_intel_package_builds_and_checks_x86_64(self):
        result = self.package(OMNIWM_ARCH="x86_64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Building OmniWM x86_64 binary", result.stdout)
        swiftArgs = (self.root / "swift-args").read_text().splitlines()
        self.assertEqual(swiftArgs.count("--arch"), 2)
        for index, argument in enumerate(swiftArgs):
            if argument == "--arch":
                self.assertEqual(swiftArgs[index + 1], "x86_64")

    def test_wrong_binary_architecture_or_unknown_arch_is_rejected(self):
        for binary in ("OmniWM", "omniwmctl", "libOmniWMNowPlaying.dylib"):
            with self.subTest(binary=binary):
                result = self.package(OMNIWM_ARCH="x86_64", OMNIWM_TEST_WRONG_BINARY=binary)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"/{binary} is not x86_64-only", result.stderr)
        result = self.package(OMNIWM_ARCH="i386")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("OMNIWM_ARCH must be arm64 or x86_64", result.stderr)
        self.assertFalse((self.root / "dist").exists())


if __name__ == "__main__":
    unittest.main()

import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ghostty_build", ROOT / "Scripts/build-ghosttykit.py")
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class GhosttyBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="omniwm-ghostty-build-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_source_requires_an_identified_released_compiler(self):
        metadata = self.root / "build.zig.zon"
        metadata.write_text('.version = "1.4.0-dev",\n.minimum_zig_version = "0.17.0",\n')
        self.assertEqual(BUILDER.source_versions(self.root), ("1.4.0", "0.17.0"))
        metadata.write_text('.version = "1.4.0-dev",\n.minimum_zig_version = "0.18.0-dev.1+abc",\n')
        with self.assertRaisesRegex(RuntimeError, "released Zig version"):
            BUILDER.source_versions(self.root)

    def test_unavailable_or_untrusted_compiler_distribution_is_rejected(self):
        for release in ({}, {"tarball": "https://example.com/zig.tar.xz", "shasum": "0" * 64}):
            with self.subTest(release=release):
                response = io.BytesIO(json.dumps({"0.16.0": {"aarch64-macos": release}}).encode())
                with patch.object(BUILDER.urllib.request, "urlopen", return_value=response):
                    with self.assertRaisesRegex(RuntimeError, "distribution is unavailable"):
                        BUILDER.zig_distribution("0.16.0")

    def test_corrupt_cached_compiler_is_rejected_before_extraction(self):
        pin = {"url": "https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz", "sha256": "0" * 64}
        archive = self.root / pin["url"].rsplit("/", 1)[1]
        archive.write_bytes(b"corrupted compiler")
        with patch.object(BUILDER, "run") as command:
            with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
                BUILDER.install_zig(pin, self.root, self.root)
        command.assert_not_called()

    def test_modified_source_or_wrong_revision_cannot_claim_clean_provenance(self):
        def git(*args):
            return subprocess.check_output(["git", *args], cwd=self.root, text=True).strip()

        git("init", "--quiet")
        source = self.root / "source.zig"
        source.write_text("original\n")
        git("add", "source.zig")
        git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "Fixture")
        revision = git("rev-parse", "HEAD")
        BUILDER.verify_source(self.root, revision)
        with self.assertRaisesRegex(RuntimeError, "revision mismatch"):
            BUILDER.verify_source(self.root, "0" * 40)
        source.write_text("modified\n")
        with self.assertRaisesRegex(RuntimeError, "dirty"):
            BUILDER.verify_source(self.root, revision)

    def test_framework_headers_must_match_source_and_zip_has_installer_layout(self):
        framework = self.root / "candidate"
        include = self.root / "include"
        include.mkdir()
        (framework / BUILDER.HEADERS).mkdir(parents=True)
        (framework / BUILDER.LIBRARY).write_bytes(b"archive")
        for name in ("ghostty.h", "module.modulemap"):
            (include / name).write_text(name)
            (framework / BUILDER.HEADERS / name).write_text(name)
        (framework / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": [{
            "LibraryIdentifier": "macos-arm64",
            "LibraryPath": "libghostty-internal.a",
            "HeadersPath": "Headers",
            "SupportedArchitectures": ["arm64"],
            "SupportedPlatform": "macos",
        }]}))
        with patch.object(BUILDER, "run", return_value="arm64"):
            hashes = BUILDER.verify_framework(framework, self.root)
            archive = self.root / "candidate.zip"
            digest = BUILDER.package_framework(framework, archive, hashes)
            self.assertEqual(digest, BUILDER.sha256(archive))
            with zipfile.ZipFile(archive) as package:
                self.assertEqual(set(package.namelist()), {str(BUILDER.FRAMEWORK / path) for path in hashes})
                for path, expected in hashes.items():
                    self.assertEqual(BUILDER.hashlib.sha256(package.read(str(BUILDER.FRAMEWORK / path))).hexdigest(), expected)
            (framework / BUILDER.HEADERS / "ghostty.h").write_text("stale header")
            with self.assertRaisesRegex(RuntimeError, "header differs"):
                BUILDER.verify_framework(framework, self.root)
            with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
                BUILDER.package_framework(framework, self.root / "stale.zip", hashes)


if __name__ == "__main__":
    unittest.main()

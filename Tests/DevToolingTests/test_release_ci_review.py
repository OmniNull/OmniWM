import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "release_ci_review", Path(__file__).resolve().parents[2] / "Scripts/release-ci-review.py"
)
review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(review)


class ReleaseCIReviewTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.manifest = {
            "version": "0.7.5",
            "state": "prepared",
            "original_main_head": "a" * 40,
            "release_commit": "b" * 40,
            "assets": {},
        }
        for name, filename in (("app", "OmniWM-v0.7.5.zip"), ("ghostty", "GhosttyKit.xcframework-v0.7.5.zip")):
            (self.root / filename).write_bytes(name.encode())
            self.manifest["assets"][name] = {"sha256": hashlib.sha256(name.encode()).hexdigest()}
        (self.root / "release-v0.7.5.json").write_text(json.dumps(self.manifest))
        (self.root / "ghostty-provenance-v0.7.5.json").write_text(json.dumps({
            "zip_sha256": self.manifest["assets"]["ghostty"]["sha256"],
            "source_revision": "c" * 40,
            "zig_version": "0.16.0",
        }))

    def summarize(self, source="a" * 40):
        return review.review_summary(self.root, "0.7.5", source, "Reviewed notes\nSecond line", 123, "https://github.com/run/1")

    def test_review_identifies_exact_commit_artifact_assets_and_notes(self):
        summary = self.summarize()
        self.assertIn("Artifact ID: `123`", summary)
        self.assertIn("b" * 40, summary)
        self.assertIn("c" * 40, summary)
        self.assertIn("0.16.0", summary)
        self.assertIn(self.manifest["assets"]["app"]["sha256"], summary)
        self.assertIn(self.manifest["assets"]["ghostty"]["sha256"], summary)
        self.assertIn("Reviewed notes\nSecond line", summary)
        self.assertIn(hashlib.sha256(b"Reviewed notes\nSecond line").hexdigest(), summary)

    def test_changed_asset_cannot_be_presented_for_approval(self):
        (self.root / "OmniWM-v0.7.5.zip").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "app asset hash mismatch"):
            self.summarize()

    def test_wrong_prepare_source_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "source does not match"):
            self.summarize("c" * 40)

    def test_artifact_must_come_from_successful_main_release_run(self):
        run = {
            "path": ".github/workflows/release.yml", "event": "workflow_dispatch",
            "head_branch": "main", "status": "completed", "conclusion": "success",
            "repository": {"full_name": "OmniNull/OmniWM"},
        }
        artifact = {"id": 123, "expired": False}
        with patch.object(review, "api", side_effect=[run, {"artifacts": [artifact]}]):
            self.assertEqual(review.prepared_artifact("OmniNull/OmniWM", "1", "0.7.5"), (run, artifact))
        for key, value in (("head_branch", "unreviewed"), ("conclusion", "failure"), ("path", ".github/workflows/other.yml")):
            with self.subTest(key=key), patch.object(review, "api", return_value={**run, key: value}):
                with self.assertRaisesRegex(ValueError, "successful release workflow"):
                    review.prepared_artifact("OmniNull/OmniWM", "1", "0.7.5")
        for artifacts in ([], [artifact, artifact], [{**artifact, "expired": True}]):
            with self.subTest(artifacts=artifacts), patch.object(review, "api", side_effect=[run, {"artifacts": artifacts}]):
                with self.assertRaisesRegex(ValueError, "one unexpired"):
                    review.prepared_artifact("OmniNull/OmniWM", "1", "0.7.5")

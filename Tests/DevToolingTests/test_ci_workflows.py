import os
from pathlib import Path
import re
import subprocess
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"


class CIWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.ci = (WORKFLOWS / "ci.yml").read_text()
        self.website = (WORKFLOWS / "website.yml").read_text()
        self.jobs = dict(re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:|\Z)",
                                    self.ci.split("\njobs:\n", 1)[1], re.MULTILINE | re.DOTALL))

    def test_automatic_pr_and_release_push_triggers(self):
        triggers = self.ci.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        ignored = "paths-ignore: ['docs/**', 'website/**', '*.md']"
        self.assertIn(f"  pull_request:\n    {ignored}\n", triggers)
        self.assertIn(f"  push:\n    branches: [main, '**-release']\n    {ignored}\n", triggers)
        self.assertIn("  workflow_dispatch:\n    inputs:\n      pr_number:\n", triggers)
        self.assertIn("        required: false\n        type: string\n", triggers)
        self.assertNotIn("head_sha:", triggers)
        self.assertNotIn("merge_sha:", triggers)

    def test_no_approval_coupling(self):
        for filename in ("approval.yml", "approval-events.yml", "approval-signal.yml",
                         "approved-ci.yml", "approved-website.yml"):
            self.assertFalse((WORKFLOWS / filename).exists(), filename)
        self.assertFalse((ROOT / "Scripts/ci-approval.py").exists())
        for workflow in (self.ci, self.website):
            self.assertNotIn("approval", workflow)
            self.assertNotIn("pull_request_target", workflow)
            self.assertNotIn("secrets:", workflow)
            self.assertIn("permissions:\n  contents: read\n", workflow)
        self.assertNotIn("website", self.jobs)

    def test_manual_pr_number_is_validated_before_checkout(self):
        ref = "ref: ${{ inputs.pr_number != '' && format('refs/pull/{0}/merge', inputs.pr_number) || github.ref }}"
        jobs = {name: job for name, job in self.jobs.items() if "refs/pull/" in job}
        self.assertEqual(set(jobs), {"tooling", "verify", "test-group"})
        for name, job in jobs.items():
            with self.subTest(job=name):
                self.assertIn(ref, job)
                before_checkout = job.split("      - uses: actions/checkout@", 1)[0]
                self.assertIn("PR_NUMBER: ${{ inputs.pr_number }}", before_checkout)
                script = textwrap.dedent(before_checkout.split("        run: |\n", 1)[1])
                for number in ("", "1", "1254", "0", "-1", "01", "1/../head", "1\n2", "$(exit 0)"):
                    with self.subTest(number=number):
                        result = subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True,
                                                env={**os.environ, "PR_NUMBER": number})
                        valid = number in ("", "1", "1254")
                        self.assertEqual(result.returncode == 0, valid, result.stdout + result.stderr)
                        if not valid:
                            self.assertIn("pr_number must be a positive integer", result.stdout)

    def test_planner_uses_event_base_and_head(self):
        changes = self.jobs["changes"]
        self.assertIn("ref: ${{ github.ref }}", changes)
        self.assertIn("fetch-depth: ${{ github.event_name == 'pull_request' && '0' || '1' }}", changes)
        for name, value in (("EVENT", "github.event_name"), ("BASE", "github.event.pull_request.base.sha"),
                            ("HEAD", "github.event.pull_request.head.sha")):
            self.assertIn(f"{name}: ${{{{ {value} }}}}", changes)
        self.assertNotIn("inputs.pr_number", changes)
        self.assertIn('if [[ "$EVENT" == pull_request ]]; then\n            git diff --name-only "$BASE...$HEAD"', changes)
        self.assertIn('python3 Scripts/ci_test_plan.py "$EVENT" >> "$GITHUB_OUTPUT"', changes)

    def test_cache_writes_are_main_push_only(self):
        self.assertIn("\ncache-mode: read\n", self.ci)
        writers = {name for name, job in self.jobs.items()
                   if any(value in job for value in ("cache-mode: write", "actions/cache/save@", "save-release-downloads: true"))}
        self.assertEqual(writers, {"cache-dependencies"})
        cache = self.jobs["cache-dependencies"]
        condition = re.findall(r"^    if: (.+)$", cache, re.MULTILINE)[0]
        self.assertEqual(condition, "github.event_name == 'push' && github.ref == 'refs/heads/main'")
        self.assertIn("    cache-mode: write\n", cache)
        self.assertIn("save-release-downloads: true", cache)
        self.assertNotIn("inputs.pr_number", cache)

    def test_tests_gate_and_runtime_pipeline_remain(self):
        self.assertIn("    name: Tests\n    needs: [changes, verify, test-group]\n    if: ${{ !cancelled() }}", self.jobs["tests"])
        self.assertIn('[[ "$CHANGES" == success && "$VERIFY" == success && "$TEST_GROUPS" == success ]]', self.jobs["tests"])
        self.assertIn('[[ "$CHANGES" == success && "$TEST_GROUPS" == skipped ]]', self.jobs["tests"])
        self.assertIn("matrix: ${{ fromJSON(needs.changes.outputs.matrix) }}", self.jobs["test-group"])
        for value in ("./.github/actions/setup-swift", "./.github/actions/setup-lix", "Archive the test runtime",
                      "actions/upload-artifact@", "Compile the live checks", "OMNIWM_LIVE_CHECKS=1"):
            self.assertIn(value, self.jobs["verify"])
        for value in ("./.github/actions/setup-audio", "./.github/actions/setup-swift", "./.github/actions/setup-lix",
                      "actions/download-artifact@", "Restore the test runtime", "swift test --skip-build"):
            self.assertIn(value, self.jobs["test-group"])

    def test_website_pr_and_push_paths(self):
        triggers = self.website.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        for event in ("push", "pull_request"):
            block = re.findall(rf"^  {event}:\n(.*?)(?=^  \w+:|\Z)", triggers, re.MULTILINE | re.DOTALL)[0]
            for path in ("website/**", "Sources/OmniWM/Resources/omniwm.d.luau", ".do/app.yaml", ".github/workflows/website.yml"):
                self.assertIn(f"      - {path}\n", block)
        for command in ("npm ci", "npm run reference:check", "npm run check", "npm run build"):
            self.assertIn(f"      - run: {command}", self.website)


if __name__ == "__main__":
    unittest.main()

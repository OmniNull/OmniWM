import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
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

    def test_every_checkout_uses_the_resolved_immutable_sha(self):
        refs = {"cache-dependencies": "github.sha", "changes": "steps.source.outputs.sha",
                **dict.fromkeys(("tooling", "verify", "test-group"), "needs.changes.outputs.source-sha")}
        self.assertEqual(set(self.jobs), {*refs, "tests"})
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                checkouts = re.findall(r"      - uses: actions/checkout@[^\n]+\n(.*?)(?=      - |\Z)",
                                       job, re.DOTALL)
                self.assertEqual(len(checkouts), int(name in refs))
                for checkout in checkouts:
                    self.assertEqual(re.findall(r"^          ref: (.+)$", checkout, re.MULTILINE),
                                     [f"${{{{ {refs[name]} }}}}"])
                    self.assertIn("persist-credentials: false", checkout)
                if name in ("tooling", "verify", "test-group"):
                    self.assertRegex(job, r"(?m)^    needs: (changes|\[changes, verify\])$")
                if name != "changes":
                    self.assertNotIn("inputs.pr_number", job)
                    self.assertNotRegex(job, r"\b(?:gh|git)\s+(?:api|ls-remote|fetch)\b")
        self.assertIn("      source-sha: ${{ steps.source.outputs.sha }}", self.jobs["changes"])
        self.assertEqual(self.ci.count("gh api "), 1)
        self.assertIn("    permissions:\n      contents: read\n      pull-requests: read", self.jobs["changes"])
        self.assertEqual(self.ci.count("pull-requests: read"), 1)
        self.assertNotRegex(self.ci, r"(?:contents|actions|checks|pull-requests): write")

    def test_source_resolver_pins_open_mergeable_prs_and_fails_closed(self):
        before_checkout = self.jobs["changes"].split("      - uses: actions/checkout@", 1)[0]
        for value in ("id: source", "PR_NUMBER: ${{ inputs.pr_number }}", "EVENT_SHA: ${{ github.sha }}",
                      "GH_TOKEN: ${{ github.token }}", "GH_REPO: ${{ github.repository }}", "shell: bash"):
            self.assertIn(value, before_checkout)
        script = textwrap.dedent(before_checkout.split("        run: |\n", 1)[1])
        event_sha, merge_sha = "a" * 40, "b" * 40
        ready = {"state": "open", "mergeable": True, "merge_commit_sha": merge_sha}
        closed = {**ready, "state": "closed"}
        merged = {**closed, "merged": True, "mergeable": None}
        pending = {**ready, "mergeable": None}
        cases = [
            ("push", "", [], 0, event_sha, ""),
            ("pull_request", "", [], 0, event_sha, ""),
            ("workflow_dispatch", "", [], 0, event_sha, ""),
            ("workflow_dispatch", "1", [ready], 0, merge_sha, ""),
            ("workflow_dispatch", "1254", [ready], 0, merge_sha, ""),
            ("workflow_dispatch", "1254", [closed], 0, None, "must be open"),
            ("workflow_dispatch", "1254", [merged], 0, None, "must be open"),
            ("workflow_dispatch", "1254", [{**ready, "mergeable": False}], 0, None, "cannot be merged"),
            ("workflow_dispatch", "1254", [pending, ready], 0, merge_sha, ""),
            ("workflow_dispatch", "1254", [{**pending, "merge_commit_sha": None}, ready], 0, merge_sha, ""),
            ("workflow_dispatch", "1254", [pending, closed], 0, None, "must be open"),
            ("workflow_dispatch", "1254", [pending] * 5, 0, None, "still computing mergeability"),
            ("workflow_dispatch", "1254", [ready], 1, None, "Could not resolve"),
        ]
        cases += [("workflow_dispatch", number, [], 0, None, "pr_number must be a positive integer")
                  for number in ("0", "-1", "01", "1/../head", "1\n2", "$(exit 0)", " 1")]
        cases += [("workflow_dispatch", "1254", [{**ready, "merge_commit_sha": sha}], 0, None,
                   "Source commit must be a full 40-character")
                  for sha in ("", None, "null", "b" * 39, "b" * 41, "g" * 40,
                              merge_sha + r"\n" + event_sha, merge_sha + "\n" + event_sha)]
        for event, number, answers, status, expected, error in cases:
            with self.subTest(event=event, number=number, answers=answers, status=status), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                calls, output = directory / "calls", directory / "output"
                stub = textwrap.dedent('''\
                    #!/bin/bash
                    echo "${0##*/} $*" >> "$CALLS"
                    answer=$(sed -n "$(wc -l < "$CALLS" | tr -d ' ')p" <<< "$ANSWERS")
                    if [[ "$QUERY_STATUS" != 0 ]]; then exit "$QUERY_STATUS"; fi
                    jq -r "$4" <<< "$answer"
                    ''')
                for command in ("gh", "git"):
                    (directory / command).write_text(stub)
                    (directory / command).chmod(0o755)
                (directory / "sleep").write_text("#!/bin/bash\nexit 0\n")
                (directory / "sleep").chmod(0o755)
                result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                                        capture_output=True, text=True, env={**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}",
                                        "PR_NUMBER": number, "EVENT_SHA": event_sha, "GITHUB_EVENT_NAME": event,
                                        "GH_REPO": "OmniNull/OmniWM", "GH_TOKEN": "fixture", "GITHUB_OUTPUT": str(output),
                                        "CALLS": str(calls), "ANSWERS": "\n".join(map(json.dumps, answers)),
                                        "QUERY_STATUS": str(status)})
                self.assertEqual(result.returncode == 0, expected is not None, result.stdout + result.stderr)
                self.assertEqual(output.read_text() if output.exists() else "", f"sha={expected}\n" if expected else "")
                requests = calls.read_text().splitlines() if calls.exists() else []
                self.assertEqual(len(requests), len(answers))
                for request in requests:
                    self.assertTrue(request.startswith(f"gh api repos/OmniNull/OmniWM/pulls/{number} --jq "), request)
                if error:
                    self.assertIn(error, result.stdout)

    def test_planner_uses_event_base_and_head(self):
        changes = self.jobs["changes"]
        plan = changes.split("      - name: Plan the Swift test groups\n", 1)[1]
        self.assertIn("fetch-depth: ${{ github.event_name == 'pull_request' && '0' || '1' }}", changes)
        for name, value in (("EVENT", "github.event_name"), ("BASE", "github.event.pull_request.base.sha"),
                            ("HEAD", "github.event.pull_request.head.sha")):
            self.assertIn(f"{name}: ${{{{ {value} }}}}", changes)
        self.assertNotIn("inputs.pr_number", plan)
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

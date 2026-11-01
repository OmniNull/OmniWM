import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[2]


def job(workflow, name):
    text = (ROOT / ".github/workflows" / workflow).read_text()
    return re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  [\w-]+:|\Z)", text, re.MULTILINE | re.DOTALL)[1]


class CIWorkflowTests(unittest.TestCase):
    def plan(self, event, changed="", status=0):
        step = job("ci.yml", "changes").split("      - name: Plan the Swift test groups\n", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        shell = ["bash", "--noprofile", "--norc", "-eo", "pipefail"] if "        shell: bash\n" in step else ["bash", "-e"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_git = root / "git"
            fake_git.write_text('#!/bin/sh\nprintf "%s" "$CHANGED"\nexit "$DIFF_STATUS"\n')
            fake_git.chmod(0o755)
            output = root / "output"
            result = subprocess.run([*shell, "-c", script], cwd=ROOT, capture_output=True, text=True, env={
                **os.environ,
                "PATH": f"{root}{os.pathsep}{os.environ['PATH']}",
                "EVENT": event,
                "BASE": "base",
                "HEAD": "head",
                "CHANGED": changed,
                "DIFF_STATUS": str(status),
                "GITHUB_OUTPUT": str(output),
            })
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        return result, values

    def test_failed_diff_cannot_skip_tests_successfully(self):
        result, _ = self.plan("pull_request", status=128)
        self.assertNotEqual(result.returncode, 0, "A failed diff must fail Changes, not silently skip Swift tests")

    def test_successful_diff_keeps_app_and_tooling_test_plans(self):
        for changed, expected in (("Sources/OmniWM/App.swift\n", "true"), ("Scripts/localization.py\n", "false"), ("", "false")):
            with self.subTest(changed=changed):
                result, values = self.plan("pull_request", changed)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(values["tests"], expected)
                self.assertTrue(json.loads(values["matrix"])["include"])

    def test_push_diff_failures_block_ci_and_manual_runs_need_no_diff(self):
        result, _ = self.plan("push", status=128)
        self.assertNotEqual(result.returncode, 0)
        result, values = self.plan("workflow_dispatch", status=128)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["tests"], "true")

    def test_docs_only_commits_skip_expensive_jobs_on_prs_and_pushes(self):
        for event in ("pull_request", "push"):
            with self.subTest(event=event):
                result, values = self.plan(event, "README.md\ndocs/config.md\nwebsite/src/content/docs/a.mdx\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                for key in ("ci", "verify", "tests"):
                    self.assertEqual(values[key], "false")
                result, values = self.plan(event, "README.md\nSources/OmniWM/App.swift\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(values["tests"], "true")

    def test_only_pr_runs_share_a_cancelling_concurrency_group(self):
        for workflow in ("ci.yml", "website.yml"):
            text = (ROOT / ".github/workflows" / workflow).read_text()
            group = re.search(r"^  group: \$\{\{ (.+) \}\}$", text, re.MULTILINE)[1]
            # The leading workflow expression is outside the second expression.
            group = group.split(" }}-${{ ", 1)[-1]
            cancel = re.search(r"^  cancel-in-progress: \$\{\{ (.+) \}\}$", text, re.MULTILINE)[1]
            evaluate = lambda expression, context: eval(
                expression.replace("&&", " and ").replace("||", " or "),
                {"__builtins__": {}, "format": str.format}, context,
            )
            for event, pr, expected_cancel in (("pull_request", 42, True), ("push", 0, False)):
                groups = []
                for run_id in (100, 101):
                    context = {"inputs": SimpleNamespace(pr_number=""), "github": SimpleNamespace(
                        event_name=event, run_id=run_id, event=SimpleNamespace(pull_request=SimpleNamespace(number=pr)),
                    )}
                    groups.append(evaluate(group, context))
                    self.assertEqual(evaluate(cancel, context), expected_cancel)
                self.assertEqual(groups[0] == groups[1], expected_cancel)

    def test_tests_gate_distinguishes_skipped_docs_from_failed_dependencies(self):
        gate = job("ci.yml", "tests")
        script = textwrap.dedent(gate.split("        run: |\n", 1)[1])
        for changes, required, verify, groups, expected in (
            ("success", "false", "skipped", "skipped", 0),
            ("success", "true", "success", "success", 0),
            ("success", "true", "failure", "skipped", 1),
            ("success", "true", "success", "failure", 1),
            ("success", "true", "success", "skipped", 1),
            ("failure", "false", "skipped", "skipped", 1),
        ):
            with self.subTest(changes=changes, required=required, verify=verify, groups=groups):
                result = subprocess.run(["bash", "-e", "-c", script], capture_output=True, env={
                    **os.environ, "CHANGES": changes, "REQUIRED": required,
                    "VERIFY": verify, "TEST_GROUPS": groups,
                })
                self.assertEqual(result.returncode, expected)

    def test_checkouts_keep_the_event_commit_when_refs_move(self):
        event_sha = "a" * 40
        for name in ("changes", "checks", "tooling-macos", "verify", "test-group"):
            ref = re.search(r"^          ref: \$\{\{ (.+) \}\}$", job("ci.yml", name), re.MULTILINE)[1]
            expression = ref.replace("&&", " and ").replace("||", " or ")
            for event_ref, pr, expected in (
                ("refs/heads/main", "", event_sha),
                ("refs/pull/42/merge", "", event_sha),
                ("refs/heads/manual-ci", "", event_sha),
                ("refs/heads/manual-ci", "42", "refs/pull/42/merge"),
            ):
                with self.subTest(job=name, event_ref=event_ref, pr=pr):
                    selected = eval(expression, {"__builtins__": {}, "format": str.format}, {
                        "inputs": SimpleNamespace(pr_number=pr),
                        "github": SimpleNamespace(sha=event_sha, ref=event_ref),
                    })
                    self.assertEqual(selected, expected)

    def test_website_test_failure_stops_the_build(self):
        commands = re.findall(r"^      - run: (.+)$", job("website.yml", "check"), re.MULTILINE)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_npm = root / "npm"
            fake_npm.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$NPM_CALLS"\n[ "$*" != test ] || exit 42\n')
            fake_npm.chmod(0o755)
            calls = root / "calls"
            for command in commands:
                result = subprocess.run(["bash", "-e", "-c", command], cwd=root, capture_output=True, text=True, env={
                    **os.environ,
                    "PATH": f"{root}{os.pathsep}{os.environ['PATH']}",
                    "NPM_CALLS": str(calls),
                })
                if result.returncode:
                    break
            self.assertEqual(result.returncode, 42, "Website must execute npm test and propagate its failure")
            self.assertNotIn("run build", calls.read_text().splitlines())


if __name__ == "__main__":
    unittest.main()

import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_ci_policy", SOURCE / "Scripts/release-ci-policy.py")
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class ReleaseCIPolicyTests(unittest.TestCase):
    def setUp(self):
        self.repository = "OmniNull/OmniWM"
        self.environment = {
            "can_admins_bypass": False,
            "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True},
            "protection_rules": [{
                "type": "required_reviewers",
                "prevent_self_review": False,
                "reviewers": [{"type": "User", "reviewer": {"login": "BarutSRB", "id": 12249659}}],
            }],
        }
        self.responses = {}
        for name in POLICY.ENVIRONMENTS:
            path = f"repos/{self.repository}/environments/{name}"
            self.responses[path] = copy.deepcopy(self.environment)
            self.responses[f"{path}/deployment-branch-policies?per_page=100"] = {
                "total_count": 1,
                "branch_policies": [{"id": 1, "name": "main", "type": "branch"}],
            }
        self.rules_path = f"repos/{self.repository}/rules/branches/main?per_page=100"
        self.responses[self.rules_path] = [[{"type": "deletion"}, {"type": "non_fast_forward"}]]
        self.api = patch.object(POLICY, "github_api", side_effect=self.response).start()
        self.addCleanup(patch.stopall)

    def response(self, path, paginate=False):
        value = self.responses[path]
        if isinstance(value, Exception):
            raise value
        return value

    def environment_at(self, name="release-signing"):
        return self.responses[f"repos/{self.repository}/environments/{name}"]

    def branch_policies_at(self, name="release-signing"):
        return self.responses[f"repos/{self.repository}/environments/{name}/deployment-branch-policies?per_page=100"]

    def test_valid_policy_checks_both_environments_and_all_rule_pages(self):
        POLICY.validate_policy(self.repository)

        self.assertEqual(self.api.call_count, 5)
        self.api.assert_any_call(self.rules_path, paginate=True)

    def test_missing_environment_fails_closed(self):
        self.responses[f"repos/{self.repository}/environments/release-publish"] = POLICY.PolicyError("HTTP 404: release-publish missing")

        with self.assertRaisesRegex(POLICY.PolicyError, "release-publish missing"):
            POLICY.validate_policy(self.repository)

    def test_extra_reviewer_is_rejected(self):
        self.environment_at()["protection_rules"][0]["reviewers"].append({"type": "User", "reviewer": {"id": 2}})

        with self.assertRaisesRegex(POLICY.PolicyError, "sole reviewer"):
            POLICY.validate_policy(self.repository)

    def test_wrong_reviewer_identity_or_team_is_rejected(self):
        for replacement in (
            {"type": "Team", "reviewer": {"login": "BarutSRB", "id": 12249659}},
            {"type": "User", "reviewer": {"login": "BarutSRB", "id": 2}},
            {"type": "User", "reviewer": {"login": "another-user", "id": 12249659}},
        ):
            with self.subTest(reviewer=replacement):
                self.environment_at()["protection_rules"][0]["reviewers"] = [replacement]
                with self.assertRaisesRegex(POLICY.PolicyError, "sole reviewer must be User BarutSRB"):
                    POLICY.validate_policy(self.repository)

    def test_missing_reviewer_rule_is_rejected(self):
        self.environment_at()["protection_rules"] = []

        with self.assertRaisesRegex(POLICY.PolicyError, "required-reviewer rule"):
            POLICY.validate_policy(self.repository)

    def test_admin_bypass_must_be_explicitly_disabled(self):
        for value in (True, None, "false"):
            with self.subTest(value=value):
                self.environment_at("release-publish")["can_admins_bypass"] = value
                with self.assertRaisesRegex(POLICY.PolicyError, "administrator bypass"):
                    POLICY.validate_policy(self.repository)

    def test_self_review_must_be_explicitly_allowed(self):
        for value in (True, None):
            with self.subTest(value=value):
                self.environment_at()["protection_rules"][0]["prevent_self_review"] = value
                with self.assertRaisesRegex(POLICY.PolicyError, "approve their own dispatch"):
                    POLICY.validate_policy(self.repository)

    def test_environment_must_use_custom_branch_policies(self):
        self.environment_at()["deployment_branch_policy"] = {"protected_branches": True, "custom_branch_policies": False}

        with self.assertRaisesRegex(POLICY.PolicyError, "selected branch policies"):
            POLICY.validate_policy(self.repository)

    def test_branch_policy_must_be_exactly_main_and_no_tags(self):
        for branches in (
            [],
            [{"name": "*", "type": "branch"}],
            [{"name": "main", "type": "tag"}],
            [{"name": "main", "type": "branch"}, {"name": "v*", "type": "tag"}],
        ):
            with self.subTest(branches=branches):
                self.branch_policies_at().update(total_count=len(branches), branch_policies=branches)
                with self.assertRaisesRegex(POLICY.PolicyError, "exactly the main branch and no tags"):
                    POLICY.validate_policy(self.repository)

    def test_additional_policies_outside_first_page_are_rejected(self):
        self.branch_policies_at()["total_count"] = 101

        with self.assertRaisesRegex(POLICY.PolicyError, "exactly the main branch and no tags"):
            POLICY.validate_policy(self.repository)

    def test_blocking_main_rule_is_rejected_even_with_bypass(self):
        self.responses[self.rules_path].append([{"type": "required_status_checks", "current_user_can_bypass": "always"}])

        with self.assertRaisesRegex(POLICY.PolicyError, "required_status_checks.*unsupported"):
            POLICY.validate_policy(self.repository)

    def test_invalid_main_rules_fail_closed(self):
        for response in ({}, [None], [[{}]]):
            with self.subTest(response=response):
                self.responses[self.rules_path] = response
                with self.assertRaisesRegex(POLICY.PolicyError, "Invalid main branch rule"):
                    POLICY.validate_policy(self.repository)

    def test_missing_repository_fails_before_api_calls(self):
        with self.assertRaisesRegex(POLICY.PolicyError, "GITHUB_REPOSITORY"):
            POLICY.validate_policy(None)

        self.api.assert_not_called()

    def test_cli_reports_policy_failure(self):
        with patch.dict(POLICY.os.environ, {"GITHUB_REPOSITORY": self.repository}), patch.object(
            POLICY, "validate_policy", side_effect=POLICY.PolicyError("approval is missing")
        ), patch("sys.stderr", new_callable=io.StringIO) as stderr:
            self.assertEqual(POLICY.main(), 1)

        self.assertIn("release policy error: approval is missing", stderr.getvalue())


class ReleaseCIPolicyAPITests(unittest.TestCase):
    def test_api_uses_read_only_paginated_get(self):
        result = subprocess.CompletedProcess([], 0, json.dumps([[]]), "")
        with patch.object(POLICY.subprocess, "run", return_value=result) as run:
            self.assertEqual(POLICY.github_api("repos/owner/repo/rules/branches/main", paginate=True), [[]])

        self.assertEqual(run.call_args.args[0], [
            "gh", "api", "--method", "GET", "repos/owner/repo/rules/branches/main", "--paginate", "--slurp",
        ])

    def test_api_failure_includes_endpoint(self):
        result = subprocess.CompletedProcess([], 1, "", "HTTP 404")
        with patch.object(POLICY.subprocess, "run", return_value=result), self.assertRaisesRegex(
            POLICY.PolicyError, "Cannot read repos/owner/repo/environments/release-signing: HTTP 404"
        ):
            POLICY.github_api("repos/owner/repo/environments/release-signing")

    def test_invalid_json_fails_closed(self):
        result = subprocess.CompletedProcess([], 0, "not JSON", "")
        with patch.object(POLICY.subprocess, "run", return_value=result), self.assertRaisesRegex(POLICY.PolicyError, "Invalid JSON"):
            POLICY.github_api("repos/owner/repo/environments/release-signing")


if __name__ == "__main__":
    unittest.main()

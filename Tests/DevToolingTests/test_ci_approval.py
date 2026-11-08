import copy
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ci_approval", ROOT / "Scripts/ci-approval.py")
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)
HEAD = "a" * 40
BASE = "b" * 40
MERGE = "c" * 40
RELAY = (ROOT / policy.RELAY_PATH).read_bytes()
PR = {
    "number": 1, "state": "open", "draft": False, "user": {"id": 100},
    "head": {"sha": HEAD}, "base": {"sha": BASE, "repo": {"full_name": policy.REPOSITORY}},
    "merge_commit_sha": MERGE,
}


def review(reviewer, state="APPROVED", commit=HEAD, ordinal=None, kind="User"):
    return {
        "id": ordinal if ordinal is not None else reviewer,
        "user": {"id": reviewer, "login": f"reviewer-{reviewer}", "type": kind},
        "state": state, "commit_id": commit,
    }


class FakeGitHub:
    def __init__(self, pulls, reviews):
        self.pulls = pulls
        self.reviews = reviews
        self.calls = []
        self.runs = []
        self.relay = RELAY
        self.parents = [BASE, HEAD]
        self.mode = "100644"

    def pages(self, path, key=None):
        if "/pulls?" in path:
            return self.pulls
        if path.endswith("/reviews"):
            return self.reviews[int(path.split("/")[-2])]
        if "/actions/workflows/" in path:
            return self.runs
        if path.endswith("/files"):
            return [{"filename": "website/src/index.ts"}]
        raise AssertionError(path)

    def request(self, path, data=None, method=None):
        self.calls.append((path, data, method))
        if "/pulls/" in path:
            return copy.deepcopy(next(pr for pr in self.pulls if pr["number"] == int(path.rsplit("/", 1)[-1])))
        if path.endswith("/permission"):
            return {"role_name": "maintain"}
        if "/git/commits/" in path:
            return {"parents": [{"sha": sha} for sha in self.parents], "tree": {"sha": "root"}}
        if "/git/trees/" in path:
            tree = path.rsplit("/", 1)[-1]
            if tree in {"root", "github"}:
                name, target = (".github", "github") if tree == "root" else ("workflows", "workflows")
                return {"tree": [{"path": name, "sha": target, "type": "tree", "mode": "040000"}]}
            digest = hashlib.sha1(f"blob {len(self.relay)}\0".encode() + self.relay).hexdigest()
            return {"tree": [{"path": "approval-events.yml", "sha": digest, "type": "blob", "mode": self.mode}]}
        if path.endswith("/check-runs"):
            return {"id": len(self.calls)}
        if "/check-runs/" in path or path.endswith(("/dispatches", "/cancel")):
            return None
        raise AssertionError(path)


class ApprovalTests(unittest.TestCase):
    def allowed(self, reviews, role="maintain", pr=PR):
        return policy.approvals(pr, reviews, lambda _: role)[0]

    def test_owner_approval_uses_stable_identity(self):
        self.assertTrue(self.allowed([review(policy.OWNER_ID)], role="admin"))
        self.assertFalse(self.allowed([review(policy.OWNER_ID, commit=BASE)], role="admin"))

    def test_three_distinct_current_maintainers_are_required(self):
        maintainers = [review(identifier) for identifier in (201, 202, 203)]
        self.assertTrue(self.allowed(maintainers))
        self.assertFalse(self.allowed(maintainers[:2]))
        self.assertFalse(self.allowed([maintainers[0]] * 3))
        self.assertFalse(self.allowed(maintainers, role="write"))

    def test_author_and_bots_do_not_count(self):
        owner_pr = {**PR, "user": {"id": policy.OWNER_ID}}
        self.assertFalse(self.allowed([review(policy.OWNER_ID)], pr=owner_pr))
        self.assertFalse(self.allowed([review(identifier, kind="Bot") for identifier in (201, 202, 203)]))
        self.assertFalse(self.allowed([review(PR["user"]["id"]), review(201), review(202)]))

    def test_comment_does_not_revoke_but_dismissal_and_changes_do(self):
        original = review(policy.OWNER_ID, ordinal=1)
        for state, expected in [("COMMENTED", True), ("DISMISSED", False), ("CHANGES_REQUESTED", False)]:
            with self.subTest(state=state):
                self.assertEqual(self.allowed([review(policy.OWNER_ID, state, ordinal=2), original]), expected)

    def test_new_head_requires_new_reviews(self):
        self.assertFalse(self.allowed([review(identifier, commit=BASE) for identifier in (201, 202, 203)]))

    def test_modified_relay_cannot_hide_review_revocations(self):
        api = FakeGitHub([PR], {PR["number"]: [review(policy.OWNER_ID)]})
        api.relay = RELAY.replace(b"submitted, edited, dismissed", b"submitted")
        with self.assertRaisesRegex(policy.ApprovalError, "relay"):
            policy.evaluate(api, PR, RELAY, policy.role_lookup(api))

    def test_merge_must_have_current_head_and_base(self):
        api = FakeGitHub([PR], {PR["number"]: [review(policy.OWNER_ID)]})
        api.parents = [BASE, BASE]
        with self.assertRaisesRegex(policy.ApprovalError, "current base and head"):
            policy.evaluate(api, PR, RELAY, policy.role_lookup(api))

    def test_symlink_cannot_replace_the_review_event_workflow(self):
        api = FakeGitHub([PR], {1: [review(policy.OWNER_ID)]})
        api.mode = "120000"
        with self.assertRaisesRegex(policy.ApprovalError, "relay"):
            policy.evaluate(api, PR, RELAY, policy.role_lookup(api))

    def test_shared_head_requires_each_pr_to_be_approved(self):
        peer = {**PR, "number": 2}
        api = FakeGitHub([PR, peer], {1: [review(policy.OWNER_ID)], 2: []})
        with patch("sys.stdout", new=io.StringIO()):
            policy.reconcile(api, RELAY)
        outcomes = [data["conclusion"] for _, data, method in api.calls if method == "PATCH"]
        self.assertEqual(outcomes, ["failure"])
        self.assertFalse(any(path.endswith("/dispatches") for path, _, _ in api.calls))

    def test_success_dispatches_only_immutable_approved_commits(self):
        api = FakeGitHub([PR], {1: [review(policy.OWNER_ID)]})
        with patch("sys.stdout", new=io.StringIO()):
            policy.reconcile(api, RELAY)
        dispatched = [data for path, data, _ in api.calls if path.endswith("/dispatches")]
        self.assertEqual(dispatched, [{"ref": "main", "inputs": {"pr_number": "1", "head_sha": HEAD, "merge_sha": MERGE}}])

    def test_revocation_cancels_authorized_ci(self):
        api = FakeGitHub([PR], {1: []})
        run = {"id": 71, "display_title": policy.run_title(PR), "status": "in_progress"}
        api.runs = [run]
        with patch("sys.stdout", new=io.StringIO()):
            policy.reconcile(api, RELAY)
        self.assertTrue(any(path.endswith(f"/runs/{run['id']}/cancel") for path, _, _ in api.calls))

    def test_revocation_cancels_ci_even_when_the_base_advanced(self):
        api = FakeGitHub([PR], {1: []})
        previous = {**PR, "merge_commit_sha": BASE}
        api.runs = [{"id": 71, "display_title": policy.run_title(previous), "status": "in_progress"}]
        with patch("sys.stdout", new=io.StringIO()):
            policy.reconcile(api, RELAY)
        self.assertTrue(any(path.endswith("/runs/71/cancel") for path, _, _ in api.calls))

    def test_reapproval_restarts_cancelled_ci(self):
        api = FakeGitHub([PR], {1: [review(policy.OWNER_ID)]})
        api.runs = [{"id": 71, "display_title": policy.run_title(PR), "status": "completed", "conclusion": "cancelled"}]
        with patch("sys.stdout", new=io.StringIO()):
            policy.reconcile(api, RELAY)
        self.assertTrue(any(path.endswith("/dispatches") for path, _, _ in api.calls))

    def test_run_history_failure_cannot_preserve_green_approval(self):
        api = FakeGitHub([PR], {1: []})
        original = api.pages

        def pages(path, key=None):
            if "/actions/workflows/" in path:
                raise policy.ApprovalError("Run history unavailable")
            return original(path, key)

        api.pages = pages
        with patch("sys.stdout", new=io.StringIO()), self.assertRaises(policy.ApprovalError):
            policy.reconcile(api, RELAY)
        self.assertEqual([data["conclusion"] for _, data, method in api.calls if method == "PATCH"], ["failure"])

    def test_reviews_follow_submission_time_not_draft_creation_order(self):
        earlier = {**review(policy.OWNER_ID, "CHANGES_REQUESTED", ordinal=2), "submitted_at": "2026-11-08T10:00:00Z"}
        later = {**review(policy.OWNER_ID, ordinal=1), "submitted_at": "2026-11-08T11:00:00Z"}
        self.assertTrue(self.allowed([earlier, later]))

    def test_dispatch_rechecks_approval_and_outputs_exact_merge(self):
        api = FakeGitHub([PR], {1: [review(policy.OWNER_ID)]})
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            env = {"PR_NUMBER": "1", "EXPECTED_HEAD": HEAD, "EXPECTED_MERGE": MERGE, "GITHUB_OUTPUT": str(output)}
            with patch.dict(os.environ, env), patch("sys.stdout", new=io.StringIO()):
                policy.authorize(api, RELAY)
                self.assertIn(f"checkout={MERGE}\n", output.read_text())
                api.reviews[1] = []
                with self.assertRaises(policy.ApprovalError):
                    policy.authorize(api, RELAY)

    def test_moved_head_is_rejected_before_checkout(self):
        api = FakeGitHub([{**PR, "head": {"sha": BASE}}], {1: [review(policy.OWNER_ID)]})
        env = {"PR_NUMBER": "1", "EXPECTED_HEAD": HEAD, "EXPECTED_MERGE": MERGE}
        with patch.dict(os.environ, env), self.assertRaisesRegex(policy.ApprovalError, "changed after authorization"):
            policy.authorize(api, RELAY)


if __name__ == "__main__":
    unittest.main()

from collections import defaultdict
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen


REPOSITORY = "OmniNull/OmniWM"
OWNER_ID = 12249659
CHECK_NAME = "CI approval"
WORKFLOW = "approved-ci.yml"
RELAY_PATH = ".github/workflows/approval-events.yml"


class ApprovalError(Exception):
    pass


class GitHub:
    def __init__(self, token):
        self.token = token

    def request(self, path, data=None, method=None):
        request = Request(
            f"https://api.github.com/{path}",
            data=None if data is None else json.dumps(data).encode(),
            method=method or ("GET" if data is None else "POST"),
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urlopen(request, timeout=30) as response:
                body = response.read()
                return json.loads(body) if body else None
        except HTTPError as error:
            raise ApprovalError(f"GitHub {request.method} {path.split('?')[0]} returned {error.code}") from error

    def pages(self, path, key=None):
        result = []
        separator = "&" if "?" in path else "?"
        page = 1
        while True:
            response = self.request(f"{path}{separator}per_page=100&page={page}")
            items = response if key is None else response[key]
            result.extend(items)
            if len(items) < 100:
                return result
            page += 1


def approvals(pr, reviews, role_for):
    latest = {}
    for review in sorted(reviews, key=lambda item: (item.get("submitted_at") or "", item["id"])):
        if review["state"] in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}:
            latest[review["user"]["id"]] = review
    accepted = []
    for reviewer_id, review in latest.items():
        if (
            reviewer_id == pr["user"]["id"]
            or review["user"]["type"] != "User"
            or review["state"] != "APPROVED"
            or review["commit_id"] != pr["head"]["sha"]
        ):
            continue
        if reviewer_id == OWNER_ID:
            return True, "Approved by BarutSRB for this head commit."
        if role_for(review["user"]["login"]) == "maintain":
            accepted.append(review["user"]["login"])
    return len(accepted) >= 3, f"{len(accepted)} of 3 distinct maintainers approved this head commit."


def run_title(pr):
    return f"PR #{pr['number']} {pr['head']['sha']} {pr['merge_commit_sha']}"


def resolve_merge(api, pr, canonical_relay):
    merge_sha = pr.get("merge_commit_sha")
    if not isinstance(merge_sha, str) or re.fullmatch(r"[0-9a-f]{40}", merge_sha) is None:
        raise ApprovalError("GitHub has not prepared a merge commit; resolve conflicts or recheck when ready.")
    commit = api.request(f"repos/{REPOSITORY}/git/commits/{merge_sha}")
    if [parent["sha"] for parent in commit["parents"]] != [pr["base"]["sha"], pr["head"]["sha"]]:
        raise ApprovalError("The prepared merge does not match the current base and head commits.")
    tree_sha = commit["tree"]["sha"]
    parts = RELAY_PATH.split("/")
    for component in parts:
        tree = api.request(f"repos/{REPOSITORY}/git/trees/{tree_sha}")
        entry = next((item for item in tree["tree"] if item["path"] == component), None)
        if tree.get("truncated") or entry is None:
            raise ApprovalError("Cannot verify the protected review-event relay.")
        tree_sha = entry["sha"]
    expected_blob = hashlib.sha1(f"blob {len(canonical_relay)}\0".encode() + canonical_relay).hexdigest()
    if entry["mode"] not in {"100644", "100755"} or entry["type"] != "blob" or entry["sha"] != expected_blob:
        raise ApprovalError("The review-event relay must match the protected main version.")
    return merge_sha


def evaluate(api, pr, canonical_relay, role_for):
    if pr["state"] != "open" or pr["draft"]:
        return False, "An open, non-draft pull request is required."
    if pr["base"]["repo"]["full_name"] != REPOSITORY:
        raise ApprovalError("Unexpected base repository.")
    reviews = api.pages(f"repos/{REPOSITORY}/pulls/{pr['number']}/reviews")
    allowed, reason = approvals(pr, reviews, role_for)
    if allowed:
        resolve_merge(api, pr, canonical_relay)
    return allowed, reason


def role_lookup(api):
    roles = {}

    def lookup(login):
        if login not in roles:
            value = api.request(f"repos/{REPOSITORY}/collaborators/{quote(login, safe='')}/permission")
            roles[login] = value["role_name"]
        return roles[login]

    return lookup


def write_outputs(values):
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")


def authorize(api, canonical_relay):
    number = os.environ.get("PR_NUMBER", "")
    if not number:
        if os.environ["GITHUB_EVENT_NAME"] not in {"push", "workflow_dispatch"} or os.environ["GITHUB_REF"] != "refs/heads/main":
            raise ApprovalError("Without a PR, CI may only run an approved main commit.")
        write_outputs({"checkout": os.environ["GITHUB_SHA"], "head": "", "base": "", "website": "false"})
        return
    if re.fullmatch(r"[1-9][0-9]*", number) is None:
        raise ApprovalError("A positive PR number is required.")
    expected_head = os.environ.get("EXPECTED_HEAD", "")
    expected_merge = os.environ.get("EXPECTED_MERGE", "")
    if any(re.fullmatch(r"[0-9a-f]{40}", value) is None for value in (expected_head, expected_merge)):
        raise ApprovalError("PR CI requires the approved head and merge commit SHAs.")
    pr = api.request(f"repos/{REPOSITORY}/pulls/{number}")
    if pr["head"]["sha"] != expected_head or pr["merge_commit_sha"] != expected_merge:
        raise ApprovalError("The PR changed after authorization; wait for fresh approval and CI.")
    role_for = role_lookup(api)
    peers = api.pages(f"repos/{REPOSITORY}/pulls?state=open")
    for peer in peers:
        if peer["head"]["sha"] == expected_head:
            detail = api.request(f"repos/{REPOSITORY}/pulls/{peer['number']}")
            allowed, reason = evaluate(api, detail, canonical_relay, role_for)
            if not allowed:
                raise ApprovalError(f"PR #{peer['number']}: {reason}")
    allowed, reason = evaluate(api, pr, canonical_relay, role_for)
    if not allowed:
        raise ApprovalError(reason)
    files = api.pages(f"repos/{REPOSITORY}/pulls/{number}/files")
    website = any(
        item["filename"].startswith("website/")
        or item["filename"] in {"Sources/OmniWM/Resources/omniwm.d.luau", ".do/app.yaml", ".github/workflows/approved-website.yml"}
        for item in files
    )
    write_outputs({"checkout": expected_merge, "head": expected_head, "base": pr["base"]["sha"], "website": str(website).lower()})
    print(f"Authorized PR #{number} at head {expected_head} and merge {expected_merge}.")


def reconcile(api, canonical_relay):
    pulls = api.pages(f"repos/{REPOSITORY}/pulls?state=open")
    grouped = defaultdict(list)
    for pr in pulls:
        grouped[pr["head"]["sha"]].append(pr)
    role_for = role_lookup(api)
    decisions = []
    for head, peers in grouped.items():
        check = api.request(f"repos/{REPOSITORY}/check-runs", {
            "name": CHECK_NAME, "head_sha": head, "status": "in_progress",
            "output": {"title": "Checking current approvals", "summary": "Requires BarutSRB or three distinct maintainers for every PR sharing this commit."},
        })
        details = []
        reasons = []
        allowed = True
        for peer in peers:
            try:
                pr = api.request(f"repos/{REPOSITORY}/pulls/{peer['number']}")
                if pr["head"]["sha"] != head:
                    raise ApprovalError("Head changed during the check.")
                accepted, reason = evaluate(api, pr, canonical_relay, role_for)
                allowed = allowed and accepted
                details.append(pr)
            except (ApprovalError, KeyError, ValueError) as error:
                accepted, reason, allowed = False, str(error), False
            reasons.append(f"PR #{peer['number']}: {reason}")
        api.request(f"repos/{REPOSITORY}/check-runs/{check['id']}", {
            "status": "completed", "conclusion": "success" if allowed else "failure",
            "output": {"title": "Approval policy satisfied" if allowed else "Approval required", "summary": "\n".join(reasons)},
        }, method="PATCH")
        print("\n".join(reasons))
        decisions.extend((pr, allowed) for pr in details)
    runs = api.pages(f"repos/{REPOSITORY}/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch", "workflow_runs")
    for pr, allowed in decisions:
        head = pr["head"]["sha"]
        matching = [run for run in runs if run["display_title"] == run_title(pr) and run.get("conclusion") != "cancelled"]
        if allowed and not matching:
            current = api.request(f"repos/{REPOSITORY}/pulls/{pr['number']}")
            if (current["head"]["sha"], current["merge_commit_sha"]) != (head, pr["merge_commit_sha"]):
                continue
            api.request(f"repos/{REPOSITORY}/actions/workflows/{WORKFLOW}/dispatches", {
                "ref": "main", "inputs": {"pr_number": str(pr["number"]), "head_sha": head, "merge_sha": pr["merge_commit_sha"]},
            })
        elif not allowed:
            for run in runs:
                if not run["display_title"].startswith(f"PR #{pr['number']} {head} "):
                    continue
                if run["status"] in {"queued", "in_progress", "waiting", "pending", "requested"}:
                    api.request(f"repos/{REPOSITORY}/actions/runs/{run['id']}/cancel", {})


def main():
    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY or os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ApprovalError("Approval policy must run from OmniNull/OmniWM main.")
    api = GitHub(os.environ["GH_TOKEN"])
    canonical_relay = Path(RELAY_PATH).read_bytes()
    if sys.argv[1:] == ["authorize"]:
        authorize(api, canonical_relay)
    elif sys.argv[1:] == ["reconcile"]:
        reconcile(api, canonical_relay)
    elif sys.argv[1:] == ["verify-access"]:
        for login in ("BarutSRB", "Guria"):
            print(f"{login}: {role_lookup(api)(login)}")
    else:
        raise ApprovalError("Expected authorize or reconcile.")


if __name__ == "__main__":
    try:
        main()
    except (ApprovalError, KeyError, ValueError, OSError) as error:
        raise SystemExit(f"CI approval: {error}") from error

import json
import os
import re
import subprocess
import sys


ENVIRONMENTS = ("release-signing", "release-publish")
REVIEWER_ID = 12249659
REVIEWER_LOGIN = "BarutSRB"
ALLOWED_MAIN_RULES = {"deletion", "non_fast_forward"}


class PolicyError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise PolicyError(message)


def github_api(path, paginate=False):
    command = ["gh", "api", "--method", "GET", path]
    if paginate:
        command.extend(["--paginate", "--slurp"])
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    require(result.returncode == 0, f"Cannot read {path}: {result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise PolicyError(f"Invalid JSON from {path}: {error}") from error


def validate_environment(repository, name):
    path = f"repos/{repository}/environments/{name}"
    environment = github_api(path)
    require(isinstance(environment, dict), f"{name}: invalid environment response")
    require(environment.get("can_admins_bypass") is False, f"{name}: administrator bypass must be disabled")
    branch_policy = environment.get("deployment_branch_policy")
    require(
        isinstance(branch_policy, dict)
        and branch_policy.get("protected_branches") is False
        and branch_policy.get("custom_branch_policies") is True,
        f"{name}: selected branch policies must be enabled",
    )
    rules = environment.get("protection_rules")
    require(isinstance(rules, list) and all(isinstance(rule, dict) for rule in rules), f"{name}: invalid protection rules")
    reviewer_rules = [rule for rule in rules if rule.get("type") == "required_reviewers"]
    require(len(reviewer_rules) == 1, f"{name}: exactly one required-reviewer rule is required")
    reviewer_rule = reviewer_rules[0]
    require(reviewer_rule.get("prevent_self_review") is False, f"{name}: BarutSRB must be able to approve their own dispatch")
    reviewers = reviewer_rule.get("reviewers")
    require(isinstance(reviewers, list) and len(reviewers) == 1, f"{name}: BarutSRB must be the sole reviewer")
    reviewer = reviewers[0]
    identity = reviewer.get("reviewer") if isinstance(reviewer, dict) else None
    require(
        isinstance(identity, dict)
        and reviewer.get("type") == "User"
        and identity.get("id") == REVIEWER_ID
        and identity.get("login") == REVIEWER_LOGIN,
        f"{name}: the sole reviewer must be User BarutSRB ({REVIEWER_ID})",
    )
    policies = github_api(f"{path}/deployment-branch-policies?per_page=100")
    require(isinstance(policies, dict), f"{name}: invalid deployment branch policies")
    branches = policies.get("branch_policies")
    require(
        policies.get("total_count") == 1
        and isinstance(branches, list)
        and len(branches) == 1
        and isinstance(branches[0], dict)
        and branches[0].get("name") == "main"
        and branches[0].get("type") == "branch",
        f"{name}: allow exactly the main branch and no tags",
    )


def validate_policy(repository):
    require(
        isinstance(repository, str) and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository),
        "GITHUB_REPOSITORY must identify the release repository as owner/repository",
    )
    for name in ENVIRONMENTS:
        validate_environment(repository, name)
    pages = github_api(f"repos/{repository}/rules/branches/main?per_page=100", paginate=True)
    require(isinstance(pages, list) and all(isinstance(page, list) for page in pages), "Invalid main branch rules response")
    for page in pages:
        for rule in page:
            require(isinstance(rule, dict) and isinstance(rule.get("type"), str), "Invalid main branch rule")
            require(
                rule["type"] in ALLOWED_MAIN_RULES,
                f"main rule '{rule['type']}' is unsupported for release publication; branch protection must remain enforced",
            )


def main():
    try:
        validate_policy(os.environ.get("GITHUB_REPOSITORY"))
    except (OSError, PolicyError) as error:
        print(f"release policy error: {error}", file=sys.stderr)
        return 1
    print("Release environments and main rules match the required policy.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

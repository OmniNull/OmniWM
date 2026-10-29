"""Decide when to build a canary, verify its CI, and write release notes.

A canary publishes main HEAD as an automated prerelease. The build is skipped
when HEAD is already contained in any existing canary or stable tag, because
such a canary would only repackage an existing build.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

CANARY_GLOB = "canary-*"
STABLE_GLOB = "v[0-9]*"
TAG_GLOBS = (CANARY_GLOB, STABLE_GLOB)


class CanaryError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise CanaryError(message)


def git(repo, *args):
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    require(
        result.returncode == 0,
        f"git {' '.join(args)} failed: {result.stderr.strip()}",
    )
    return result.stdout.strip()


def is_ancestor(repo, maybe_ancestor, descendant):
    result = subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", maybe_ancestor, descendant],
        capture_output=True,
        text=True,
        check=False,
    )
    require(
        result.returncode in (0, 1),
        f"git merge-base --is-ancestor {maybe_ancestor} {descendant} failed: {result.stderr.strip()}",
    )
    return result.returncode == 0


def tags_with_create_dates(repo, pattern):
    """Return (create_date, tag) for every tag matching the pattern.

    creatordate is the tagger date for annotated tags and the commit date for
    lightweight ones (auto-created canary tags are lightweight), so it works for
    both.
    """
    refs = git(
        repo,
        "for-each-ref",
        f"refs/tags/{pattern}",
        "--format=%(refname:short)%00%(creatordate:unix)",
    )
    tags = []
    for line in refs.splitlines():
        name, _, date = line.partition("\x00")
        tags.append((int(date or 0), name))
    return sorted(tags)


def containing_tag(repo, commit):
    """Newest canary or stable tag whose history contains commit, if any."""
    best = None
    for pattern in TAG_GLOBS:
        for date, tag in tags_with_create_dates(repo, pattern):
            if is_ancestor(repo, commit, tag):
                if best is None or date > best[0]:
                    best = (date, tag)
    return best[1] if best else None


def check(repo, force):
    head = git(repo, "rev-parse", "HEAD")
    if not force:
        tag = containing_tag(repo, head)
        if tag:
            return {
                "should_skip": "true",
                "skip_reason": f"HEAD {head[:12]} is already contained in {tag}",
            }
        base = notes_base(repo, head)
        if base and not app_changes(repo, f"{base}..{head}"):
            return {"should_skip": "true", "skip_reason": f"only docs changed since {base}"}
    return {"should_skip": "false", "skip_reason": ""}


def github_api(path):
    result = subprocess.run(
        ["gh", "api", "--method", "GET", "--paginate", "--slurp", path],
        capture_output=True,
        text=True,
        check=False,
    )
    require(result.returncode == 0, f"Cannot read CI status: {result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise CanaryError(f"Invalid CI response: {error}") from error


def verify_ci(repo, repository):
    require(repository, "--repository or GITHUB_REPOSITORY is required for verify-ci")
    head = git(repo, "rev-parse", "HEAD")
    pages = github_api(
        f"repos/{repository}/actions/workflows/ci.yml/runs"
        f"?branch=main&event=push&head_sha={head}&per_page=100"
    )
    runs = [run for page in pages for run in page["workflow_runs"]]
    require(runs, f"No OmniWM CI push run exists for main commit {head}; wait for CI and retry the canary.")
    latest = max(runs, key=lambda run: run["run_number"])
    expected = {
        "head_sha": head,
        "head_branch": "main",
        "event": "push",
        "path": ".github/workflows/ci.yml",
    }
    require(
        all(latest.get(key) == value for key, value in expected.items()),
        f"Latest CI run does not match the checked-out main commit {head}.",
    )
    require(
        latest.get("status") == "completed" and latest.get("conclusion") == "success",
        f"Latest OmniWM CI run for {head} has not succeeded: {latest['html_url']} "
        f"({latest.get('status')}/{latest.get('conclusion')}); wait for CI and retry the canary.",
    )
    pages = github_api(f"repos/{repository}/actions/runs/{latest['id']}/jobs?filter=latest&per_page=100")
    jobs = [job for page in pages for job in page["jobs"]]
    for name in ("Verify", "Tests"):
        matching = [job for job in jobs if job.get("name") == name]
        require(
            matching and all(job.get("status") == "completed" and job.get("conclusion") == "success" for job in matching),
            f"{name} must complete successfully for {head}: {latest['html_url']}",
        )
    return latest


def notes_base(repo, commit):
    """Newest tag (canary or stable) that is an ancestor of commit.

    Both pools compete on creatordate without pattern priority: when a stable
    release lands after a canary, its tag describes history the canary
    predates, so the next canary's notes must resume after the release.
    """
    candidates = []
    for pattern in TAG_GLOBS:
        candidates.extend(
            (date, tag)
            for date, tag in tags_with_create_dates(repo, pattern)
            if is_ancestor(repo, tag, commit)
        )
    return max(candidates)[1] if candidates else None


def notes(repo):
    head = git(repo, "rev-parse", "HEAD")
    previous = notes_base(repo, head)
    lines = [
        "Automated canary build of `main`. It is signed and notarized like a"
        " release but skips the owner review, so treat it as unstable.",
        "",
        "See the [canary guide](https://omniwm.app/guides/install/#canary-builds)"
        " to install, update, or return to stable. For everyday use, download the"
        " [latest stable release](https://github.com/OmniNull/OmniWM/releases/latest).",
        "",
        f"- Commit: `{head[:12]}`",
    ]
    if previous:
        lines.append(f"- Base tag: `{previous}`")
    lines.append("")
    lines.append(f"### Changes since {previous}" if previous else "### Recent changes")
    lines.append("")
    log_range = [f"{previous}..{head}"] if previous else ["-20", head]
    lines.append("\n".join(app_changes(repo, *log_range)) or "No commits recorded.")
    return "\n".join(lines) + "\n"


def app_changes(repo, *log_range):
    log = git(
        repo, "-c", "core.quotePath=false", "log", "--format=%x00- %h %s",
        "--name-only", "--no-renames", "--diff-merges=first-parent", *log_range,
    )
    changes = []
    for record in log.split("\x00")[1:]:
        entry, *paths = [line for line in record.splitlines() if line]
        if not paths or not all(map(is_docs_path, paths)):
            changes.append(entry)
    return changes


def is_docs_path(path):
    return path.startswith(("docs/", "website/")) or ("/" not in path and path.endswith(".md"))


def write_github_output(path, values):
    require(path, "--github-output or GITHUB_OUTPUT is required for check")
    with open(path, "a", encoding="utf-8") as handle:
        for key, value in values.items():
            handle.write(f"{key}={value}\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    check_parser = subparsers.add_parser("check", help="decide whether to build")
    check_parser.add_argument("--repo", default=".")
    check_parser.add_argument("--force", action="store_true")
    check_parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))

    ci_parser = subparsers.add_parser("verify-ci", help="require passing main push CI for the checked-out commit")
    ci_parser.add_argument("--repo", default=".")
    ci_parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))

    notes_parser = subparsers.add_parser("notes", help="print canary release notes")
    notes_parser.add_argument("--repo", default=".")
    notes_parser.add_argument("--output")

    args = parser.parse_args(argv)
    try:
        if args.command == "check":
            values = check(args.repo, args.force)
            if args.github_output:
                write_github_output(args.github_output, values)
            print(values["should_skip"])
            if values["skip_reason"]:
                print(values["skip_reason"], file=sys.stderr)
        elif args.command == "verify-ci":
            ci_run = verify_ci(args.repo, args.repository)
            print(f"OmniWM CI passed for {ci_run['head_sha']}: {ci_run['html_url']}")
        else:
            text = notes(args.repo)
            if args.output:
                Path(args.output).write_text(text, encoding="utf-8")
            else:
                sys.stdout.write(text)
    except (CanaryError, OSError) as error:
        print(f"canary-release: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

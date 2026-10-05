"""Decide when a canary build is needed and write its release notes.

A canary publishes main HEAD as an automated prerelease. The build is skipped
when HEAD is already contained in any existing canary or stable tag, because
such a canary would only repackage an existing build.
"""

import argparse
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
        check=False,
    )
    return result.returncode == 0


def tags_with_create_dates(repo, pattern):
    """Return (create_date, tag) for every tag matching the pattern.

    creatordate is the tagger date for annotated tags and the commit date for
    lightweight ones (GitHub release tags are lightweight), so it works for
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
    return {"should_skip": "false", "skip_reason": ""}


def notes_base(repo, commit):
    """Newest canary containing commit, else the newest stable tag that does.

    This mirrors the skip gate: canary notes resume where the previous canary
    ended, falling back to the last stable release.
    """
    for pattern in (CANARY_GLOB, STABLE_GLOB):
        candidates = [
            (date, tag)
            for date, tag in tags_with_create_dates(repo, pattern)
            if is_ancestor(repo, tag, commit)
        ]
        if candidates:
            return max(candidates)[1]
    return None


def notes(repo):
    head = git(repo, "rev-parse", "HEAD")
    previous = notes_base(repo, head)
    lines = [
        "Automated canary build of `main`. It is signed and notarized like a"
        " release but skips the owner review, so treat it as unstable.",
        "",
        f"- Commit: `{head[:12]}`",
    ]
    if previous:
        lines.append(f"- Base tag: `{previous}`")
    lines.append("")
    lines.append(f"### Changes since {previous}" if previous else "### Recent changes")
    lines.append("")
    if previous:
        log = git(repo, "log", "--format=- %h %s", f"{previous}..{head}")
    else:
        log = git(repo, "log", "--format=- %h %s", "-20", head)
    lines.append(log or "No commits recorded.")
    return "\n".join(lines) + "\n"


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
        else:
            text = notes(args.repo)
            if args.output:
                Path(args.output).write_text(text, encoding="utf-8")
            else:
                sys.stdout.write(text)
    except CanaryError as error:
        print(f"canary-release: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

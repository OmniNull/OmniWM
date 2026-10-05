#!/usr/bin/env python3

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def prepared_artifact(repository, run_id, version):
    run = api(f"repos/{repository}/actions/runs/{run_id}")
    expected = {
        "path": ".github/workflows/release.yml",
        "event": "workflow_dispatch",
        "head_branch": "main",
        "status": "completed",
        "conclusion": "success",
    }
    if any(run.get(key) != value for key, value in expected.items()):
        raise ValueError("prepare_run_id must identify a successful release workflow on main")
    if run["repository"]["full_name"] != repository:
        raise ValueError("Prepare run repository mismatch")
    result = api(f"repos/{repository}/actions/runs/{run_id}/artifacts?name=omniwm-release-v{version}")
    artifacts = result["artifacts"]
    if len(artifacts) != 1 or artifacts[0]["expired"]:
        raise ValueError("The prepare run must have one unexpired release artifact")
    return run, artifacts[0]


def review_summary(root, version, source_commit, notes, artifact_id, run_url):
    manifest = json.loads((root / f"release-v{version}.json").read_text())
    if manifest["version"] != version or manifest["state"] != "prepared":
        raise ValueError("Artifact is not the requested prepared release")
    if manifest["original_main_head"] != source_commit:
        raise ValueError("Artifact source does not match its prepare run")
    commit = manifest["release_commit"]
    if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise ValueError("Invalid prepared release commit")
    ghostty = json.loads((root / f"ghostty-provenance-v{version}.json").read_text())
    if ghostty["zip_sha256"] != manifest["assets"]["ghostty"]["sha256"]:
        raise ValueError("Ghostty source provenance does not match the release asset")
    lines = [
        f"## Approval requested: OmniWM v{version}",
        "",
        "Only BarutSRB may approve the release-publish job. Review the downloaded app before approving.",
        "",
        f"Prepare run: {run_url}",
        f"Artifact ID: `{artifact_id}`",
        f"Release commit: `{commit}`",
        f"Ghostty source commit: `{ghostty['source_revision']}`",
        f"Ghostty Zig version: `{ghostty['zig_version']}`",
        f"Release notes SHA-256: `{hashlib.sha256(notes.encode()).hexdigest()}`",
        "",
    ]
    for name, filename in (("app", f"OmniWM-v{version}.zip"), ("ghostty", f"GhosttyKit.xcframework-v{version}.zip")):
        with (root / filename).open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest != manifest["assets"][name]["sha256"]:
            raise ValueError(f"Prepared {name} asset hash mismatch")
        lines.append(f"{filename}: `{digest}`")
    lines.extend(["", "### Final release notes", "", notes, ""])
    return "\n".join(lines)


def main():
    if len(sys.argv) == 1:
        run, artifact = prepared_artifact(os.environ["GITHUB_REPOSITORY"], os.environ["PREPARE_RUN_ID"], os.environ["VERSION"])
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as stream:
            stream.write(f"artifact_id={artifact['id']}\nsource_commit={run['head_sha']}\nrun_url={run['html_url']}\n")
        return
    summary = review_summary(
        Path(sys.argv[1]), os.environ["VERSION"], os.environ["PREPARE_SOURCE_COMMIT"],
        os.environ["RELEASE_NOTES"], os.environ["RELEASE_ARTIFACT_ID"], os.environ["PREPARE_RUN_URL"],
    )
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as stream:
        stream.write(summary)


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"release review: {error}") from error

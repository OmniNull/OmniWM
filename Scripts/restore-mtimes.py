import json
import os
import subprocess
import sys
import time

SOURCES = (".swift", ".h", ".hpp", ".c", ".cc", ".cpp", ".m", ".mm", ".modulemap")


def git(*arguments):
    return subprocess.run(["git", *arguments], capture_output=True, text=True, check=True).stdout


def sources_of_dependents(changed, package, tracked):
    roots, excluded, needs = {}, {}, {}
    for target in package["targets"]:
        if target["type"] == "binary":
            continue
        folder = "Tests" if target["type"] == "test" else "Sources"
        root = (target.get("path") or f"{folder}/{target['name']}").rstrip("/") + "/"
        roots[target["name"]] = root
        excluded[target["name"]] = tuple(root + path.rstrip("/") for path in target.get("exclude", []))
        needs[target["name"]] = {
            dependency[kind][0] for dependency in target.get("dependencies", []) for kind in ("byName", "target")
            if kind in dependency
        }

    def compiled(path, name):
        return path.startswith(roots[name]) and path.endswith(SOURCES) and not any(
            path == skipped or path.startswith(skipped + "/") for skipped in excluded[name]
        )

    frontier = {name for name in roots if any(compiled(path, name) for path in changed)}
    dependents = set()
    while frontier:
        frontier = {name for name, used in needs.items() if used & frontier} - dependents
        dependents |= frontier
    return {path for path in tracked if any(compiled(path, name) for name in dependents)}


tracked = set(git("ls-files").splitlines())
undated = set(tracked)
log = git("log", "--first-parent", "--diff-merges=first-parent", "--format=@%ct", "--name-only")
stamp = None
for line in log.splitlines():
    if line.startswith("@"):
        stamp = int(line[1:])
    elif line in undated:
        undated.discard(line)
        os.utime(line, (stamp, stamp), follow_symlinks=False)
    if not undated:
        break

cached_key = sys.argv[1] if len(sys.argv) > 1 else ""
if cached_key:
    cached_commit = cached_key.rsplit("-", 1)[-1]
    known = subprocess.run(["git", "cat-file", "-e", f"{cached_commit}^{{commit}}"], capture_output=True).returncode == 0
    changed = set(git("diff", "--name-only", "--no-renames", cached_commit, "HEAD").splitlines()) if known else tracked
    if known and len(sys.argv) > 2:
        with open(sys.argv[2]) as package:
            changed |= sources_of_dependents(changed, json.load(package), tracked)
    now = time.time()
    for path in changed & tracked:
        os.utime(path, (now, now), follow_symlinks=False)

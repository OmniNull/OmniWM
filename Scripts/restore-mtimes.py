import os
import subprocess
import sys
import time


def git(*arguments):
    return subprocess.run(["git", *arguments], capture_output=True, text=True, check=True).stdout


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
    changed = set(git("diff", "--name-only", cached_commit, "HEAD").splitlines()) if known else tracked
    now = time.time()
    for path in changed & tracked:
        os.utime(path, (now, now), follow_symlinks=False)

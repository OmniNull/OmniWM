import os
import subprocess

tracked = set(subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.splitlines())
log = subprocess.run(["git", "log", "--format=@%ct", "--name-only"], capture_output=True, text=True, check=True).stdout
stamp = None
for line in log.splitlines():
    if line.startswith("@"):
        stamp = int(line[1:])
    elif line in tracked:
        tracked.discard(line)
        os.utime(line, (stamp, stamp), follow_symlinks=False)
    if not tracked:
        break

"""Check that every *_URL pinned in Scripts/dev-tools.env is downloadable.

The flake fetches these URLs during make setup and in every CI job. A pin
that points at a release asset before the release is published breaks both.
"""

import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def pinned_urls(path):
    urls = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition("=")
        if separator and re.fullmatch(r"[A-Z0-9_]+_URL", key):
            urls[key] = value
    return urls


def unreachable(url, timeout=30):
    try:
        request = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(request, timeout=timeout):
            return None
    except urllib.error.HTTPError as error:
        return f"HTTP {error.code}"
    except (urllib.error.URLError, OSError, ValueError) as error:
        return str(getattr(error, "reason", error))


def main(argv):
    path = Path(argv[1]) if len(argv) > 1 else ROOT / "Scripts/dev-tools.env"
    failures = 0
    for key, url in pinned_urls(path).items():
        reason = unreachable(url)
        if reason:
            failures += 1
            print(f"{path.name}: {key} is not downloadable ({reason}): {url}", file=sys.stderr)
    if failures:
        print("publish the asset or keep the previous pin until it is public", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

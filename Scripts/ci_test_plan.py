"""Plan which Swift test groups a CI run needs.

Reads the changed paths on stdin and prints GITHUB_OUTPUT lines. Pull requests
that change no app files skip the suite, pull requests that only change Swift
test files run the suites those files reach, everything else runs the full
suite split into parallel groups.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = Path("Tests/OmniWMTests")
GLASS = r"OmniWMTests\.ShellGlass"
FULL = [
    {"name": "glass", "flag": "--filter", "pattern": GLASS},
    {"name": "rest", "flag": "--skip", "pattern": GLASS},
]
DECLARATION = re.compile(r"^[ \t]*(?:@\w+[ \t]+)*((?:(?:public|package|internal|open|private|fileprivate|final|nonisolated)[ \t]+)*)"
                         r"(class|struct|enum|protocol|actor|extension)[ \t]+([A-Z]\w*)(?:[ \t]*:[ \t]*(\w+))?",
                         re.MULTILINE)
TOP_LEVEL = re.compile(r"^(?:@\w+(?:\([^)\n]*\))?[ \t]+)*((?:\w+[ \t]+)*)(?:\w+\(set\)[ \t]+)?(?:func|var|let)[ \t]", re.MULTILINE)
IDENTIFIER = re.compile(r"\b[A-Z]\w+\b")


def needs_tests(path):
    if path.startswith(("docs/", "website/", "Tests/DevToolingTests/")):
        return False
    if path.startswith("Scripts/") and path.count("/") == 1 and path.endswith(".py"):
        return False
    return not ("/" not in path and path.endswith(".md"))


def suites(changed, root=ROOT):
    files = {path.relative_to(root).as_posix(): path.read_text(encoding="utf-8", errors="ignore")
             for path in (root / TESTS).glob("*.swift")}
    declared = {name: list(DECLARATION.finditer(text)) for name, text in files.items()}
    types = {m[3] for found in declared.values() for m in found if m[2] != "extension"}
    parents = {m[3]: m[4] for found in declared.values() for m in found if m[4] and m[2] != "extension"}

    def opaque(path):
        return (any("private" not in m[1] for m in TOP_LEVEL.finditer(files[path]))
                or any(m[2] == "extension" and m[3] not in types and "private" not in m[1] for m in declared[path]))

    def is_case(name):
        seen = set()
        while name in parents and name not in seen:
            seen.add(name)
            name = parents[name]
        return name == "XCTestCase"

    users = {}
    for name, text in files.items():
        for identifier in set(IDENTIFIER.findall(text)):
            users.setdefault(identifier, []).append(name)

    pending = list(changed)
    reached = set()
    names = set()
    shared = set()
    while pending:
        path = pending.pop()
        if path in reached:
            continue
        if path not in files or not declared[path] or opaque(path):
            return None
        reached.add(path)
        for match in declared[path]:
            name = match[3]
            names.add(name)
            if "private" not in match[1] and name not in shared:
                shared.add(name)
                pending += users.get(name, [])
    cases = sorted(name for name in names if is_case(name))
    total = sum(is_case(name) for name in parents)
    return cases if len(cases) * 2 <= total else None


def plan(paths, event, root=ROOT):
    paths = [path for path in paths if path]
    if event != "pull_request":
        return FULL
    app = [path for path in paths if needs_tests(path)]
    if not app:
        return []
    if all(path.startswith(f"{TESTS}/") and path.endswith(".swift") for path in app):
        names = suites(app, root)
        if names:
            split = {"glass": [n for n in names if n.startswith("ShellGlass")],
                     "rest": [n for n in names if not n.startswith("ShellGlass")]}
            return [{"name": f"selected {name}", "flag": "--filter",
                     "pattern": r"OmniWMTests\.(" + "|".join(group) + ")/"}
                    for name, group in split.items() if group]
    return FULL


def main():
    groups = plan(sys.stdin.read().splitlines(), sys.argv[1] if len(sys.argv) > 1 else "pull_request")
    print(f"tests={'true' if groups else 'false'}")
    print(f"matrix={json.dumps({'include': groups or FULL})}")


if __name__ == "__main__":
    main()

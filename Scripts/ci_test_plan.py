"""Plan which Swift test groups a CI run needs.

Reads the changed paths on stdin and prints GITHUB_OUTPUT lines. Pull requests
that change no app files skip the suite, pull requests that only change Swift
test files run the suites those files reach, everything else runs the full
suite split into parallel shards packed by ci-suite-seconds.json. The last
shard skips what the others filter, so every suite runs somewhere.
"""

import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = Path("Tests/OmniWMTests")
SHARDS = 4
SHELL_SUITES = {"LauncherExecutionTests", "LauncherTerminalLiveTests", "NuCompletionTests", "WorkspaceMoveIPCContractTests"}
SECONDS = json.loads((ROOT / "Scripts/ci-suite-seconds.json").read_text())
DEFAULT_SECONDS = 0.1
DECLARATION = re.compile(r"^[ \t]*(?:@\w+[ \t]+)*((?:(?:public|package|internal|open|private|fileprivate|final|nonisolated)[ \t]+)*)"
                         r"(class|struct|enum|protocol|actor|extension)[ \t]+([A-Z]\w*)(?:[ \t]*:[ \t]*(\w+))?",
                         re.MULTILINE)
TOP_LEVEL = re.compile(r"^(?:@\w+(?:\([^)\n]*\))?[ \t]+)*((?:\w+[ \t]+)*)(?:\w+\(set\)[ \t]+)?(?:func|var|let)[ \t]", re.MULTILINE)
IDENTIFIER = re.compile(r"\b[A-Z]\w+\b")
SUITE_END = re.compile(r"Test Suite '(\w+)' (?:passed|failed) at")
EXECUTED = re.compile(r"Executed \d+ tests?, .* in ([\d.]+) \(")


def needs_tests(path):
    if path.startswith(("docs/", "website/", "Tests/DevToolingTests/")):
        return False
    if path.startswith("Scripts/") and path.count("/") == 1 and path.endswith(".py"):
        return False
    return not ("/" not in path and path.endswith(".md"))


def scan(root):
    files = {path.relative_to(root).as_posix(): path.read_text(encoding="utf-8", errors="ignore")
             for path in (root / TESTS).glob("*.swift")}
    declared = {name: list(DECLARATION.finditer(text)) for name, text in files.items()}
    parents = {m[3]: m[4] for found in declared.values() for m in found if m[4] and m[2] != "extension"}
    return files, declared, parents


def is_case(name, parents):
    seen = set()
    while name in parents and name not in seen:
        seen.add(name)
        name = parents[name]
    return name == "XCTestCase"


def test_cases(root=ROOT):
    _, _, parents = scan(root)
    return sorted(name for name in parents if is_case(name, parents))


def suites(changed, root=ROOT):
    files, declared, parents = scan(root)
    types = {m[3] for found in declared.values() for m in found if m[2] != "extension"}

    def opaque(path):
        return (any("private" not in m[1] for m in TOP_LEVEL.finditer(files[path]))
                or any(m[2] == "extension" and m[3] not in types and "private" not in m[1] for m in declared[path]))

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
    cases = sorted(name for name in names if is_case(name, parents))
    total = sum(is_case(name, parents) for name in parents)
    return cases if len(cases) * 2 <= total else None


def seconds(name):
    return SECONDS.get(name, DEFAULT_SECONDS)


def shard(names, count):
    units = [[name] for name in names if name not in SHELL_SUITES]
    shells = sorted(set(names) & SHELL_SUITES)
    if shells:
        units.append(shells)
    bins = [[] for _ in range(count)]
    load = [0.0] * count
    for unit in sorted(units, key=lambda unit: (-sum(map(seconds, unit)), unit)):
        lightest = load.index(min(load))
        bins[lightest] += unit
        load[lightest] += sum(map(seconds, unit))
    return [sorted(group) for group in bins if group]


def group(name, flag, names, runs):
    return {"name": name, "flag": flag, "pattern": pattern(names), "shells": not SHELL_SUITES.isdisjoint(runs)}


def pattern(names):
    return r"OmniWMTests\.(" + "|".join(names) + ")/"


def full(root=ROOT):
    groups = shard(test_cases(root), SHARDS)
    filtered = [group(f"shard {index}", "--filter", members, members) for index, members in enumerate(groups[:-1], 1)]
    skipped = sorted(name for members in groups[:-1] for name in members)
    return filtered + [group(f"shard {len(groups)}", "--skip", skipped, groups[-1])]


def selected(names, root=ROOT):
    budget = sum(map(seconds, test_cases(root))) / SHARDS
    count = max(1, min(SHARDS, math.ceil(sum(map(seconds, names)) / budget)))
    return [group(f"selected {index}", "--filter", members, members) for index, members in enumerate(shard(names, count), 1)]


def plan(paths, event, root=ROOT):
    paths = [path for path in paths if path]
    if event != "pull_request":
        return full(root)
    app = [path for path in paths if needs_tests(path)]
    if not app:
        return []
    if all(path.startswith(f"{TESTS}/") and path.endswith(".swift") for path in app):
        names = suites(app, root)
        if names:
            return selected(names, root)
    return full(root)


def measured_seconds(log):
    measured = {}
    suite = None
    for line in log.splitlines():
        if match := SUITE_END.search(line):
            suite = match[1]
        elif suite and (match := EXECUTED.search(line)):
            measured[suite] = round(float(match[1]), 1)
            suite = None
    return measured


def refreshed(existing, log):
    merged = {**existing, **measured_seconds(log)}
    return {suite: value for suite, value in sorted(merged.items()) if value >= 0.5}


def main():
    if sys.argv[1:] == ["seconds"]:
        path = ROOT / "Scripts/ci-suite-seconds.json"
        staged = path.with_suffix(".tmp")
        staged.write_text(json.dumps(refreshed(SECONDS, sys.stdin.read()), indent=2) + "\n")
        staged.replace(path)
        return
    groups = plan(sys.stdin.read().splitlines(), sys.argv[1] if len(sys.argv) > 1 else "pull_request")
    print(f"tests={'true' if groups else 'false'}")
    print(f"matrix={json.dumps({'include': groups or full()})}")


if __name__ == "__main__":
    main()

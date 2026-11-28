import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFINITIONS = ROOT / "Sources/OmniWM/Resources/omniwm-config.d.luau"
GUIDE = ROOT / "website/src/content/docs/config/init-luau.md"
FIXTURES = ROOT / "Tests/DevToolingTests/Fixtures/luau-check"
STRICT = "--!strict"
LUA = {"lua", "luau"}
OPENING_FENCE = re.compile(r"^(?P<indent> {0,3})(?:(?P<fence>`{3,})(?P<info>[^`]*)|(?P<tilde>~{3,})(?P<tildeinfo>.*))$")
LANGUAGE = re.compile(r"[A-Za-z0-9_+-]+")
TYPE_ERRORS = 1
REJECTIONS = {
    "argument-kind.luau": "None of the overloads for function that accept 1 arguments are compatible.",
    "argument-missing.luau": "No overload for function accepts 0 arguments.",
    "argument-value.luau": "None of the overloads for function that accept 1 arguments are compatible.",
    "member-typo.luau": "Key 'focuss' not found in table 'ConfigCommands'",
    "mode-directive.luau": "ModeError: every checked file must be analyzed in strict mode",
    "namespace-typo.luau": "does not have key 'dispach'",
    "renamed-open.luau": "Key 'open' not found in table 'ConfigActionBuilders'",
}


def recipes(markdown):
    blocks = []
    opening = None
    for line in markdown.splitlines(keepends=True):
        text = line.rstrip("\n")
        if opening is None:
            match = OPENING_FENCE.match(text)
            if match:
                fence = match.group("fence") or match.group("tilde")
                info = match.group("info") if match.group("fence") else match.group("tildeinfo")
                language = LANGUAGE.match(info.strip())
                lua = bool(language) and language.group(0).lower() in LUA
                opening = (match.group("indent"), fence, lua, [])
            continue
        indent, fence, lua, body = opening
        if re.fullmatch(rf" {{0,3}}{re.escape(fence[0])}{{{len(fence)},}}[ \t]*", text):
            if lua:
                blocks.append("".join(body))
            opening = None
        else:
            body.append(line[len(indent):] if line.startswith(indent) else line.lstrip(" "))
    if opening is not None:
        raise ValueError("a fenced code block in the guide has no closing fence")
    return blocks


def run(command, files):
    return subprocess.run([*command, str(DEFINITIONS), *map(str, files)], capture_output=True, text=True)


def check(command, guide=GUIDE, fixtures=FIXTURES, rejections=REJECTIONS):
    problems = []
    with tempfile.TemporaryDirectory() as raw:
        clean = sorted((fixtures / "clean").glob("*.luau"))
        for index, source in enumerate(recipes(guide.read_text()), 1):
            path = Path(raw) / f"{guide.stem}-{index:02}.luau"
            path.write_text(source if source.startswith(STRICT) else f"{STRICT}\n{source}")
            clean.append(path)
        result = run(command, clean)
        if result.returncode != 0 or result.stdout or result.stderr:
            problems.append(f"clean files reported diagnostics (exit {result.returncode}):\n{result.stdout}{result.stderr}")
    rejected = sorted((fixtures / "rejected").glob("*.luau"))
    if sorted(path.name for path in rejected) != sorted(rejections):
        problems.append(f"rejected fixtures {sorted(path.name for path in rejected)} differ from {sorted(rejections)}")
    for path in rejected:
        expected = rejections.get(path.name, "")
        line = len(path.read_text().splitlines())
        result = run(command, [path])
        reported = [text for text in result.stdout.splitlines() if text.startswith(f"{path}:{line}:")]
        if result.returncode != TYPE_ERRORS or not any(expected in text for text in reported):
            problems.append(
                f"{path.name}: expected exit {TYPE_ERRORS} with '{expected}' on line {line}, "
                f"got exit {result.returncode}:\n{result.stdout}{result.stderr}"
            )
    return len(clean), len(rejected), problems


def main(argv):
    checker = Path(argv[1]) if len(argv) > 1 else ROOT / ".cache/flake-tools/bin/luau-check"
    if not checker.is_file():
        print(f"{checker} is missing; run make setup-tools", file=sys.stderr)
        return 1
    clean, rejected, problems = check([str(checker)])
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    print(f"luau-check: {clean} files clean, {rejected} mistakes rejected")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

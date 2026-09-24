#!/usr/bin/env python3
import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOGS = ROOT / "Sources/OmniWM/Resources"
FORMAT = re.compile(
    r"%(?:(\d+)\$)?[-+#0 ']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(hh|ll|h|l|q|z|t|j|L)?([@diuoxXfFeEgGaAcCsSp])"
)
SUBSTITUTION = re.compile(r"%(?:(\d+)\$)?#@([A-Za-z_][A-Za-z_0-9]*)@")
INFO_KEYS = ("NSMicrophoneUsageDescription", "NSScreenCaptureUsageDescription")


def format_type(specifier):
    match = FORMAT.fullmatch("%" + specifier)
    if not match:
        raise ValueError(f"unsupported format specifier: {specifier!r}")
    return (match.group(2) or "") + match.group(3)


def arguments(value, substitutions=None, substitution_type=None):
    substitutions = substitutions or {}
    result = {}
    implicit = 0
    explicit = False
    used_implicit = False
    position = 0
    while position < len(value):
        if value[position] != "%":
            position += 1
            continue
        if value.startswith("%%", position):
            position += 2
            continue
        if substitution_type and value.startswith("%arg", position):
            if position + 4 == len(value) or not value[position + 4].isalnum():
                position += 4
                continue
        named = SUBSTITUTION.match(value, position)
        standard = FORMAT.match(value, position) if not named else None
        match = named or standard
        if not match:
            if position + 1 < len(value) and value[position + 1] not in " \t\n.,:;!?)]}—–-/":
                raise ValueError(f"unsupported format token near {value[position:position + 12]!r}")
            position += 1
            continue
        if "*" in match.group():
            raise ValueError("dynamic format width and precision are unsupported")
        number = match.group(1)
        if number:
            explicit = True
            index = int(number)
            if index < 1:
                raise ValueError("format argument indices start at 1")
        else:
            used_implicit = True
            implicit += 1
            index = implicit
        if named:
            name = match.group(2)
            if name not in substitutions:
                raise ValueError(f"missing substitution definition for {name!r}")
            specifier = substitutions[name].get("formatSpecifier")
            if not isinstance(specifier, str):
                raise ValueError(f"missing format specifier for substitution {name!r}")
            kind = format_type(specifier)
        else:
            kind = (match.group(2) or "") + match.group(3)
        if index in result and result[index] != kind:
            raise ValueError(f"argument {index} has conflicting formats")
        result[index] = kind
        position = match.end()
    if explicit and used_implicit:
        raise ValueError("mixed positional and nonpositional format arguments")
    if substitution_type and result and set(result.values()) != {substitution_type}:
        raise ValueError(f"plural substitution must use {substitution_type}, found {result}")
    return result


def string_units(node, plural=False):
    unit = node.get("stringUnit")
    if isinstance(unit, dict) and isinstance(unit.get("value"), str):
        yield unit["value"], plural
    for kind, variants in node.get("variations", {}).items():
        for branch in variants.values():
            if isinstance(branch, dict):
                yield from string_units(branch, plural or kind == "plural")


def source_arguments(key, source):
    from_key = arguments(key)
    if not source:
        return from_key
    substitutions = source.get("substitutions", {})
    from_source = {}
    units = list(string_units(source))
    for value, _ in units:
        for index, kind in arguments(value, substitutions).items():
            if index in from_source and from_source[index] != kind:
                raise ValueError(f"source argument {index} has conflicting formats")
            from_source[index] = kind
    if from_key:
        if any(plural for _, plural in units):
            valid = set(from_source.items()).issubset(set(from_key.items()))
        else:
            valid = not units or from_source == from_key
        if not valid:
            raise ValueError(f"English source formats {from_source} differ from key formats {from_key}")
        return from_key
    return from_source


def validate_catalog_data(data, label):
    if data.get("sourceLanguage") != "en" or not isinstance(data.get("strings"), dict):
        raise ValueError(f"{label}: expected an English source string catalog")
    for key, entry in data["strings"].items():
        try:
            locales = entry.get("localizations", {})
            expected = source_arguments(key, locales.get("en"))
            for language, localization in locales.items():
                substitutions = localization.get("substitutions", {})
                for value, plural in string_units(localization):
                    actual = arguments(value, substitutions)
                    if plural:
                        valid = set(actual.items()).issubset(set(expected.items()))
                    else:
                        valid = actual == expected
                    if not valid:
                        raise ValueError(
                            f"{language} format {actual} differs from English format {expected} in {value!r}"
                        )
                for name, substitution in substitutions.items():
                    kind = format_type(substitution["formatSpecifier"])
                    for value, _ in string_units(substitution):
                        arguments(value, substitution_type=kind)
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(f"{label}: {key!r}: {error}") from error


def validate_catalogs(catalog_dir=CATALOGS, info_plist=ROOT / "Info.plist"):
    for name in ("Localizable", "Commands", "InfoPlist"):
        path = catalog_dir / f"{name}.xcstrings"
        data = json.loads(path.read_text())
        validate_catalog_data(data, path.name)
        if name == "InfoPlist":
            info = plistlib.loads(info_plist.read_bytes())
            for key in INFO_KEYS:
                english = data["strings"].get(key, {}).get("localizations", {}).get("en", {})
                values = [value for value, _ in string_units(english)]
                if values != [info[key]]:
                    raise ValueError(f"InfoPlist.xcstrings: English {key} must match Info.plist")


def compiler_stringsdata():
    result = subprocess.run(
        ["swift", "build", "--arch", "arm64", "--show-bin-path"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    )
    bin_path = Path(result.stdout.strip())
    intermediates = bin_path.parent.parent / "Intermediates.noindex"
    sources = (ROOT / "Sources/OmniWM", ROOT / "Sources/OmniWMApp")
    found = {}
    for path in intermediates.rglob("*.stringsdata"):
        if bin_path.name not in path.parts or "Objects-normal" not in path.parts or "arm64" not in path.parts:
            continue
        if any("-testable-" in part for part in path.parts):
            continue
        data = json.loads(path.read_text())
        source = Path(data.get("source", "")).resolve()
        if not source.is_file() or not any(source.is_relative_to(root) for root in sources):
            continue
        old = found.get(source)
        if old and old[1] != data:
            raise ValueError(f"conflicting compiler strings metadata for {source}")
        found[source] = (path, data)
    if not found:
        raise ValueError("no OmniWM compiler .stringsdata found; run make build first")
    return [entry[0] for entry in found.values()]


def synchronize(catalog_dir, stringsdata):
    catalogs = [catalog_dir / f"{name}.xcstrings" for name in ("Localizable", "Commands")]
    command = ["xcrun", "xcstringstool", "sync", *map(str, catalogs)]
    for path in stringsdata:
        command.extend(("--stringsdata", str(path)))
    subprocess.run(command, cwd=ROOT, check=True)


def validate_command_defaults(stringsdata):
    commands = json.loads((CATALOGS / "Commands.xcstrings").read_text())["strings"]
    defaults = {}
    for path in stringsdata:
        for entry in json.loads(path.read_text()).get("tables", {}).get("Commands", []):
            if "value" not in entry:
                continue
            key = entry["key"]
            value = entry["value"]
            if key in defaults and defaults[key] != value:
                raise ValueError(f"Commands key {key!r} has conflicting English source values")
            defaults[key] = value
    for key, value in defaults.items():
        english = commands.get(key, {}).get("localizations", {}).get("en", {})
        units = [text for text, _ in string_units(english)]
        if units != [value]:
            raise ValueError(f"Commands.xcstrings: English {key!r} must match source value {value!r}")


def check():
    validate_catalogs()
    stringsdata = compiler_stringsdata()
    validate_command_defaults(stringsdata)
    with tempfile.TemporaryDirectory(prefix="omniwm-localization-") as temporary:
        directory = Path(temporary)
        for name in ("Localizable", "Commands"):
            shutil.copy2(CATALOGS / f"{name}.xcstrings", directory)
        synchronize(directory, stringsdata)
        for name in ("Localizable", "Commands"):
            filename = f"{name}.xcstrings"
            current = json.loads((CATALOGS / filename).read_text())
            extracted = json.loads((directory / filename).read_text())
            if current != extracted:
                added = extracted["strings"].keys() - current["strings"].keys()
                removed = current["strings"].keys() - extracted["strings"].keys()
                raise ValueError(
                    f"{filename} differs from compiler strings metadata "
                    f"({len(added)} added, {len(removed)} removed); run make localization-sync"
                )
    print("Localization catalogs match compiler strings metadata and format arguments")


def package(bundle, app):
    source = bundle / "Contents/Resources"
    target = app / "Contents/Resources"
    if not source.is_dir():
        raise ValueError(f"SwiftPM resource bundle has no Contents/Resources: {bundle}")
    for locale in source.glob("*.lproj"):
        if locale.is_dir():
            shutil.copytree(locale, target / locale.name, dirs_exist_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("check", "sync", "validate", "package"))
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--catalog-dir", type=Path, default=CATALOGS)
    args = parser.parse_args()
    try:
        if args.command == "check":
            check()
        elif args.command == "sync":
            stringsdata = compiler_stringsdata()
            synchronize(CATALOGS, stringsdata)
            validate_catalogs()
            validate_command_defaults(stringsdata)
        elif args.command == "validate":
            validate_catalogs(args.catalog_dir)
        elif args.bundle and args.app:
            package(args.bundle, args.app)
        else:
            parser.error("package requires --bundle and --app")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"localization: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

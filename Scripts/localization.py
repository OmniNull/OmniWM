#!/usr/bin/env python3
import argparse
import json
import os
import plistlib
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOGS = ROOT / "Sources/OmniWM/Resources"
SHELL_WIDGETS = (ROOT / "Sources/OmniWM/ShellDefault", ROOT / "Sources/OmniWM/ShellStyles")
FORMAT = re.compile(
    r"%(?:(\d+)\$)?[-+#0 ']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(hh|ll|h|l|q|z|t|j|L)?([@diuoxXfFeEgGaAcCsSp])"
)
SUBSTITUTION = re.compile(r"%(?:(\d+)\$)?#@([A-Za-z_][A-Za-z_0-9]*)@")
INFO_KEYS = (
    "NSAppleEventsUsageDescription",
    "NSAudioCaptureUsageDescription",
    "NSBluetoothAlwaysUsageDescription",
    "NSCalendarsFullAccessUsageDescription",
    "NSLocationUsageDescription",
    "NSLocationWhenInUseUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSScreenCaptureUsageDescription",
)
CATALOG_NAMES = ("Localizable", "Commands", "InfoPlist", "Shell")
SHELL_KEY = re.compile(r'omniwm\.l10n\(\s*"((?:[^"\\]|\\.)*)"')
PLURAL_CATEGORIES = {
    "ar": {"zero", "one", "two", "few", "many", "other"},
    "da": {"one", "other"},
    "de": {"one", "other"},
    "el": {"one", "other"},
    "en": {"one", "other"},
    "es": {"one", "many", "other"},
    "fi": {"one", "other"},
    "fr": {"one", "many", "other"},
    "he": {"one", "two", "other"},
    "hi": {"one", "other"},
    "it": {"one", "many", "other"},
    "ja": {"other"},
    "ko": {"other"},
    "nb": {"one", "other"},
    "nl": {"one", "other"},
    "pl": {"one", "few", "many", "other"},
    "ru": {"one", "few", "many", "other"},
    "sr-Latn": {"one", "few", "other"},
    "sv": {"one", "other"},
    "uk": {"one", "few", "many", "other"},
    "zh-Hans": {"other"},
}

LOCALIZED_SOURCES = ("Sources/OmniWM", "Sources/OmniWMApp")
LOCALIZED_MODULES = ("OmniWM", "OmniWMApp")
LOCALIZED_TYPES = ("LocalizedStringKey", "LocalizedStringResource", "String.LocalizationValue")
LOCALIZATION_INITIALIZERS = {
    "Foundation.(file).String extension.init(localized:table:bundle:locale:comment:)": ("localized", None, "table"),
    "Foundation.(file).LocalizedStringResource.init(_:table:locale:bundle:comment:)": ("", None, "table"),
    "Foundation.(file).LocalizedStringResource.init(_:defaultValue:table:locale:bundle:comment:)": ("", "defaultValue", "table"),
    "SwiftUICore.(file).Text extension.init(_:tableName:bundle:comment:)": ("", None, "tableName"),
}
LOCALIZATION_LABELS = {"defaultValue", "table", "tableName", "comment"}
INTERPOLATION_SPECIFIERS = {
    "Int": "%lld", "Int64": "%lld", "ClosedRange<Int>.Element": "%lld", "Int32": "%d", "pid_t": "%d",
}
FORMAT_SPECIFIABLE = "generic_signature=<T where T : _FormatSpecifiable> T -> "
AST_TOKEN = re.compile(r'(?:(\w+)=)?("(?:[^"\\]|\\.)*"|\[[^\]]*\]|[^\s()"]+)')
AST_ESCAPE = re.compile(r"\\(u\{([0-9A-Fa-f]+)\}|.)", re.DOTALL)
AST_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}
DUMP_DROPPED_FLAGS = {
    "-c", "-incremental", "-save-temps", "-emit-dependencies", "-emit-module", "-serialize-diagnostics",
    "-emit-objc-header", "-emit-const-values", "-experimental-emit-module-separately",
}
DUMP_DROPPED_OPTIONS = {
    "-output-file-map", "-emit-module-path", "-index-store-path", "-emit-objc-header-path",
    "-const-gather-protocols-list", "-dependency-scan-serialize-diagnostics-path",
}


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


def validate_shell_usage(strings, folders):
    used = set()
    for widget in sorted(widget for folder in folders for widget in folder.rglob("*.luau")):
        used.update(SHELL_KEY.findall(widget.read_text()))
    for manifest in (file for folder in folders for file in folder.rglob("*.toml")
                     if file.name in ("settings.toml", "component.toml")):
        options = tomllib.loads(manifest.read_text(encoding="utf-8")).get("options", {})
        used.update(option.get("title", key) for key, option in options.items())
    missing = sorted(used - strings.keys())
    if missing:
        raise ValueError(f"Shell.xcstrings: bundled widgets use missing keys {missing}")
    unused = sorted(strings.keys() - used)
    if unused:
        raise ValueError(f"Shell.xcstrings: keys no bundled widget uses {unused}")
    plural = sorted(key for key, entry in strings.items()
                    if any(has_plural(node) for node in entry.get("localizations", {}).values()))
    if plural:
        raise ValueError(f"Shell.xcstrings: plural variations are not supported {plural}")


def validate_catalogs(catalog_dir=CATALOGS, info_plist=ROOT / "Info.plist", widgets=SHELL_WIDGETS):
    for name in CATALOG_NAMES:
        path = catalog_dir / f"{name}.xcstrings"
        data = json.loads(path.read_text())
        validate_catalog_data(data, path.name)
        if name == "Shell":
            validate_shell_usage(data["strings"], widgets)
        if name == "InfoPlist":
            info = plistlib.loads(info_plist.read_bytes())
            for key in INFO_KEYS:
                english = data["strings"].get(key, {}).get("localizations", {}).get("en", {})
                values = [value for value, _ in string_units(english)]
                if values != [info[key]]:
                    raise ValueError(f"InfoPlist.xcstrings: English {key} must match Info.plist")


def has_plural(node):
    variations = node.get("variations", {})
    if "plural" in variations:
        return True
    return any(
        has_plural(branch)
        for branches in variations.values()
        for branch in branches.values()
    ) or any(has_plural(substitution) for substitution in node.get("substitutions", {}).values())


def translation_error(node, plural_categories):
    if not isinstance(node, dict):
        return "missing translation"
    unit = node.get("stringUnit")
    variations = node.get("variations", {})
    if unit is None and not variations:
        return "missing translated string"
    if unit is not None and (
        not isinstance(unit, dict)
        or unit.get("state") != "translated"
        or not isinstance(unit.get("value"), str)
        or not unit["value"].strip()
    ):
        return "empty or unreviewed translated string"
    for kind, branches in variations.items():
        if not isinstance(branches, dict) or not branches:
            return f"missing {kind} branches"
        if kind == "plural":
            missing = plural_categories - branches.keys()
            if missing:
                return f"missing plural {sorted(missing)[0]} branch"
        for branch in branches.values():
            error = translation_error(branch, plural_categories)
            if error:
                return error
    for substitution in node.get("substitutions", {}).values():
        error = translation_error(substitution, plural_categories)
        if error:
            return error
    return None


def validate_locale_completeness(catalog_dir, languages):
    problems = []
    for name in CATALOG_NAMES:
        strings = json.loads((catalog_dir / f"{name}.xcstrings").read_text())["strings"]
        for language in languages:
            if language not in PLURAL_CATEGORIES:
                raise ValueError(f"unsupported plural categories for {language}")
            plural_categories = PLURAL_CATEGORIES[language]
            incomplete = []
            for key, entry in strings.items():
                if not key:
                    continue
                locales = entry.get("localizations", {})
                translation = locales.get(language)
                error = translation_error(translation, plural_categories)
                if not error and has_plural(locales.get("en", {})) and not has_plural(translation):
                    error = "missing plural branches"
                if error:
                    incomplete.append(f"{key!r} ({error})")
            if incomplete:
                examples = ", ".join(incomplete[:3])
                problems.append(f"{language} {name}.xcstrings: {len(incomplete)} incomplete; e.g. {examples}")
    if problems:
        raise ValueError("locale completeness failed:\n" + "\n".join(problems))


def swiftly_bin():
    return Path(os.environ.get("SWIFTLY_HOME_DIR") or Path.home() / ".swiftly") / "bin"


def decode_task_store(data):
    sized = {0xC4: (1, False), 0xC5: (2, False), 0xC6: (4, False), 0xD9: (1, True), 0xDA: (2, True), 0xDB: (4, True)}
    containers = {0xDC: (2, False), 0xDD: (4, False), 0xDE: (2, True), 0xDF: (4, True)}

    def items(index, count, is_map):
        values = []
        for _ in range(count * 2 if is_map else count):
            value, index = read(index)
            values.append(value)
        return (dict(zip(values[::2], values[1::2])) if is_map else values), index

    def read(index):
        byte = data[index]
        if byte <= 0x7F:
            return byte, index + 1
        if byte == 0xE0:
            return data[index + 1], index + 2
        if byte <= 0x9F:
            return items(index + 1, byte & 0x0F, byte <= 0x8F)
        if byte <= 0xBF:
            end = index + 1 + (byte & 0x1F)
            return data[index + 1:end].decode(), end
        if byte == 0xC0:
            return None, index + 1
        if byte in (0xC2, 0xC3):
            return byte == 0xC3, index + 1
        if byte in sized:
            width, text = sized[byte]
            start = index + 1 + width
            end = start + int.from_bytes(data[index + 1:start], "big")
            return (data[start:end].decode() if text else bytes(data[start:end])), end
        if byte in (0xCA, 0xCB):
            end = index + (5 if byte == 0xCA else 9)
            return struct.unpack(">f" if byte == 0xCA else ">d", data[index + 1:end])[0], end
        if 0xCC <= byte <= 0xD3:
            end = index + 1 + (1 << ((byte - 0xCC) % 4))
            return int.from_bytes(data[index + 1:end], "big", signed=byte >= 0xD0), end
        if byte in containers:
            width, is_map = containers[byte]
            start = index + 1 + width
            return items(start, int.from_bytes(data[index + 1:start], "big"), is_map)
        raise ValueError(f"unsupported Swift Build task store byte 0x{byte:02x} at offset {index}")

    value, end = read(0)
    if end != len(data):
        raise ValueError(f"Swift Build task store has {len(data) - end} unread bytes")
    return value


def driver_arguments(scratch, module):
    stores = sorted(
        (scratch / "out/Intermediates.noindex/XCBuildData").glob("*.xcbuilddata/task-store.msgpack"),
        key=lambda path: path.parent.stat().st_mtime,
    )
    if not stores:
        raise ValueError(f"no Swift Build task store in {scratch}")
    matches = []
    for task in decode_task_store(stores[-1].read_bytes()):
        if len(task) != 25 or not isinstance(task[4], list) or task[4][:1] != ["SwiftDriver Compilation"]:
            continue
        arguments = [value.decode() if isinstance(value, bytes) else value for _, value in task[6]]
        if "-module-name" in arguments and arguments[arguments.index("-module-name") + 1] == module:
            matches.append((arguments, task[9]))
    if len(matches) != 1:
        raise ValueError(f"expected one Swift compilation of {module} in {stores[-1]}, found {len(matches)}")
    arguments, directory = matches[0]
    if arguments[1:2] != ["--"] or not arguments[2].endswith("/swiftc"):
        raise ValueError(f"unexpected Swift compilation command for {module}: {arguments[:3]}")
    return arguments[2:], directory


def dump_syntax_trees(arguments, directory, output, environment):
    options = iter(arguments[1:])
    kept = []
    for option in options:
        if option in DUMP_DROPPED_OPTIONS:
            next(options)
        elif option not in DUMP_DROPPED_FLAGS:
            kept.append(option)
    file_list = next((option[1:] for option in kept if option.startswith("@") and option.endswith(".SwiftFileList")), None)
    if file_list is None:
        raise ValueError("Swift compilation command has no source file list")
    output.mkdir(parents=True)
    dumps = {source: output / f"{index}.ast" for index, source in enumerate(shlex.split(Path(file_list).read_text()))}
    output_map = output / "output-file-map.json"
    output_map.write_text(json.dumps({source: {"ast-dump": str(dump)} for source, dump in dumps.items()}))
    subprocess.run([arguments[0], *kept, "-dump-ast", "-output-file-map", str(output_map)], cwd=directory, check=True, env=environment)
    return {Path(source).resolve(): dump for source, dump in dumps.items()}


class SyntaxNode:
    __slots__ = ("kind", "role", "text", "children")

    def __init__(self, text):
        self.role, _, self.kind = text[1:].split(" ", 1)[0].rstrip(")").rpartition("=")
        self.text = text
        self.children = []

    def attribute(self, name):
        for match in AST_TOKEN.finditer(self.text):
            if match.group(1) == name:
                value = match.group(2)
                return unescape_ast(value[1:-1]) if value.startswith('"') else value
        return None


def unescape_ast(text):
    def replace(match):
        if match.group(2):
            return chr(int(match.group(2), 16))
        if match.group(1) not in AST_ESCAPES:
            raise ValueError(f"unsupported escape \\{match.group(1)} in compiler AST string {text!r}")
        return AST_ESCAPES[match.group(1)]
    return AST_ESCAPE.sub(replace, text)


def parse_syntax_tree(text):
    roots = []
    stack = []
    for line in text.split("\n"):
        stripped = line.lstrip(" ")
        if not stripped.startswith("("):
            if stripped.strip(" )"):
                raise ValueError(f"unexpected compiler AST line: {line[:120]!r}")
            continue
        node = SyntaxNode(stripped)
        depth = len(line) - len(stripped)
        while stack and stack[-1][0] >= depth:
            stack.pop()
        (stack[-1][1].children if stack else roots).append(node)
        stack.append((depth, node))
    return roots


def walk(nodes):
    for node in nodes:
        if node.role != "original_init":
            yield node
            yield from walk(node.children)


def unwrap(node):
    while node.kind in ("inject_into_optional", "paren_expr") and node.children:
        node = node.children[0]
    return node


def is_localized(node):
    return node.kind in ("string_literal_expr", "interpolated_string_literal_expr") and node.attribute("type") in LOCALIZED_TYPES


def source_location(node):
    _, line, column = node.attribute("location").rsplit(":", 2)
    return int(line), int(column)


def call_parts(call):
    arguments = next((child for child in call.children[1:] if child.kind == "argument_list"), None)
    return (call.children[0] if call.children else None), arguments


def declaration(node):
    return next((child.attribute("decl") for child in walk([node]) if child.kind == "declref_expr" and child.attribute("decl")), None)


def literal_value(node):
    node = unwrap(node)
    if node.kind == "default_argument_expr":
        return None
    if node.kind != "string_literal_expr":
        raise ValueError(f"expected a string literal, found {node.kind} at {node.attribute('location')}")
    return node.attribute("value")


def interpolation_specifier(call):
    function, arguments = call_parts(call)
    reference = next(node for node in walk([function]) if node.kind == "declref_expr")
    decl = reference.attribute("decl")
    if "appendInterpolation(_:specifier:)" in decl:
        return literal_value(next(argument for argument in arguments.children if argument.attribute("label") == "specifier").children[0])
    if FORMAT_SPECIFIABLE in decl:
        spelled = decl.split(FORMAT_SPECIFIABLE, 1)[1].removesuffix(")]")
        if spelled not in INTERPOLATION_SPECIFIERS:
            raise ValueError(f"no format specifier for interpolated {spelled}; add it to INTERPOLATION_SPECIFIERS")
        return INTERPOLATION_SPECIFIERS[spelled]
    if reference.attribute("type").endswith("StringInterpolation) -> (String) -> ()"):
        return "%@"
    raise ValueError(f"unsupported localized interpolation {decl} of type {reference.attribute('type')}")


def localized_text(literal):
    if literal.kind == "string_literal_expr":
        return literal.attribute("value")
    if literal.kind != "interpolated_string_literal_expr":
        raise ValueError(f"expected a localized literal, found {literal.kind} at {literal.attribute('location')}")
    body = next(node for node in walk(literal.children) if node.kind == "brace_stmt")
    parts = []
    for call in body.children:
        if call.kind != "call_expr":
            continue
        function, arguments = call_parts(call)
        if declaration(function).endswith(".appendLiteral"):
            parts.append(literal_value(arguments.children[0].children[0]).replace("%", "%%"))
        else:
            parts.append(interpolation_specifier(call))
    return "".join(parts)


def localized_strings(dump):
    text = dump.read_bytes().decode()
    if not any(name in text for name in LOCALIZED_TYPES):
        return {}
    roots = parse_syntax_tree(text)
    entries = {}
    consumed = set()
    for call in walk(roots):
        function, arguments = call_parts(call) if call.kind == "call_expr" else (None, None)
        if function is None or function.kind != "constructor_ref_call_expr" or arguments is None:
            continue
        labeled = {
            argument.attribute("label") or "": unwrap(argument.children[0])
            for argument in arguments.children if argument.kind == "argument" and argument.children
        }
        roles = LOCALIZATION_INITIALIZERS.get(declaration(function))
        if roles is None:
            if LOCALIZATION_LABELS & labeled.keys() and any(map(is_localized, labeled.values())):
                raise ValueError(f"unsupported localization initializer {declaration(function)}")
            continue
        key_label, value_label, table_label = roles
        key = labeled[key_label]
        value = labeled[value_label] if value_label else None
        if value is None and not is_localized(key):
            continue
        line, column = source_location(key)
        consumed.update(source_location(node) for node in (key, value) if node is not None)
        table = literal_value(labeled[table_label]) if table_label in labeled else None
        comment = literal_value(labeled["comment"]) if "comment" in labeled else None
        entry = {"comment": comment or "", "key": localized_text(key), "location": {"startingColumn": column, "startingLine": line}}
        if value is not None:
            entry["value"] = localized_text(value)
        entries[(table or "Localizable", line, column)] = entry
    for literal in walk(roots):
        if is_localized(literal) and source_location(literal) not in consumed:
            line, column = source_location(literal)
            entries.setdefault(("Localizable", line, column), {
                "comment": "", "key": localized_text(literal), "location": {"startingColumn": column, "startingLine": line},
            })
    tables = {}
    for (table, _, _), entry in sorted(entries.items()):
        tables.setdefault(table, []).append(entry)
    return tables


def compiler_stringsdata():
    library_dir = subprocess.run(
        [str(ROOT / "Scripts/ghostty-preflight.sh"), "print-library-dir"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.strip()
    environment = os.environ.copy()
    library_path = environment.get("LIBRARY_PATH")
    environment["LIBRARY_PATH"] = library_dir + (f":{library_path}" if library_path else "")
    scratch = ROOT / ".build/localization"
    subprocess.run([
        str(swiftly_bin() / "swift"), "build",
        "--build-system", "swiftbuild", "--arch", "arm64",
        "--configuration", "debug", "--product", "OmniWM",
        "--scratch-path", str(scratch),
    ], cwd=ROOT, check=True, env=environment)
    output = scratch / "strings"
    shutil.rmtree(output, ignore_errors=True)
    sources = tuple(ROOT / path for path in LOCALIZED_SOURCES)
    stringsdata = []
    for module in LOCALIZED_MODULES:
        arguments, directory = driver_arguments(scratch, module)
        for source, dump in dump_syntax_trees(arguments, directory, output / module, environment).items():
            tables = localized_strings(dump) if any(source.is_relative_to(root) for root in sources) else {}
            if tables:
                path = output / f"{len(stringsdata)}-{source.stem}.stringsdata"
                path.write_text(json.dumps({"source": str(source), "tables": tables, "version": 1}, ensure_ascii=False))
                stringsdata.append(path)
        shutil.rmtree(output / module)
    if not stringsdata:
        raise ValueError("compiler AST produced no OmniWM localized strings")
    return stringsdata


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
    parser.add_argument("command", choices=("check", "sync", "validate", "completeness", "package"))
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--catalog-dir", type=Path, default=CATALOGS)
    parser.add_argument("--locales", nargs="+", metavar="LOCALE")
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
        elif args.command == "completeness":
            if not args.locales:
                parser.error("completeness requires --locales LOCALE [LOCALE ...]")
            validate_locale_completeness(args.catalog_dir, args.locales)
            print(f"Complete translations for {', '.join(args.locales)} in all catalogs")
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

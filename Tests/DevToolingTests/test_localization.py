import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/localization.py"
SPEC = importlib.util.spec_from_file_location("localization", SCRIPT)
localization = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(localization)
FIXTURE = Path(__file__).resolve().parent / "Fixtures/localization-sample.ast"


def pack(value):
    if value is None:
        return b"\xc0"
    if isinstance(value, bool):
        return b"\xc3" if value else b"\xc2"
    if isinstance(value, int):
        return bytes([value]) if value < 0x80 else b"\xe0" + bytes([value])
    if isinstance(value, bytes):
        return b"\xc4" + bytes([len(value)]) + value
    if isinstance(value, str):
        return b"\xd9" + bytes([len(value.encode())]) + value.encode()
    if isinstance(value, dict):
        return b"\xde" + len(value).to_bytes(2, "big") + b"".join(pack(key) + pack(item) for key, item in value.items())
    return b"\xdc" + len(value).to_bytes(2, "big") + b"".join(map(pack, value))


def task(rule, arguments, directory="/work"):
    fields = [None] * 25
    fields[4] = rule
    fields[6] = [[0, argument.encode()] if index % 2 else [1, argument] for index, argument in enumerate(arguments)]
    fields[9] = directory
    return fields


def write_store(scratch, tasks, name="current"):
    store = scratch / f"out/Intermediates.noindex/XCBuildData/{name}.xcbuilddata/task-store.msgpack"
    store.parent.mkdir(parents=True)
    store.write_bytes(pack(tasks))
    return store


def catalog(key, translations, english=None):
    localizations = dict(translations)
    if english is not None:
        localizations["en"] = english
    return {"sourceLanguage": "en", "strings": {key: {"localizations": localizations}}, "version": "1.0"}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


class LocalizationTests(unittest.TestCase):
    def test_wrong_object_placeholder_is_rejected(self):
        data = catalog("%lld windows", {"fr": unit("%@ fenêtres")})
        with self.assertRaisesRegex(ValueError, r"fr format.*lld"):
            localization.validate_catalog_data(data, "Localizable.xcstrings")

    def test_positional_reorder_and_escaped_percent_are_allowed(self):
        data = catalog("%lld of %@, 100%%", {"fr": unit("%2$@ : %1$lld, 100%%")})
        localization.validate_catalog_data(data, "Localizable.xcstrings")

    def test_plural_branch_cannot_change_count_type(self):
        plural = {
            "variations": {
                "plural": {"one": unit("Un fichier"), "other": unit("%1$@ fichiers")}
            }
        }
        data = catalog("%lld files", {"fr": plural})
        with self.assertRaisesRegex(ValueError, r"fr format.*lld"):
            localization.validate_catalog_data(data, "Localizable.xcstrings")
        plural["variations"]["plural"]["other"] = unit("%1$lld fichiers")
        localization.validate_catalog_data(data, "Localizable.xcstrings")

    def test_plural_substitution_format_is_checked(self):
        source = {
            **unit("Compressing %#@items@"),
            "substitutions": {
                "items": {
                    "formatSpecifier": "lld",
                    "variations": {"plural": {"one": unit("%arg item"), "other": unit("%arg items")}},
                }
            },
        }
        translated = {
            **unit("Compression de %#@items@"),
            "substitutions": {
                "items": {
                    "formatSpecifier": "@",
                    "variations": {"plural": {"one": unit("%arg fichier"), "other": unit("%arg fichiers")}},
                }
            },
        }
        data = catalog("Compressing %lld items", {"fr": translated}, source)
        with self.assertRaisesRegex(ValueError, r"fr format.*lld"):
            localization.validate_catalog_data(data, "Localizable.xcstrings")
        translated["substitutions"]["items"]["formatSpecifier"] = "lld"
        localization.validate_catalog_data(data, "Localizable.xcstrings")

    def test_compiler_metadata_synchronizes_catalog_with_original_filename(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plural = {
                "localizations": {
                    "en": {
                        "variations": {
                            "plural": {
                                "one": unit("%1$lld window"),
                                "other": unit("%1$lld windows"),
                            }
                        }
                    }
                }
            }
            for name in ("Localizable", "Commands"):
                (root / f"{name}.xcstrings").write_text(
                    json.dumps({
                        "sourceLanguage": "en",
                        "strings": {"%lld windows": plural} if name == "Localizable" else {},
                        "version": "1.0",
                    })
                )
            metadata = root / "Example.stringsdata"
            metadata.write_text(json.dumps({
                "source": str(root / "Example.swift"),
                "tables": {"Localizable": [
                    {"comment": "", "key": "New command"},
                    {"comment": "", "key": "%lld windows"},
                ]},
                "version": 1,
            }))
            localization.synchronize(root, [metadata])
            synced = json.loads((root / "Localizable.xcstrings").read_text())
            self.assertIn("New command", synced["strings"])
            self.assertEqual(synced["strings"]["%lld windows"], plural)

    def test_info_plist_catalog_tracks_permission_text(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            info = {key: f"English {key}" for key in localization.INFO_KEYS}
            plist = root / "Info.plist"
            plist.write_bytes(plistlib.dumps(info))
            empty = {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
            for name in ("Localizable", "Commands", "Shell"):
                (root / f"{name}.xcstrings").write_text(json.dumps(empty))
            strings = {
                key: {"localizations": {"en": unit(value)}} for key, value in info.items()
            }
            catalog_path = root / "InfoPlist.xcstrings"
            catalog_path.write_text(json.dumps({**empty, "strings": strings}))
            localization.validate_catalogs(root, plist, widgets=(root,))
            strings[localization.INFO_KEYS[0]]["localizations"]["en"] = unit("Wrong text")
            catalog_path.write_text(json.dumps({**empty, "strings": strings}))
            with self.assertRaisesRegex(ValueError, "must match Info.plist"):
                localization.validate_catalogs(root, plist, widgets=(root,))

    def test_command_english_value_matches_compiler_default(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            commands = root / "Commands.xcstrings"
            strings = {"command.focus.left": {"localizations": {"en": unit("Focus Left")}}}
            commands.write_text(json.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.0"}))
            metadata = root / "Example.stringsdata"
            metadata.write_text(json.dumps({
                "tables": {"Commands": [{"key": "command.focus.left", "value": "Focus Left"}]}
            }))
            with patch.object(localization, "CATALOGS", root):
                localization.validate_command_defaults([metadata])
                strings["command.focus.left"]["localizations"]["en"] = unit("Edited Title")
                commands.write_text(json.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.0"}))
                with self.assertRaisesRegex(ValueError, "must match source value"):
                    localization.validate_command_defaults([metadata])

    def test_completeness_requires_every_nonempty_key_in_each_catalog(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            entries = {
                "Localizable": {"": {}, "Open": {"localizations": {"fr": unit("Ouvrir")}}},
                "Commands": {"command.open": {"localizations": {"fr": unit("Ouvrir")}}},
                "InfoPlist": {"NSMicrophoneUsageDescription": {"localizations": {"fr": unit("Microphone")}}},
                "Shell": {"Wind %@": {"localizations": {"fr": unit("Vent %@")}}},
            }
            for name, strings in entries.items():
                (root / f"{name}.xcstrings").write_text(json.dumps({"strings": strings}))
            localization.validate_locale_completeness(root, ["fr"])
            for name, key in (("Localizable", "Open"), ("Commands", "command.open"),
                              ("InfoPlist", "NSMicrophoneUsageDescription"), ("Shell", "Wind %@")):
                translated = entries[name][key]["localizations"].pop("fr")
                (root / f"{name}.xcstrings").write_text(json.dumps({"strings": entries[name]}))
                with self.assertRaisesRegex(ValueError, rf"fr {name}.xcstrings: 1 incomplete"):
                    localization.validate_locale_completeness(root, ["fr"])
                entries[name][key]["localizations"]["fr"] = translated
                (root / f"{name}.xcstrings").write_text(json.dumps({"strings": entries[name]}))

    def test_completeness_checks_translated_values_and_plural_branches(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plural = {"variations": {"plural": {"one": unit("%1$lld fenêtre"),
                                                 "many": unit("%1$lld fenêtres"),
                                                 "other": unit("%1$lld fenêtres")}}}
            strings = {"%lld windows": {"localizations": {
                "en": {"variations": {"plural": {"one": unit("%1$lld window"),
                                                      "other": unit("%1$lld windows")}}},
                "fr": plural,
            }}}
            (root / "Localizable.xcstrings").write_text(json.dumps({"strings": strings}))
            for name in ("Commands", "InfoPlist", "Shell"):
                (root / f"{name}.xcstrings").write_text(json.dumps({"strings": {}}))
            localization.validate_locale_completeness(root, ["fr"])

            plural["variations"]["plural"].pop("one")
            (root / "Localizable.xcstrings").write_text(json.dumps({"strings": strings}))
            with self.assertRaisesRegex(ValueError, "missing plural one branch"):
                localization.validate_locale_completeness(root, ["fr"])
            plural["variations"]["plural"]["one"] = unit("%1$lld fenêtre")

            plural["variations"]["plural"]["one"] = unit("  ")
            (root / "Localizable.xcstrings").write_text(json.dumps({"strings": strings}))
            with self.assertRaisesRegex(ValueError, "empty or unreviewed translated string"):
                localization.validate_locale_completeness(root, ["fr"])

            plural["variations"]["plural"]["one"] = {"stringUnit": {"state": "needs_review", "value": "Fenêtre"}}
            (root / "Localizable.xcstrings").write_text(json.dumps({"strings": strings}))
            with self.assertRaisesRegex(ValueError, "empty or unreviewed translated string"):
                localization.validate_locale_completeness(root, ["fr"])

            plural["variations"]["plural"].pop("other")
            (root / "Localizable.xcstrings").write_text(json.dumps({"strings": strings}))
            with self.assertRaisesRegex(ValueError, "missing plural other branch"):
                localization.validate_locale_completeness(root, ["fr"])

            strings["%lld windows"]["localizations"]["fr"] = unit("%lld fenêtres")
            (root / "Localizable.xcstrings").write_text(json.dumps({"strings": strings}))
            with self.assertRaisesRegex(ValueError, "missing plural branches"):
                localization.validate_locale_completeness(root, ["fr"])

            strings["%lld windows"]["localizations"]["ja"] = {
                "variations": {"plural": {"other": unit("%1$lld 件のウィンドウ")}}
            }
            (root / "Localizable.xcstrings").write_text(json.dumps({"strings": strings}))
            localization.validate_locale_completeness(root, ["ja"])

    def test_shell_catalog_must_match_bundled_widget_keys(self):
        with tempfile.TemporaryDirectory() as temporary:
            widgets = Path(temporary)
            (widgets / "widget-weather.luau").write_text('ui.text{ text = omniwm.l10n("Wind %@", speed) }')
            strings = {"Wind %@": {"localizations": {"en": unit("Wind %@")}}}
            localization.validate_shell_usage(strings, (widgets,))
            with self.assertRaisesRegex(ValueError, "keys no bundled widget uses"):
                localization.validate_shell_usage({**strings, "Rain": {}}, (widgets,))
            with self.assertRaisesRegex(ValueError, "use missing keys"):
                localization.validate_shell_usage({}, (widgets,))
            plural = {"variations": {"plural": {"one": unit("%lld"), "other": unit("%lld")}}}
            with self.assertRaisesRegex(ValueError, "plural variations"):
                localization.validate_shell_usage({"Wind %@": {"localizations": {"en": plural}}}, (widgets,))

    def test_shell_catalog_tracks_titles_from_both_widget_manifests(self):
        with tempfile.TemporaryDirectory() as temporary:
            widgets = Path(temporary)
            (widgets / "settings.toml").write_text(
                '[options.date]\ntype = "boolean"\ntitle = "Show date"\n[options.label]\ntype = "string"\n'
            )
            (widgets / "component.toml").write_text(
                '[options.width]\ntype = "number"\ntitle = "展开宽度"\n', encoding="utf-8"
            )
            titles = ("Show date", "展开宽度", "label")
            for missing in titles:
                with self.subTest(missing=missing):
                    strings = {key: {} for key in titles if key != missing}
                    with self.assertRaisesRegex(ValueError, missing):
                        localization.validate_shell_usage(strings, (widgets,))
            localization.validate_shell_usage(dict.fromkeys(titles, {}), (widgets,))

    def test_packaging_places_locales_in_main_app_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "OmniWM_OmniWM.bundle"
            source = bundle / "Contents/Resources/fr.lproj"
            source.mkdir(parents=True)
            (source / "Localizable.strings").write_text('"Open" = "Ouvrir";')
            (source / "InfoPlist.strings").write_text('"NSMicrophoneUsageDescription" = "Microphone";')
            app = root / "OmniWM.app"
            (app / "Contents/Resources").mkdir(parents=True)
            localization.package(bundle, app)
            copied = app / "Contents/Resources/fr.lproj/Localizable.strings"
            self.assertEqual(copied.read_text(), '"Open" = "Ouvrir";')
            self.assertTrue((app / "Contents/Resources/fr.lproj/InfoPlist.strings").is_file())


class CompilerMetadataTests(unittest.TestCase):
    def test_task_store_decoding_follows_swift_build_encoding(self):
        data = pack([None, True, False, 5, 200, b"\x01", "text", {"key": [1]}]) + b""
        self.assertEqual(
            localization.decode_task_store(data),
            [None, True, False, 5, 200, b"\x01", "text", {"key": [1]}],
        )
        self.assertEqual(localization.decode_task_store(b"\xd1\xff\xfe"), -2)
        self.assertEqual(localization.decode_task_store(b"\xcb?\xf8\x00\x00\x00\x00\x00\x00"), 1.5)
        with self.assertRaisesRegex(ValueError, "unread bytes"):
            localization.decode_task_store(b"\x01\x02")
        with self.assertRaisesRegex(ValueError, "unsupported Swift Build task store byte 0xc1"):
            localization.decode_task_store(b"\xc1")

    def test_driver_arguments_select_the_module_compilation(self):
        with tempfile.TemporaryDirectory() as temporary:
            scratch = Path(temporary)
            swiftc = "/toolchain/usr/bin/swiftc"
            write_store(scratch, [
                task(["SwiftDriver Compilation Requirements", "OmniWM"], ["builtin", "--", swiftc, "-module-name", "OmniWM"]),
                task(["SwiftDriver Compilation", "OmniWM"], ["builtin", "--", swiftc, "-module-name", "OmniWMApp"], "/app"),
                task(["SwiftDriver Compilation", "OmniWM"], ["builtin", "--", swiftc, "-module-name", "OmniWM", "-g"], "/core"),
            ])
            self.assertEqual(
                localization.driver_arguments(scratch, "OmniWM"),
                ([swiftc, "-module-name", "OmniWM", "-g"], "/core"),
            )
            self.assertEqual(localization.driver_arguments(scratch, "OmniWMApp")[1], "/app")
            with self.assertRaisesRegex(ValueError, "expected one Swift compilation of OmniWMShellCore"):
                localization.driver_arguments(scratch, "OmniWMShellCore")

    def test_driver_arguments_follow_the_most_recently_used_build_description(self):
        with tempfile.TemporaryDirectory() as temporary:
            scratch = Path(temporary)
            swiftc = "/toolchain/usr/bin/swiftc"
            reused = write_store(scratch, [
                task(["SwiftDriver Compilation", "OmniWM"], ["builtin", "--", swiftc, "-module-name", "OmniWM"], "/reused"),
            ], "reused")
            newer = write_store(scratch, [
                task(["SwiftDriver Compilation", "OmniWM"], ["builtin", "--", swiftc, "-module-name", "OmniWM"], "/newer"),
            ], "newer")
            os.utime(reused, (100, 100))
            os.utime(newer, (200, 200))
            os.utime(newer.parent, (300, 300))
            os.utime(reused.parent, (400, 400))
            self.assertEqual(localization.driver_arguments(scratch, "OmniWM")[1], "/reused")

    def test_dump_keeps_semantic_options_and_replaces_build_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            sources = [root / "Sources/OmniWM/A.swift", root / "Sources/OmniWM/B C.swift"]
            file_list = root / "OmniWM.SwiftFileList"
            file_list.write_text(f"{sources[0]}\n'{sources[1]}'\n")
            arguments = [
                "/toolchain/swiftc", "-module-name", "OmniWM", f"@{file_list}", "-DDEBUG", "-c",
                "-output-file-map", "/build/map.json", "-emit-module", "-emit-module-path", "/build/OmniWM.swiftmodule",
                "-index-store-path", "/build/index", "-j14", "-explicit-module-build",
            ]
            output = root / "dumps"
            with patch.object(localization.subprocess, "run") as run:
                dumps = localization.dump_syntax_trees(arguments, "/work", output, {"PATH": "/bin"})
            self.assertEqual(run.call_args.args[0], [
                "/toolchain/swiftc", "-module-name", "OmniWM", f"@{file_list}", "-DDEBUG", "-j14",
                "-explicit-module-build", "-dump-ast", "-output-file-map", str(output / "output-file-map.json"),
            ])
            self.assertEqual(run.call_args.kwargs, {"cwd": "/work", "check": True, "env": {"PATH": "/bin"}})
            self.assertEqual(json.loads((output / "output-file-map.json").read_text()), {
                str(sources[0]): {"ast-dump": str(output / "0.ast")},
                str(sources[1]): {"ast-dump": str(output / "1.ast")},
            })
            self.assertEqual(dumps, {sources[0]: output / "0.ast", sources[1]: output / "1.ast"})

    def test_localized_strings_follow_initializer_roles_and_interpolation_types(self):
        tables = localization.localized_strings(FIXTURE)
        summary = {
            table: [(entry["key"], entry.get("value"), entry["comment"]) for entry in entries]
            for table, entries in tables.items()
        }
        self.assertEqual(summary, {
            "Commands": [
                ("Title", None, "Window title"),
                ("command.sample", "Run %lld Sample", ""),
                ("Shared", None, ""),
                ("Header", None, "Header comment"),
            ],
            "Localizable": [
                ("Count %lld for %@ at 50%%", None, ""),
                ("On", None, ""),
                ("Off", None, ""),
                ("50%", None, ""),
                ("Process %d", None, ""),
                ("Ratio %lld", None, ""),
                ("Wrapped resource", None, ""),
            ],
        })
        self.assertEqual(tables["Commands"][1]["location"], {"startingColumn": 43, "startingLine": 9})

    def test_unknown_interpolation_types_and_initializers_fail(self):
        text = FIXTURE.read_bytes().decode()
        with tempfile.TemporaryDirectory() as temporary:
            dump = Path(temporary) / "sample.ast"
            dump.write_bytes(text.replace("T -> pid_t)]", "T -> UInt8)]").encode())
            with self.assertRaisesRegex(ValueError, "no format specifier for interpolated UInt8"):
                localization.localized_strings(dump)
            dump.write_bytes(text.replace(
                "Text extension.init(_:tableName:bundle:comment:)", "Text extension.init(_:tableName:bundle:comment:variant:)",
            ).encode())
            with self.assertRaisesRegex(ValueError, "unsupported localization initializer"):
                localization.localized_strings(dump)

    def test_swiftly_bin_follows_swiftly_home(self):
        default = Path.home() / ".swiftly/bin"
        for home, expected in ((None, default), ("", default), ("/custom swiftly", Path("/custom swiftly/bin"))):
            with self.subTest(home=home), patch.dict("os.environ", {"SWIFTLY_HOME_DIR": home or ""}):
                if home is None:
                    os.environ.pop("SWIFTLY_HOME_DIR")
                self.assertEqual(localization.swiftly_bin(), expected)

    def extraction(self, root, localized):
        scratch = root / ".build/localization"
        source = root / "Sources/OmniWM/Sample.swift"
        files = {
            "OmniWM": [scratch / "DerivedSources/resource_bundle_accessor.swift", source],
            "OmniWMApp": [root / "Sources/OmniWMApp/App.swift"],
        }
        tasks = []
        for module, paths in files.items():
            file_list = root / f"{module}.SwiftFileList"
            file_list.write_text("\n".join(map(str, paths)))
            arguments = ["builtin", "--", "/toolchain/usr/bin/swiftc", "-module-name", module, f"@{file_list}", "-c"]
            tasks.append(task(["SwiftDriver Compilation", module], arguments, str(root)))
        write_store(scratch, tasks)
        library = root / "Frameworks/GhosttyKit.xcframework/macos-arm64"
        calls = []

        def run(arguments, **kwargs):
            calls.append(arguments)
            self.assertEqual(kwargs["check"], True)
            if arguments[0].endswith("ghostty-preflight.sh"):
                return subprocess.CompletedProcess(arguments, 0, stdout=f"{library}\n")
            self.assertEqual(kwargs["env"]["LIBRARY_PATH"], f"{library}:/existing/libraries")
            if arguments[1] != "build":
                self.assertEqual(kwargs["cwd"], str(root))
                for path, outputs in json.loads(Path(arguments[-1]).read_text()).items():
                    dump = FIXTURE.read_bytes() if localized and path == str(source) else b'(source_file "x")\n'
                    Path(outputs["ast-dump"]).write_bytes(dump)
            return subprocess.CompletedProcess(arguments, 0)

        with patch.object(localization, "ROOT", root), \
                patch.dict("os.environ", {"LIBRARY_PATH": "/existing/libraries", "SWIFTLY_HOME_DIR": "/custom swiftly"}), \
                patch.object(localization.subprocess, "run", side_effect=run):
            return localization.compiler_stringsdata(), calls, source

    def test_extraction_builds_with_swiftly_then_dumps_each_module(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            found, calls, source = self.extraction(root, localized=True)
            self.assertEqual(calls[1], [
                "/custom swiftly/bin/swift", "build", "--build-system", "swiftbuild", "--arch", "arm64",
                "--configuration", "debug", "--product", "OmniWM", "--scratch-path", str(root / ".build/localization"),
            ])
            self.assertEqual([call[0] for call in calls[2:]], ["/toolchain/usr/bin/swiftc"] * 2)
            self.assertEqual(len(found), 1)
            data = json.loads(found[0].read_text())
            self.assertEqual(data["source"], str(source))
            self.assertEqual([entry["key"] for entry in data["tables"]["Commands"]], ["Title", "command.sample", "Shared", "Header"])
            self.assertFalse((root / ".build/localization/strings/OmniWM").exists())

    def test_extraction_without_localized_strings_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "compiler AST produced no OmniWM localized strings"):
                self.extraction(Path(temporary).resolve(), localized=False)

    def test_build_failure_stops_before_dumping(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            failure = subprocess.CalledProcessError(1, ["swift", "build"])
            with patch.object(localization, "ROOT", root), \
                    patch.object(localization.subprocess, "run", side_effect=[
                        subprocess.CompletedProcess([], 0, stdout="/ghostty\n"), failure,
                    ]) as run:
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    localization.compiler_stringsdata()
            self.assertIs(raised.exception, failure)
            self.assertEqual(run.call_count, 2)


if __name__ == "__main__":
    unittest.main()

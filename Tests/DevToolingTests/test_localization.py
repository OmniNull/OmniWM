import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/localization.py"
SPEC = importlib.util.spec_from_file_location("localization", SCRIPT)
localization = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(localization)


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
            for name in ("Localizable", "Commands"):
                (root / f"{name}.xcstrings").write_text(json.dumps(empty))
            strings = {
                key: {"localizations": {"en": unit(value)}} for key, value in info.items()
            }
            catalog_path = root / "InfoPlist.xcstrings"
            catalog_path.write_text(json.dumps({**empty, "strings": strings}))
            localization.validate_catalogs(root, plist)
            strings[localization.INFO_KEYS[0]]["localizations"]["en"] = unit("Wrong text")
            catalog_path.write_text(json.dumps({**empty, "strings": strings}))
            with self.assertRaisesRegex(ValueError, "must match Info.plist"):
                localization.validate_catalogs(root, plist)

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
            }
            for name, strings in entries.items():
                (root / f"{name}.xcstrings").write_text(json.dumps({"strings": strings}))
            localization.validate_locale_completeness(root, ["fr"])
            for name, key in (("Localizable", "Open"), ("Commands", "command.open"),
                              ("InfoPlist", "NSMicrophoneUsageDescription")):
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
            for name in ("Commands", "InfoPlist"):
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


if __name__ == "__main__":
    unittest.main()

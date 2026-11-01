from pathlib import Path
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/ci_test_plan.py"
SPEC = importlib.util.spec_from_file_location("ci_test_plan", SCRIPT)
plan_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(plan_module)

SUITES = {
    "AlphaTests.swift": "final class AlphaTests: XCTestCase {\n    private struct Fixture {}\n}\n"
                        "struct AlphaHarness {}\n",
    "BetaTests.swift": "@MainActor\nfinal class BetaTests: XCTestCase {\n    let harness = AlphaHarness()\n}\n",
    "GammaTests.swift": "final class GammaTests: XCTestCase {\n    private struct Fixture {}\n}\nprivate func local() {}\n",
    "GammaTests+Extra.swift": "extension GammaTests {\n    func extra() {}\n}\n",
    "DeltaTests.swift": "final class DeltaTests: GammaBase {}\nclass GammaBase: XCTestCase {}\n",
    "EpsilonTests.swift": "final class EpsilonTests: XCTestCase {}\nprivate extension String {}\n",
    "Helpers.swift": "import XCTest\n\nfunc helper() {}\n",
    "ShellGlassSceneTests.swift": "final class ShellGlassSceneTests: XCTestCase {}\n",
    "ShellGlassRimTests.swift": "final class ShellGlassRimTests: XCTestCase {\n    let scene = ShellGlassSceneTests()\n}\n",
    "ShellVitreusBarTests.swift": "final class ShellVitreusBarTests: XCTestCase {\n    let scene = ShellGlassSceneTests()\n}\n",
    "ShellThemeTests.swift": "final class ShellThemeTests: XCTestCase {\n    let scene = ShellGlassSceneTests()\n}\n",
    "ZetaTests.swift": "final class ZetaTests: XCTestCase {}\nextension ZetaTests: CustomStringConvertible {}\n",
    "PreviewSupport.swift": "struct PreviewFixture {}\nfunc makePreviewFrame() {}\n",
    "PreviewSizeTests.swift": "final class PreviewSizeTests: XCTestCase {\n    let fixture = PreviewFixture()\n}\n",
    "PreviewFadeTests.swift": "final class PreviewFadeTests: XCTestCase {\n    let frame = makePreviewFrame()\n}\n",
    "ProviderSupport.swift": "struct ProviderFixture {}\nextension ProviderPermissions {\n    static var approving: Self { .init() }\n}\n",
    "ProviderConfigurationTests.swift": "final class ProviderConfigurationTests: XCTestCase {\n    let fixture = ProviderFixture()\n}\n",
    "ProviderPackageTests.swift": "final class ProviderPackageTests: XCTestCase {\n    func testLoad() { load(.approving) }\n}\n",
    "EtaTests.swift": "final class EtaTests: XCTestCase {}\n",
    "ThetaTests.swift": "internal final class ThetaTests: XCTestCase {}\nfinal class IotaTests: XCTestCase {}\n",
    "CounterSupport.swift": "struct CounterFixture {}\nprivate(set) var counter = 0\n",
    "CounterTests.swift": "final class CounterTests: XCTestCase {\n    let fixture = CounterFixture()\n}\n",
}


class CITestPlanTests(unittest.TestCase):
    def setUp(self):
        raw = tempfile.TemporaryDirectory()
        self.addCleanup(raw.cleanup)
        self.root = Path(raw.name)
        tests = self.root / "Tests/OmniWMTests"
        tests.mkdir(parents=True)
        for name, text in SUITES.items():
            (tests / name).write_text(text)

    def plan(self, *paths, event="pull_request"):
        return plan_module.plan(list(paths), event, self.root)

    def selected(self, *paths):
        groups = self.plan(*paths)
        self.assertEqual([group["name"] for group in groups], ["selected 1"])
        self.assertEqual(groups[0]["flag"], "--filter")
        return groups[0]["pattern"]

    def test_tooling_and_docs_changes_skip_the_suite(self):
        self.assertEqual(self.plan("docs/a.md", "README.md", "Scripts/x.py", "Tests/DevToolingTests/test_x.py"), [])

    def test_pushes_and_app_changes_run_every_group(self):
        self.assertEqual(self.plan("README.md", event="push"), plan_module.full(self.root))
        self.assertEqual(self.plan("Sources/OmniWM/App/A.swift"), plan_module.full(self.root))
        self.assertEqual(self.plan("Scripts/lib/x.py"), plan_module.full(self.root))
        self.assertEqual(self.plan("Tests/OmniWMTests/AlphaTests.swift", "Package.swift"), plan_module.full(self.root))
        self.assertEqual(self.plan("Tests/OmniWMTests/Fixtures/a.json"), plan_module.full(self.root))

    def test_test_only_changes_run_the_suites_that_reach_them(self):
        self.assertEqual(self.selected("Tests/OmniWMTests/AlphaTests.swift"), r"OmniWMTests\.(AlphaTests|BetaTests)/")
        self.assertEqual(self.selected("Tests/OmniWMTests/GammaTests.swift"), r"OmniWMTests\.(GammaTests)/")
        self.assertEqual(self.selected("Tests/OmniWMTests/EpsilonTests.swift"), r"OmniWMTests\.(EpsilonTests)/")
        self.assertEqual(self.selected("Tests/OmniWMTests/DeltaTests.swift"), r"OmniWMTests\.(DeltaTests|GammaBase)/")
        self.assertEqual(self.selected("Tests/OmniWMTests/ThetaTests.swift"), r"OmniWMTests\.(IotaTests|ThetaTests)/")

    def test_extension_conformances_keep_the_test_case_superclass(self):
        self.assertEqual(self.selected("Tests/OmniWMTests/ZetaTests.swift"), r"OmniWMTests\.(ZetaTests)/")

    def test_members_reached_without_a_type_name_run_every_group(self):
        self.assertEqual(self.plan("Tests/OmniWMTests/PreviewSupport.swift"), plan_module.full(self.root))
        self.assertEqual(self.plan("Tests/OmniWMTests/ProviderSupport.swift"), plan_module.full(self.root))
        self.assertEqual(self.plan("Tests/OmniWMTests/CounterSupport.swift"), plan_module.full(self.root))

    def names(self, group):
        return group["pattern"].removeprefix("OmniWMTests\\.(").removesuffix(")/").split("|")

    def test_full_suite_shards_filter_disjoint_suites_and_the_last_skips_them(self):
        groups = plan_module.full(self.root)
        self.assertEqual(len(groups), plan_module.SHARDS)
        filtered = [self.names(group) for group in groups[:-1]]
        self.assertEqual([group["flag"] for group in groups], ["--filter"] * (plan_module.SHARDS - 1) + ["--skip"])
        self.assertEqual(sum(map(len, filtered)), len({name for names in filtered for name in names}))
        self.assertEqual(self.names(groups[-1]), sorted(name for names in filtered for name in names))

    def test_heavy_suites_get_a_shard_to_themselves(self):
        with mock.patch.dict(plan_module.SECONDS, {"AlphaTests": 50, "BetaTests": 40}, clear=True):
            groups = [self.names(group) for group in plan_module.full(self.root)]
        self.assertIn(["AlphaTests"], groups)
        self.assertIn(["BetaTests"], groups[:-1])

    def test_shell_suites_share_one_shard_that_installs_the_shells(self):
        with mock.patch.object(plan_module, "SHELL_SUITES", {"AlphaTests", "BetaTests"}), \
                mock.patch.dict(plan_module.SECONDS, {}, clear=True):
            groups = plan_module.full(self.root)
        cases = set(plan_module.test_cases(self.root))
        runs = [set(self.names(group)) if group["flag"] == "--filter" else cases - set(self.names(group)) for group in groups]
        flagged = [members for group, members in zip(groups, runs) if group["shells"]]
        self.assertEqual(len(flagged), 1)
        self.assertTrue({"AlphaTests", "BetaTests"} <= flagged[0])

    def test_selected_suites_split_only_when_they_outweigh_one_shard(self):
        with mock.patch.dict(plan_module.SECONDS, {"ShellGlassSceneTests": 30, "ShellGlassRimTests": 30}, clear=True):
            groups = [self.names(group) for group in self.plan("Tests/OmniWMTests/ShellGlassSceneTests.swift")]
        self.assertGreater(len(groups), 1)
        self.assertFalse(any({"ShellGlassSceneTests", "ShellGlassRimTests"} <= set(group) for group in groups))
        self.assertEqual(sorted(name for group in groups for name in group),
                         ["ShellGlassRimTests", "ShellGlassSceneTests", "ShellThemeTests", "ShellVitreusBarTests"])

    def test_unresolved_or_wide_test_changes_run_every_group(self):
        self.assertEqual(self.plan("Tests/OmniWMTests/Helpers.swift"), plan_module.full(self.root))
        self.assertEqual(self.plan("Tests/OmniWMTests/Helpers.swift", "Tests/OmniWMTests/AlphaTests.swift"), plan_module.full(self.root))
        self.assertEqual(self.plan("Tests/OmniWMTests/RemovedTests.swift"), plan_module.full(self.root))
        wide = [f"Tests/OmniWMTests/{name}" for name in SUITES if name != "Helpers.swift"]
        self.assertEqual(self.plan(*wide), plan_module.full(self.root))

    def test_seconds_come_from_each_suites_executed_line(self):
        log = "\n".join([
            "Tests (shard 1)\tRun\t2026Z Test Suite 'AlphaTests' passed at 2026-11-01 14:21:38.",
            "Tests (shard 1)\tRun\t2026Z \t Executed 6 tests, with 0 failures (0 unexpected) in 12.34 (12.4) seconds",
            "Tests (shard 1)\tRun\t2026Z Test Suite 'BetaTests' failed at 2026-11-01 14:21:39.",
            "Tests (shard 1)\tRun\t2026Z \t Executed 2 tests, with 1 failure (0 unexpected) in 0.2 (0.2) seconds",
            "Tests (shard 1)\tRun\t2026Z Test Suite 'OmniWMPackageTests.xctest' passed at 2026-11-01 14:21:40.",
            "Tests (shard 1)\tRun\t2026Z \t Executed 8 tests, with 1 failure (0 unexpected) in 12.54 (12.6) seconds",
        ])
        self.assertEqual(plan_module.measured_seconds(log), {"AlphaTests": 12.3, "BetaTests": 0.2})

    def test_refreshed_seconds_keep_suites_the_run_did_not_reach(self):
        log = "\n".join([
            "Test Suite 'AlphaTests' passed at 2026-11-01 14:21:38.",
            "\t Executed 6 tests, with 0 failures (0 unexpected) in 3.0 (3.0) seconds",
            "Test Suite 'BetaTests' passed at 2026-11-01 14:21:39.",
            "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds",
        ])
        existing = {"AlphaTests": 9.0, "BetaTests": 4.0, "GammaTests": 7.0}
        self.assertEqual(plan_module.refreshed(existing, log), {"AlphaTests": 3.0, "GammaTests": 7.0})

    def test_outputs_keep_a_matrix_when_the_suite_is_skipped(self):
        result = subprocess.run(
            [sys.executable, SCRIPT, "pull_request"], input="docs/a.md\n", capture_output=True, text=True, check=True
        )
        lines = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(lines["tests"], "false")
        self.assertEqual(json.loads(lines["matrix"])["include"], plan_module.full())


if __name__ == "__main__":
    unittest.main()

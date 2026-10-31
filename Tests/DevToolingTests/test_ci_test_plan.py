from pathlib import Path
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/ci_test_plan.py"
SPEC = importlib.util.spec_from_file_location("ci_test_plan", SCRIPT)
plan_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(plan_module)

SUITES = {
    "AlphaTests.swift": "final class AlphaTests: XCTestCase {\n    private struct Fixture {}\n}\n"
                        "struct AlphaHarness {}\n",
    "BetaTests.swift": "@MainActor\nfinal class BetaTests: XCTestCase {\n    let harness = AlphaHarness()\n}\n",
    "GammaTests.swift": "final class GammaTests: XCTestCase {\n    private struct Fixture {}\n}\n",
    "DeltaTests.swift": "final class DeltaTests: GammaBase {}\nclass GammaBase: XCTestCase {}\n",
    "EpsilonTests.swift": "final class EpsilonTests: XCTestCase {}\n",
    "Helpers.swift": "import XCTest\n\nfunc helper() {}\n",
    "ShellGlassSceneTests.swift": "final class ShellGlassSceneTests: XCTestCase {}\n",
    "ShellGlassRimTests.swift": "final class ShellGlassRimTests: XCTestCase {\n    let scene = ShellGlassSceneTests()\n}\n",
    "ShellWidgetTests.swift": "final class ShellWidgetTests: XCTestCase {\n    let scene = ShellGlassSceneTests()\n}\n",
    "ZetaTests.swift": "final class ZetaTests: XCTestCase {}\n",
    "EtaTests.swift": "final class EtaTests: XCTestCase {}\n",
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
        self.assertEqual([group["name"] for group in groups], ["selected rest"])
        self.assertEqual(groups[0]["flag"], "--filter")
        return groups[0]["pattern"]

    def test_tooling_and_docs_changes_skip_the_suite(self):
        self.assertEqual(self.plan("docs/a.md", "README.md", "Scripts/x.py", "Tests/DevToolingTests/test_x.py"), [])

    def test_pushes_and_app_changes_run_every_group(self):
        self.assertEqual(self.plan("README.md", event="push"), plan_module.FULL)
        self.assertEqual(self.plan("Sources/OmniWM/App/A.swift"), plan_module.FULL)
        self.assertEqual(self.plan("Scripts/lib/x.py"), plan_module.FULL)
        self.assertEqual(self.plan("Tests/OmniWMTests/AlphaTests.swift", "Package.swift"), plan_module.FULL)
        self.assertEqual(self.plan("Tests/OmniWMTests/Fixtures/a.json"), plan_module.FULL)

    def test_test_only_changes_run_the_suites_that_reach_them(self):
        self.assertEqual(self.selected("Tests/OmniWMTests/AlphaTests.swift"), r"OmniWMTests\.(AlphaTests|BetaTests)/")
        self.assertEqual(self.selected("Tests/OmniWMTests/GammaTests.swift"), r"OmniWMTests\.(GammaTests)/")
        self.assertEqual(self.selected("Tests/OmniWMTests/DeltaTests.swift"), r"OmniWMTests\.(DeltaTests|GammaBase)/")

    def test_selected_glass_suites_get_their_own_group(self):
        groups = self.plan("Tests/OmniWMTests/ShellGlassSceneTests.swift")
        self.assertEqual(
            [(group["name"], group["pattern"]) for group in groups],
            [
                ("selected glass", r"OmniWMTests\.(ShellGlassRimTests|ShellGlassSceneTests)/"),
                ("selected rest", r"OmniWMTests\.(ShellWidgetTests)/"),
            ],
        )

    def test_unresolved_or_wide_test_changes_run_every_group(self):
        self.assertEqual(self.plan("Tests/OmniWMTests/Helpers.swift"), plan_module.FULL)
        self.assertEqual(self.plan("Tests/OmniWMTests/Helpers.swift", "Tests/OmniWMTests/AlphaTests.swift"), plan_module.FULL)
        self.assertEqual(self.plan("Tests/OmniWMTests/RemovedTests.swift"), plan_module.FULL)
        wide = [f"Tests/OmniWMTests/{name}" for name in SUITES if name != "Helpers.swift"]
        self.assertEqual(self.plan(*wide), plan_module.FULL)

    def test_outputs_keep_a_matrix_when_the_suite_is_skipped(self):
        result = subprocess.run(
            [sys.executable, SCRIPT, "pull_request"], input="docs/a.md\n", capture_output=True, text=True, check=True
        )
        lines = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(lines["tests"], "false")
        self.assertEqual(json.loads(lines["matrix"])["include"], plan_module.FULL)


if __name__ == "__main__":
    unittest.main()

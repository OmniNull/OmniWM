import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
SPEC = importlib.util.spec_from_file_location("luau_check", SCRIPTS / "luau_check.py")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

STUB = """
import sys
from pathlib import Path
flagged = {flagged!r}
failed = False
for name in sys.argv[2:]:
    path = Path(name)
    if path.name in flagged:
        print(f"{{name}}:{{len(path.read_text().splitlines())}}:1: TypeError: {{flagged[path.name]}}")
        failed = True
sys.exit(1 if failed else 0)
"""


class LuauCheckGateTests(unittest.TestCase):
    def setUp(self):
        raw = tempfile.TemporaryDirectory()
        self.addCleanup(raw.cleanup)
        self.root = Path(raw.name)
        self.recipes = ["local a = 1\n", "local b = 2\n"]
        self.clean = {"ok.luau": "--!strict\nlocal x = 1\n"}
        self.rejected = {"typo.luau": "--!strict\nlocal wm = omniwm\nwm.cmd.focuss()\n"}
        self.rejections = {"typo.luau": "Key 'focuss' not found"}
        for folder, files in (("clean", self.clean), ("rejected", self.rejected)):
            (self.root / folder).mkdir()
            for name, text in files.items():
                (self.root / folder / name).write_text(text)
        fences = "\n".join(f"```lua\n{recipe}```\n" for recipe in self.recipes)
        self.guide = self.root / "guide.md"
        self.guide.write_text(f"Intro\n\n{fences}\n```sh\necho other\n```\n")

    def stub(self, flagged):
        path = self.root / "stub.py"
        path.write_text(STUB.format(flagged=flagged))
        return [sys.executable, str(path)]

    def test_recipes_returns_only_the_lua_blocks(self):
        self.assertEqual(gate.recipes(self.guide.read_text()), self.recipes)

    def test_recipes_refuses_a_lua_block_without_a_closing_fence(self):
        with self.assertRaises(ValueError):
            gate.recipes("```lua\nlocal a = 1\n")

    def test_recipes_reads_every_fence_form_of_a_lua_block(self):
        bodies = ["local a = 1\n", "local b = 2\n", "local c = 3\n", "local d = 4\n", "local e = 5\n"]
        openings = ["````lua", "~~~lua", '```lua title="recipe"', "```luau", "```lua{2}"]
        closings = ["````", "~~~", "```", "```", "```"]
        markdown = "".join(f"{opening}\n{body}{closing}\n" for opening, body, closing in zip(openings, bodies, closings))
        self.assertEqual(gate.recipes(markdown), bodies)

    def test_a_tilde_fence_may_carry_backticks_in_its_info_string(self):
        bodies = ["local a = 1\n", "local b = 2\n"]
        markdown = f"~~~lua title=\"`a`\"\n{bodies[0]}~~~\n\n~~~lua\n{bodies[1]}~~~\n"
        self.assertEqual(gate.recipes(markdown), bodies)

    def test_a_fence_with_an_info_string_does_not_close_a_lua_block(self):
        with self.assertRaises(ValueError):
            gate.recipes("```lua\nlocal a = 1\n```text\n")

    def test_a_lua_fence_inside_another_block_is_content(self):
        inner = "```lua\nlocal hidden = 1\n```\n"
        self.assertEqual(gate.recipes(f"````text\n{inner}````\n"), [])

    def test_a_checker_that_rejects_exactly_the_mistakes_passes(self):
        clean, rejected, problems = gate.check(self.stub(self.rejections), self.guide, self.root, self.rejections)
        self.assertEqual(problems, [])
        self.assertEqual(clean, len(self.clean) + len(self.recipes))
        self.assertEqual(rejected, len(self.rejected))

    def test_a_mistake_the_checker_accepts_is_reported(self):
        _, _, problems = gate.check(self.stub({}), self.guide, self.root, self.rejections)
        self.assertEqual(len(problems), len(self.rejected))
        self.assertIn(next(iter(self.rejected)), problems[0])

    def test_a_diagnostic_in_a_clean_file_is_reported(self):
        flagged = dict(self.rejections, **{next(iter(self.clean)): "unexpected"})
        _, _, problems = gate.check(self.stub(flagged), self.guide, self.root, self.rejections)
        self.assertEqual(len(problems), 1)
        self.assertIn("clean files reported diagnostics", problems[0])

    def test_output_on_stderr_from_a_clean_run_is_reported(self):
        command = self.stub(self.rejections)
        noisy = self.root / "noisy.py"
        noisy.write_text("import runpy, sys\nprint('note', file=sys.stderr)\nsys.argv = sys.argv[1:]\nrunpy.run_path(sys.argv[0], run_name='__main__')\n")
        _, _, problems = gate.check([sys.executable, str(noisy), command[1]], self.guide, self.root, self.rejections)
        self.assertTrue(any("clean files reported diagnostics" in problem for problem in problems))

    def test_a_missing_expectation_for_a_fixture_is_reported(self):
        _, _, problems = gate.check(self.stub(self.rejections), self.guide, self.root, {})
        self.assertTrue(any("differ from" in problem for problem in problems))


if __name__ == "__main__":
    unittest.main()

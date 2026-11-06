from pathlib import Path
import re
import unittest


TESTS = Path(__file__).resolve().parents[1] / "OmniWMTests"
SKIP = re.compile(r"\bXCTSkip")
LITERAL_TIMEOUT = re.compile(r"\b(?:timeout:|executionTimeAllowance\s*=)\s*\.?[0-9]")


class SwiftTestRuleTests(unittest.TestCase):
    def offenders(self, pattern):
        return [
            f"{path.name}:{number}"
            for path in sorted(TESTS.rglob("*.swift"))
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1)
            if pattern.search(line)
        ]

    def test_no_test_skips_itself(self):
        self.assertEqual(self.offenders(SKIP), [], "Fail with MissingTestPrerequisite, or gate on OMNIWM_LIVE_CHECKS")

    def test_timeouts_use_a_named_value(self):
        self.assertEqual(self.offenders(LITERAL_TIMEOUT), [], "Bound waits with failureBound, or name the fixture input")


if __name__ == "__main__":
    unittest.main()

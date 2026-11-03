import importlib.util
from pathlib import Path
import re
import sys
import unittest


SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("generate_ipc_wire", SCRIPTS / "generate_ipc_wire.py")
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)


def encoder_body(typ):
    header = f"    mutating func value(_ value: borrowing {typ}) throws {{\n"
    matches = [function for function in generator.output if function.startswith(header)]
    if len(matches) != 1:
        raise AssertionError(f"expected one encoder for {typ}, found {len(matches)}")
    return "\n".join(matches[0].splitlines()[1:-1])


class IPCWireGeneratorTests(unittest.TestCase):
    def test_command_encoder_covers_every_declared_command_case(self):
        source = (generator.models / "IPCCommandModels.swift").read_text()
        declaration = re.search(
            r"public enum IPCCommandRequest: [^{]+\{(.*?)\n    public var name:", source, re.S
        )
        self.assertIsNotNone(declaration)
        expected = set(re.findall(r"^    case (\w+)", declaration.group(1), re.M))
        branches = re.findall(r"^        case (.+):$", encoder_body("IPCCommandRequest"), re.M)
        actual = set(re.findall(r"\.(\w+)", "\n".join(branches)))
        self.assertEqual(actual, expected)

    def test_payload_roots_write_sorted_keys_and_delegate_the_payload_switch(self):
        roots = {
            "IPCResult": ["kind", "payload"],
            "IPCRequest": ["authorizationToken", "id", "kind", "payload", "version"],
        }
        for root, keys in roots.items():
            body = encoder_body(root)
            self.assertEqual(re.findall(r'self\.key\("(\w+)"', body), keys, root)
            self.assertIn("        try self.value(value.payload)", body.splitlines(), root)
            self.assertNotIn("switch", body, root)

    def test_payload_switches_cover_every_payload_case_in_declaration_order(self):
        request_source = (generator.models / "IPCRequest.swift").read_text()
        expected = {
            "IPCResult.Payload": [generator.camel(kind) for kind in generator.schemas["IPCResult"]["tagged"]],
            "IPCRequest.Payload": re.findall(r"^        case (\w+)\(\w+\)$", request_source, re.M),
        }
        for typ, cases in expected.items():
            self.assertIn("windowGather", cases, typ)
            self.assertEqual(re.findall(r"case let \.(\w+)\(payload\):", encoder_body(typ)), cases, typ)


if __name__ == "__main__":
    unittest.main()

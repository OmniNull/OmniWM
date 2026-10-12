import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "Scripts" / "release-ci-credentials.sh"

REQUIRED_VARS = [
    "APPLE_DEVELOPER_ID_CERT_P12_BASE64",
    "APPLE_DEVELOPER_ID_CERT_PASSWORD",
    "APPLE_NOTARY_KEY_ID",
    "APPLE_NOTARY_ISSUER_ID",
    "APPLE_NOTARY_KEY_P8",
    "RUNNER_TEMP",
    "KEYCHAIN_PASSWORD",
]

CERT_P12_BASE64 = base64.b64encode(b"fake-p12-bytes").decode()
CERT_PASSWORD = "cert-password"
NOTARY_KEY_ID = "ABC123KEYID"
NOTARY_ISSUER_ID = "issuer-uuid-1234"
KEYCHAIN_PASSWORD = "keychain-password"
SIGNING_IDENTITY = "Developer ID Application: Oliver Nikolic (VF8LDJRGFM)"
NOTARIZE_PROFILE = "OmniWM-Notarize"

P8_BODY = (
    "-----BEGIN PRIVATE KEY-----\n"
    "MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgfakefakefakefake\n"
    "-----END PRIVATE KEY-----"
)

SECRET_VALUES = [CERT_P12_BASE64, CERT_PASSWORD, KEYCHAIN_PASSWORD, P8_BODY]

SECURITY_STUB = r"""#!/bin/bash
set -eu
{
  printf '%s' "${1:-}"
  if [ "$#" -gt 1 ]; then
    for arg in "${@:2}"; do printf '\t%s' "$arg"; done
  fi
  printf '\n'
} >> "$OMNIWM_TEST_CMDLOG"
if [ "${1:-}" = "find-identity" ] && [ -n "${OMNIWM_TEST_FAKE_IDENTITY:-}" ]; then
  printf '  1) 1234ABCDEF "%s"\n' "$OMNIWM_TEST_FAKE_IDENTITY"
elif [ "${1:-}" = "default-keychain" ] && [ "${2:-}" = "-d" ]; then
  printf '    "%s"\n' "$OMNIWM_TEST_LOGIN_KEYCHAIN"
elif [ "${1:-}" = "list-keychains" ] && [ "${2:-}" = "-d" ]; then
  printf '    "%s"\n' "$OMNIWM_TEST_LOGIN_KEYCHAIN"
  printf '    "%s"\n' "$OMNIWM_TEST_OTHER_KEYCHAIN"
fi
if [ "${1:-}" = "delete-keychain" ]; then
  rm -f "${2:-}"
fi
"""

XCRUN_STUB = r"""#!/bin/bash
set -eu
{
  printf '%s' "${1:-}"
  if [ "$#" -gt 1 ]; then
    for arg in "${@:2}"; do printf '\t%s' "$arg"; done
  fi
  printf '\n'
} >> "$OMNIWM_TEST_CMDLOG"
"""


class ReleaseCICredentialsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="omniwm-release-ci-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.write_command(self.tools / "security", SECURITY_STUB)
        self.write_command(self.tools / "xcrun", XCRUN_STUB)
        self.runner_temp = self.root / "runner-temp"
        self.runner_temp.mkdir()
        self.login_keychain = self.root / "login.keychain-db"
        self.other_keychain = self.root / "other.keychain-db"
        self.cmdlog = self.root / "commands.log"
        clean = self.clean_environ()
        self.environment = {
            **clean,
            "PATH": f"{self.tools}:{clean['PATH']}",
            "OMNIWM_TEST_CMDLOG": str(self.cmdlog),
            "OMNIWM_TEST_FAKE_IDENTITY": SIGNING_IDENTITY,
            "OMNIWM_TEST_LOGIN_KEYCHAIN": str(self.login_keychain),
            "OMNIWM_TEST_OTHER_KEYCHAIN": str(self.other_keychain),
            "RUNNER_TEMP": str(self.runner_temp),
            "APPLE_DEVELOPER_ID_CERT_P12_BASE64": CERT_P12_BASE64,
            "APPLE_DEVELOPER_ID_CERT_PASSWORD": CERT_PASSWORD,
            "APPLE_NOTARY_KEY_ID": NOTARY_KEY_ID,
            "APPLE_NOTARY_ISSUER_ID": NOTARY_ISSUER_ID,
            "APPLE_NOTARY_KEY_P8": P8_BODY,
            "KEYCHAIN_PASSWORD": KEYCHAIN_PASSWORD,
        }

    @staticmethod
    def clean_environ():
        reserved = {*REQUIRED_VARS, "OMNIWM_TEST_CMDLOG", "OMNIWM_TEST_FAKE_IDENTITY"}
        return {
            name: value
            for name, value in os.environ.items()
            if name not in reserved
        }

    @staticmethod
    def write_command(path, body):
        path.write_text(body)
        path.chmod(0o755)

    def run_script(self, *args, overrides=None, omit=()):
        environment = {**self.environment, **(overrides or {})}
        for name in omit:
            environment.pop(name, None)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), *args],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def log_text(self):
        if not self.cmdlog.exists():
            return ""
        return self.cmdlog.read_text()

    def commands(self):
        return [line.split("\t") for line in self.log_text().splitlines()]

    def first_tokens(self):
        return [argv[0] for argv in self.commands()]

    def assert_not_stored(self):
        self.assertNotIn("store-credentials", self.log_text())

    def assert_ordered(self, tokens, expected):
        position = 0
        for command in expected:
            while position < len(tokens) and tokens[position] != command:
                position += 1
            self.assertLess(position, len(tokens), tokens)
            position += 1

    def assert_no_secrets(self, result):
        for secret in SECRET_VALUES:
            self.assertNotIn(secret, result.stdout)
            self.assertNotIn(secret, result.stderr)

    def keychain_path(self):
        return str(self.runner_temp / "omniwm-release.keychain-db")

    def test_missing_variables_exit_2_without_touching_tools(self):
        result = self.run_script(omit=REQUIRED_VARS)

        self.assertEqual(result.returncode, 2)
        for name in REQUIRED_VARS:
            self.assertIn(name, result.stderr)
        self.assertEqual(self.commands(), [])

    def test_newline_terminated_notary_key_is_accepted(self):
        result = self.run_script(overrides={"APPLE_NOTARY_KEY_P8": P8_BODY + "\n"})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("store-credentials", self.log_text())
        self.assert_no_secrets(result)

    def test_single_missing_variable_is_listed_by_name(self):
        result = self.run_script(overrides={"KEYCHAIN_PASSWORD": ""})

        self.assertEqual(result.returncode, 2)
        self.assertIn("KEYCHAIN_PASSWORD", result.stderr)
        self.assertNotIn("APPLE_NOTARY_KEY_ID", result.stderr)
        self.assertEqual(self.commands(), [])

    def test_happy_path_runs_expected_commands_and_removes_temp_files(self):
        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        keychain = self.keychain_path()
        p8_path = str(self.runner_temp / f"AuthKey_{NOTARY_KEY_ID}.p8")
        commands = self.commands()
        tokens = self.first_tokens()
        self.assert_ordered(
            tokens,
            [
                "create-keychain",
                "import",
                "list-keychains",
                "default-keychain",
                "set-key-partition-list",
                "find-identity",
                "notarytool",
            ],
        )
        self.assertEqual(tokens[-1], "notarytool", tokens)
        self.assertEqual(tokens[:2], ["default-keychain", "list-keychains"])

        state = self.runner_temp / "omniwm-release-keychain-state"
        self.assertEqual(
            state.read_text(),
            f"{self.login_keychain}\n{self.login_keychain}\n{self.other_keychain}\n",
        )

        create = commands[tokens.index("create-keychain")]
        self.assertIn("-p", create)
        self.assertIn(KEYCHAIN_PASSWORD, create)
        self.assertIn(keychain, create)

        imported = commands[tokens.index("import")]
        self.assertIn(str(self.runner_temp / "developer-id.p12"), imported)
        self.assertIn(keychain, imported)

        set_calls = [c for c in commands if c[:4] == ["list-keychains", "-d", "user", "-s"]]
        self.assertEqual(set_calls, [["list-keychains", "-d", "user", "-s", keychain]])
        set_defaults = [c for c in commands if c[:2] == ["default-keychain", "-s"]]
        self.assertEqual(set_defaults, [["default-keychain", "-s", keychain]])
        partition = commands[tokens.index("set-key-partition-list")]
        self.assertIn("-S", partition)
        self.assertIn(keychain, partition)

        identities = commands[tokens.index("find-identity")]
        self.assertIn("-v", identities)
        self.assertIn("-p", identities)
        self.assertIn("codesigning", identities)
        self.assertIn(keychain, identities)

        store = commands[tokens.index("notarytool")]
        self.assertEqual(store[1], "store-credentials")
        self.assertEqual(store[2], NOTARIZE_PROFILE)
        self.assertIn("--key", store)
        self.assertIn(p8_path, store)
        self.assertIn("--key-id", store)
        self.assertIn(NOTARY_KEY_ID, store)
        self.assertIn("--issuer", store)
        self.assertIn(NOTARY_ISSUER_ID, store)
        self.assertIn("--keychain", store)
        self.assertIn(keychain, store)

        self.assertEqual(
            sorted(p.name for p in self.runner_temp.iterdir()),
            ["omniwm-release-keychain-state"],
        )
        self.assert_no_secrets(result)

    def test_absent_signing_identity_fails_before_storing_credentials(self):
        result = self.run_script(overrides={"OMNIWM_TEST_FAKE_IDENTITY": ""})

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("OMNIWM_RELEASE_SIGNING_IDENTITY", result.stderr)
        self.assertIn("find-identity", self.first_tokens())
        self.assert_not_stored()

    def test_p8_without_end_line_fails_before_storing_credentials(self):
        result = self.run_script(
            overrides={"APPLE_NOTARY_KEY_P8": "-----BEGIN PRIVATE KEY-----\nMIGTAgEA"}
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_p8_with_literal_newline_escapes_fails_before_storing_credentials(self):
        literal = "\\n".join(P8_BODY.splitlines())

        result = self.run_script(overrides={"APPLE_NOTARY_KEY_P8": literal})

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])
        self.assert_no_secrets(result)

    def test_secrets_never_reach_stdout_or_stderr(self):
        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_secrets(result)

    def test_cleanup_deletes_existing_keychain(self):
        keychain = self.runner_temp / "omniwm-release.keychain-db"
        keychain.write_bytes(b"keychain")

        result = self.run_script("cleanup")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands(), [["delete-keychain", str(keychain)]])

    def test_cleanup_restores_recorded_keychains_then_deletes_its_own(self):
        keychain = self.runner_temp / "omniwm-release.keychain-db"
        keychain.write_bytes(b"keychain")
        state = self.runner_temp / "omniwm-release-keychain-state"
        state.write_text(
            f"{self.login_keychain}\n{self.login_keychain}\n{self.other_keychain}\n"
        )

        result = self.run_script("cleanup")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.commands(),
            [
                [
                    "list-keychains",
                    "-d",
                    "user",
                    "-s",
                    str(self.login_keychain),
                    str(self.other_keychain),
                ],
                ["default-keychain", "-d", "user", "-s", str(self.login_keychain)],
                ["delete-keychain", str(keychain)],
            ],
        )
        self.assertFalse(state.exists())

    def test_second_cleanup_run_is_a_noop(self):
        (self.runner_temp / "omniwm-release.keychain-db").write_bytes(b"keychain")
        state = self.runner_temp / "omniwm-release-keychain-state"
        state.write_text(f"{self.login_keychain}\n")
        self.assertEqual(self.run_script("cleanup").returncode, 0)

        self.cmdlog.unlink()

        result = self.run_script("cleanup")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands(), [])

    def test_cleanup_without_keychain_is_a_noop(self):
        result = self.run_script("cleanup")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands(), [])


if __name__ == "__main__":
    unittest.main()

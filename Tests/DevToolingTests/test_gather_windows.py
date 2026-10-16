import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2]
SCRIPT = SOURCE / "Scripts/gather-windows.py"
PROTOCOL_VERSION = int(
    re.search(
        r"public static let version = (\d+)",
        (SOURCE / "Sources/OmniWMIPC/IPCModels.swift").read_text(),
    ).group(1)
)
SECRET = "test-secret-token-7b1f"


class FakeOmniWM:
    """Serves one response line per connection on a temporary IPC socket."""

    def __init__(self, directory, response=None, secret=SECRET):
        self.path = os.path.join(directory, "ipc.sock")
        if secret is not None:
            Path(self.path + ".secret").write_text(secret + "\n")
        self.response = response
        self.requests = []
        self.connections = 0
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen()
        self.server.settimeout(0.1)
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stopped.is_set():
            try:
                connection, _ = self.server.accept()
            except socket.timeout:
                continue
            with connection:
                self.connections += 1
                data = b""
                while not data.endswith(b"\n"):
                    chunk = connection.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                if not data:
                    continue
                request = json.loads(data)
                self.requests.append(request)
                if isinstance(self.response, bytes):
                    connection.sendall(self.response)
                elif self.response is not None:
                    reply = dict(self.response, id=request["id"])
                    connection.sendall(json.dumps(reply).encode() + b"\n")

    def close(self):
        self.stopped.set()
        self.thread.join()
        self.server.close()


def gather_result(outcome, windows, reason=None):
    payload = {
        "outcome": outcome,
        "workspace": {"id": "ws", "rawName": "2", "displayName": "2", "number": 2},
        "windows": windows,
        "moved": [window["windowId"] for window in windows if window["status"] == "moved"],
        "relayoutWorkspaces": [],
        "modelCommitted": outcome == "gathered",
        "relayoutRequested": outcome == "gathered",
    }
    if reason:
        payload["reason"] = reason
    return {"kind": "window-gather", "payload": payload}


def response(ok, status, result=None, code=None):
    reply = {"version": PROTOCOL_VERSION, "ok": ok, "kind": "window-gather", "status": status}
    if code:
        reply["code"] = code
    if result:
        reply["result"] = result
    return reply


GATHERED = response(
    True,
    "executed",
    gather_result("gathered", [
        {"windowId": "ow_b", "status": "moved"},
        {"windowId": "ow_a", "status": "moved"},
    ]),
)
UNCHANGED = response(
    False,
    "ignored",
    gather_result("unchanged", [
        {"windowId": "ow_b", "status": "unchanged"},
        {"windowId": "ow_a", "status": "unchanged"},
    ]),
    code="no_change",
)
REFUSED = response(
    False,
    "error",
    gather_result("refused", [
        {"windowId": "ow_b", "status": "refused", "reason": "minimized"},
        {"windowId": "ow_a", "status": "blocked"},
    ], reason="window_refused"),
    code="ineligible_window",
)


class GatherWindowsScriptTests(unittest.TestCase):
    def setUp(self):
        # AF_UNIX paths are limited to 104 bytes on macOS, so keep the directory short.
        self.directory = tempfile.mkdtemp(prefix="gw", dir="/tmp")
        self.servers = []

    def tearDown(self):
        for server in self.servers:
            server.close()
        for name in os.listdir(self.directory):
            os.unlink(os.path.join(self.directory, name))
        os.rmdir(self.directory)

    def serve(self, reply=GATHERED, secret=SECRET):
        server = FakeOmniWM(self.directory, reply, secret=secret)
        self.servers.append(server)
        return server

    def run_script(self, *arguments):
        environment = dict(os.environ, OMNIWM_SOCKET=os.path.join(self.directory, "ipc.sock"))
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            capture_output=True,
            text=True,
            env=environment,
            timeout=30,
        )

    def assert_secret_hidden(self, result):
        self.assertNotIn(SECRET, result.stdout)
        self.assertNotIn(SECRET, result.stderr)

    def test_sends_one_ordered_window_gather_request(self):
        server = self.serve()

        result = self.run_script("--workspace", "2", "ow_b", "ow_a")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(server.connections, 1)
        self.assertEqual(len(server.requests), 1)
        request = server.requests[0]
        self.assertEqual(request["version"], PROTOCOL_VERSION)
        self.assertEqual(request["kind"], "window-gather")
        self.assertTrue(request["id"])
        self.assertEqual(request["authorizationToken"], SECRET)
        self.assertEqual(request["payload"], {
            "windowIds": ["ow_b", "ow_a"],
            "workspaceTarget": {"kind": "raw-id", "value": "2"},
        })
        self.assertEqual(json.loads(result.stdout)["result"], GATHERED["result"])
        self.assert_secret_hidden(result)

    def test_non_numeric_workspace_is_a_display_name(self):
        server = self.serve()

        for workspace in ("Mail", "02", "0"):
            with self.subTest(workspace=workspace):
                self.run_script("--workspace", workspace, "ow_a")
                self.assertEqual(
                    server.requests[-1]["payload"]["workspaceTarget"],
                    {"kind": "display-name", "value": workspace},
                )

    def test_missing_or_empty_secret_sends_no_token(self):
        for secret in (None, "  \n"):
            with self.subTest(secret=secret):
                server = self.serve(secret=secret)

                result = self.run_script("--workspace", "2", "ow_a")

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("authorizationToken", server.requests[0])
                server.close()
                self.servers.remove(server)
                for name in os.listdir(self.directory):
                    os.unlink(os.path.join(self.directory, name))

    def test_rejections_exit_nonzero_and_print_the_typed_result(self):
        cases = (
            (UNCHANGED, 1),
            (REFUSED, 1),
            (response(False, "error", code="unauthorized"), 1),
            (response(False, "error", code="protocol_mismatch"), 1),
            (response(False, "error", code="internal_error"), 4),
        )
        server = self.serve()
        for reply, exit_code in cases:
            with self.subTest(code=reply.get("code")):
                server.response = reply

                result = self.run_script("--workspace", "2", "ow_b", "ow_a")

                self.assertEqual(result.returncode, exit_code, result.stderr)
                self.assertEqual(json.loads(result.stdout).get("result"), reply.get("result"))
                self.assert_secret_hidden(result)
        self.assertEqual(server.connections, len(cases))

    def test_dry_run_prints_the_request_without_connecting(self):
        server = self.serve()

        result = self.run_script("--dry-run", "--workspace", "2", "ow_b", "ow_a")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(server.connections, 0)
        request = json.loads(result.stdout)
        self.assertEqual(request["kind"], "window-gather")
        self.assertEqual(request["payload"]["windowIds"], ["ow_b", "ow_a"])
        self.assertNotIn("authorizationToken", request)
        self.assert_secret_hidden(result)

    def test_transport_failures_exit_two(self):
        result = self.run_script("--workspace", "2", "ow_a")
        self.assertEqual(result.returncode, 2)
        self.assertIn("gather-windows:", result.stderr)

        server = self.serve(reply=None)
        result = self.run_script("--workspace", "2", "ow_a")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(len(server.requests), 1)
        self.assert_secret_hidden(result)

    def test_undecodable_response_exits_four(self):
        self.serve(reply=b"not json\n")

        result = self.run_script("--workspace", "2", "ow_a")

        self.assertEqual(result.returncode, 4)
        self.assertIn("gather-windows:", result.stderr)

    def test_invalid_arguments_exit_three_without_connecting(self):
        server = self.serve()
        for arguments in ((), ("ow_a",), ("--workspace", "2"), ("--workspace", "", "ow_a")):
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 3)
        self.assertEqual(server.connections, 0)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Gather explicit windows into one Niri column with a single window-gather request.

Usage:
  gather-windows.py --workspace WORKSPACE [--dry-run] WINDOW_ID [WINDOW_ID ...]

The windows become, in the given order, the only windows of the leading column
of the existing WORKSPACE. OmniWM validates the whole request before anything
changes and refuses it, moving nothing, when any window is ineligible. The
script sends exactly one request and never falls back to focus or move
commands. A positive whole number names a workspace ID; any other value is a
workspace display name, as in omniwmctl.

Window IDs are the opaque IDs reported by `omniwmctl query windows`. The
response is printed as JSON. `--dry-run` prints the request instead, without
the authorization token, and contacts nothing.

Exit codes follow omniwmctl: 0 gathered, 1 rejected (including unchanged),
2 transport failure, 3 invalid arguments, 4 internal error.
"""

import argparse
import json
import os
import socket
import sys
import uuid
from pathlib import Path

PROTOCOL_VERSION = 20
TIMEOUT_SECONDS = 10

EXIT_SUCCESS = 0
EXIT_REJECTED = 1
EXIT_TRANSPORT_FAILURE = 2
EXIT_INVALID_ARGUMENTS = 3
EXIT_INTERNAL_ERROR = 4


def fail(message, exit_code):
    print(f"gather-windows: {message}", file=sys.stderr)
    raise SystemExit(exit_code)


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        fail(message, EXIT_INVALID_ARGUMENTS)


def parse_args(argv):
    parser = ArgumentParser(description="Gather explicit windows into one Niri column.")
    parser.add_argument("--workspace", required=True, help="existing destination workspace ID or name")
    parser.add_argument("--dry-run", action="store_true", help="print the request without sending it")
    parser.add_argument("window_ids", nargs="+", metavar="WINDOW_ID", help="window IDs in column order")
    args = parser.parse_args(argv)
    if not args.workspace:
        parser.error("--workspace must not be empty")
    return args


def workspace_target(value):
    # Mirrors WorkspaceTarget(resolvingInput:): only a canonical positive integer is a raw ID.
    if value.isascii() and value.isdigit() and value == str(int(value)) and int(value) > 0:
        return {"kind": "raw-id", "value": value}
    return {"kind": "display-name", "value": value}


def socket_path():
    configured = os.environ.get("OMNIWM_SOCKET")
    if configured:
        return configured
    return str(Path.home() / "Library/Application Support/com.barut.OmniWM/ipc.sock")


def authorization_token(path):
    try:
        token = Path(path + ".secret").read_text().strip()
    except OSError:
        return None
    return token or None


def build_request(window_ids, workspace):
    return {
        "version": PROTOCOL_VERSION,
        "id": str(uuid.uuid4()),
        "kind": "window-gather",
        "payload": {"windowIds": window_ids, "workspaceTarget": workspace_target(workspace)},
    }


def send(path, request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(TIMEOUT_SECONDS)
        connection.connect(path)
        connection.sendall(json.dumps(request, sort_keys=True).encode() + b"\n")
        data = b""
        while b"\n" not in data:
            chunk = connection.recv(65536)
            if not chunk:
                break
            data += chunk
    line = data.split(b"\n", 1)[0]
    if not line:
        raise ConnectionError("OmniWM closed the connection without a response")
    return line


def exit_code(response):
    if response.get("ok") is True:
        return EXIT_SUCCESS
    if response.get("code") == "internal_error":
        return EXIT_INTERNAL_ERROR
    return EXIT_REJECTED


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    request = build_request(args.window_ids, args.workspace)
    if args.dry_run:
        print(json.dumps(request, indent=2, sort_keys=True))
        return EXIT_SUCCESS

    path = socket_path()
    token = authorization_token(path)
    if token:
        request["authorizationToken"] = token
    try:
        line = send(path, request)
    except OSError as error:
        fail(f"could not reach OmniWM at {path}: {error}", EXIT_TRANSPORT_FAILURE)
    try:
        response = json.loads(line)
    except ValueError:
        fail("OmniWM returned an invalid response", EXIT_INTERNAL_ERROR)
    # Validate the required IPCResponse envelope, not its command-specific result.
    # A different integer version is valid for protocol_mismatch diagnostics.
    if not (
        isinstance(response, dict)
        and type(response.get("version")) is int
        and response.get("id") == request["id"]
        and response.get("kind") == request["kind"]
        and type(response.get("ok")) is bool
        and response.get("status") in ("success", "executed", "ignored", "error", "subscribed")
    ):
        fail("OmniWM returned an invalid response", EXIT_INTERNAL_ERROR)
    print(json.dumps(response, indent=2, sort_keys=True))
    return exit_code(response)


if __name__ == "__main__":
    sys.exit(main())

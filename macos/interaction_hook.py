#!/usr/bin/env python3
"""Claude main-session PermissionRequest competitor; old interceptors are no-ops."""
import argparse
import json
import os
from pathlib import Path
import socket
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from service.claude_requests import normalize, native_response
from service.interactions import RESPONSE_TIMEOUT_SECONDS
from service.claude_request_scope import binding

MAX_BYTES = 65536


def exchange(request, scope):
    path = os.environ.get("PACEMAN_INTERACTION_SOCKET") or str(Path.home() / "Library/Application Support/Paceman/interaction.sock")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(.25)
        connection.connect(path)
        connection.sendall(json.dumps(dict(request=request, binding=scope, timeoutSeconds=RESPONSE_TIMEOUT_SECONDS), ensure_ascii=False).encode() + b"\n")
        connection.settimeout(RESPONSE_TIMEOUT_SECONDS + 2)
        raw = connection.makefile("rb").readline(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES or not raw.endswith(b"\n"):
            return None
        return json.loads(raw)


def run(provider, input_stream, output_stream):
    if provider != "claude":
        return
    try:
        raw = input_stream.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            return
        original = json.loads(raw)
        request = normalize(provider, original)
        scope = binding(original)
        if request is None or scope is None or "scope" not in scope:
            return
        response = native_response(provider, original, request, exchange(request, scope))
        if response is not None:
            output_stream.write(json.dumps(response, ensure_ascii=False) + "\n")
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", required=True, choices=("codex", "claude"))
    args = parser.parse_args()
    run(args.provider, sys.stdin.buffer, sys.stdout)


if __name__ == "__main__":
    main()

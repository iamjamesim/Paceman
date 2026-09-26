"""Read terminal Codex turn outcomes without loading task content."""
from __future__ import annotations

import subprocess
import time
from uuid import UUID

from service.codex_limits import _response, _send, codex_binary


def read_codex_turn_statuses(turns: list[tuple[str, str]]) -> dict[tuple[str, str], str]:
    """Return only confirmed completed/failed outcomes for known local turns.

    The metadata-only App Server listing avoids reading prompts, messages and
    tool output. An active turn can appear interrupted to another App Server
    instance, so that status is deliberately never used for reconciliation.
    """
    valid = []
    for session, turn in dict.fromkeys(turns):
        try:
            UUID(session)
            UUID(turn)
        except (ValueError, TypeError, AttributeError):
            continue
        valid.append((session, turn))
    binary = codex_binary()
    if not binary or not valid:
        return {}
    process = None
    outcomes = {}
    try:
        process = subprocess.Popen([binary, "app-server", "--stdio"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, bufsize=0)
        deadline = time.monotonic() + 8
        _send(process, {"method": "initialize", "id": 1, "params": {
            "clientInfo": {"name": "paceman", "title": "Paceman", "version": "0.1.0"},
            "capabilities": {"experimentalApi": True}}})
        if not _response(process, 1, deadline):
            return {}
        _send(process, {"method": "initialized", "params": {}})
        for request_id, (session, turn) in enumerate(valid, 2):
            _send(process, {"method": "thread/turns/list", "id": request_id, "params": {
                "threadId": session, "limit": 10, "sortDirection": "desc",
                "itemsView": "notLoaded"}})
            rows = _response(process, request_id, deadline).get("data")
            if not isinstance(rows, list):
                continue
            for row in rows:
                if isinstance(row, dict) and row.get("id") == turn:
                    if row.get("status") in ("completed", "failed"):
                        outcomes[(session, turn)] = row["status"]
                    break
    except (OSError, ValueError, BrokenPipeError, OverflowError):
        pass
    finally:
        if process is not None:
            try:
                process.terminate()
                process.wait(timeout=1)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    process.kill()
                    process.wait(timeout=1)
                except OSError:
                    pass
            process.stdin.close()
            process.stdout.close()
    return outcomes

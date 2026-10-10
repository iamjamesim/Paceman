"""Read saved Codex turn order and outcomes without loading task content."""
from __future__ import annotations

import subprocess
import time
from uuid import UUID

from service.codex_limits import _response, _send, codex_binary


def read_codex_turn_metadata(sessions: list[str]) -> dict[str, list[dict]]:
    """Read newest-first saved turn IDs and outcomes, without loading items."""
    valid = []
    for session in dict.fromkeys(sessions):
        try:
            UUID(session)
        except (ValueError, TypeError, AttributeError):
            continue
        valid.append(session)
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
        for request_id, session in enumerate(valid, 2):
            _send(process, {"method": "thread/turns/list", "id": request_id, "params": {
                "threadId": session, "limit": 10, "sortDirection": "desc",
                "itemsView": "notLoaded"}})
            rows = _response(process, request_id, deadline).get("data")
            if not isinstance(rows, list):
                continue
            if rows and all(isinstance(row, dict) and isinstance(row.get("id"), str)
                            for row in rows):
                outcomes[session] = [{"id": row["id"], "status": row.get("status")}
                                     for row in rows]
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


def read_codex_turn_statuses(turns: list[tuple[str, str]]) -> dict[tuple[str, str], str]:
    """Return only confirmed terminal outcomes for known local turns.

    A separate App Server can report an active turn as interrupted. Never use
    that status for reconciliation; saved turn ordering is independent of it.
    """
    rows = read_codex_turn_metadata([session for session, _ in turns])
    return {(session, turn): row["status"] for session, turn in turns
            for row in rows.get(session, []) if row["id"] == turn
            and row["status"] in ("completed", "failed")}

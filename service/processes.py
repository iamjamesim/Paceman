"""Linux Codex ownership from Unix peer credentials, without reading commands.

Only process metadata and executable links are inspected. A PID alone is not an
identity: start ticks and boot ID prevent reuse from reviving an old session.
"""
from dataclasses import dataclass
import os
from pathlib import Path


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    start_ticks: str
    boot_id: str


class CodexProcesses:
    def __init__(self, proc=Path("/proc")):
        self.proc = proc
        try:
            self.boot_id = (proc / "sys/kernel/random/boot_id").read_text().strip()
        except OSError:
            self.boot_id = ""

    def _read(self, pid):
        try:
            base = self.proc / str(pid)
            if base.stat().st_uid != os.getuid():
                return None
            raw = (base / "stat").read_text()
            # comm is parenthesized and can contain spaces or closing brackets.
            fields = raw[raw.rfind(")") + 2:].split()
            if fields[0] in ("Z", "X", "x"):
                return None
            return int(fields[1]), fields[19]
        except (OSError, ValueError, IndexError):
            return None

    def identify(self, peer_pid):
        """Find the nearest Codex ancestor of the kernel-authenticated sender."""
        if not self.boot_id or not peer_pid:
            return None
        original = self._read(peer_pid)
        pid, visited = peer_pid, set()
        for _ in range(64):
            if pid <= 1 or pid in visited:
                break
            visited.add(pid)
            info = self._read(pid)
            if info is None:
                break
            parent, started = info
            try:
                executable = os.readlink(self.proc / str(pid) / "exe")
            except OSError:
                break
            if Path(executable.removesuffix(" (deleted)")).name == "codex":
                identity = ProcessIdentity(pid, started, self.boot_id)
                # Recheck both ends after walking the ancestry to avoid exit/reuse races.
                if self._read(peer_pid) == original and self.is_alive(identity):
                    return identity
                break
            pid = parent
        return None

    def is_alive(self, identity):
        if not self.boot_id or identity.boot_id != self.boot_id:
            return False
        info = self._read(identity.pid)
        return info is not None and info[1] == identity.start_ticks

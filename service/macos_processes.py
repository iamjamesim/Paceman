"""macOS agent ownership from kernel peer PID and libproc lifecycle metadata."""
import ctypes
import os
from pathlib import Path
import sys

from service.processes import ProcessIdentity


class BSDInfo(ctypes.Structure):
    # sys/proc_info.h: PROC_PIDTBSDINFO, including microsecond process start time.
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'jobc', 'tdev', 'tpgid', 'nice')]
    _fields_ += [('started_sec', ctypes.c_uint64), ('started_usec', ctypes.c_uint64)]


class MacAgentProcesses:
    def __init__(self):
        self.boot_id = ''
        self.proc = self.libc = None
        if sys.platform != 'darwin':
            return
        try:
            self.proc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
            self.libc = ctypes.CDLL(None, use_errno=True)
            self.proc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
            self.proc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
            self.libc.sysctlbyname.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t),
                                             ctypes.c_void_p, ctypes.c_size_t]
            self.libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                                       ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
            buffer, size = ctypes.create_string_buffer(64), ctypes.c_size_t(64)
            if self.libc.sysctlbyname(b'kern.bootsessionuuid', buffer, ctypes.byref(size), None, 0) == 0:
                self.boot_id = buffer.value.decode('ascii')
        except (OSError, ValueError, UnicodeError):
            self.boot_id = ''

    def _read(self, pid):
        if not self.proc or type(pid) is not int or pid <= 1:
            return None
        info = BSDInfo()
        if self.proc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
            return None
        if info.pid != pid or info.uid != os.getuid() or info.status == 5 or info.flags & 4:
            return None
        path = ctypes.create_string_buffer(4096)
        if self.proc.proc_pidpath(pid, path, len(path)) <= 0:
            return None
        return info.ppid, f'{info.started_sec}:{info.started_usec}', os.fsdecode(path.value)

    def _node_launcher(self, pid):
        # KERN_PROCARGS2 has no argv projection. Inspect only executable/argv[0]
        # and the launcher; never parse or retain later arguments or environment.
        mib = (ctypes.c_int * 3)(1, 49, pid)
        size = ctypes.c_size_t()
        if self.libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) or not 4 < size.value <= 1024 * 1024:
            return None
        buffer = ctypes.create_string_buffer(size.value)
        if self.libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0):
            return None
        raw = buffer.raw[:size.value]
        if int.from_bytes(raw[:4], sys.byteorder) < 2:
            return None
        end = raw.find(b'\0', 4)
        if end < 0:
            return None
        offset = end + 1
        while offset < len(raw) and raw[offset] == 0:
            offset += 1
        for index in range(2):
            end = raw.find(b'\0', offset)
            if end < 0:
                return None
            if index == 1:
                return os.fsdecode(raw[offset:end])
            offset = end + 1

    def _matches(self, pid, executable, provider):
        path = Path(executable)
        if provider == 'codex':
            return path.name == 'codex'
        if provider != 'claude':
            return False
        if path.name == 'claude' or path.parent == Path.home() / '.local/share/claude/versions':
            return True
        if path.name not in ('node', 'nodejs'):
            return False
        launcher = self._node_launcher(pid)
        if not launcher or not Path(launcher).is_absolute():
            return False
        try:
            return Path(launcher).resolve().parts[-4:] == ('node_modules', '@anthropic-ai', 'claude-code', 'cli.js')
        except OSError:
            return False

    def identify(self, peer_pid, provider='claude'):
        if not self.boot_id:
            return None
        original = self._read(peer_pid)
        pid, visited = peer_pid, set()
        for _ in range(64):
            if not pid or pid <= 1 or pid in visited:
                break
            visited.add(pid)
            info = self._read(pid)
            if info is None:
                break
            parent, started, executable = info
            if self._matches(pid, executable, provider):
                identity = ProcessIdentity(pid, started, self.boot_id)
                if self._read(peer_pid) == original and self.is_alive(identity):
                    return identity
                break
            pid = parent
        return None

    def is_alive(self, identity):
        if not self.boot_id or identity.boot_id != self.boot_id:
            return False
        info = self._read(identity.pid)
        return bool(info and info[1] == identity.start_ticks and self._matches(identity.pid, info[2], 'claude'))

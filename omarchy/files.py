"""Owned, private, atomic installation files."""
import os
from pathlib import Path
import stat
import tempfile

def directory(path):
    """Refuse symlink destinations or directories writable by other users."""
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError(f"Use an absolute destination: {path}")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            raise ValueError(f"Refusing a symbolic-link destination: {current}")
        current.mkdir(mode=0o700, exist_ok=True)
        info = current.stat()
        if not stat.S_ISDIR(info.st_mode) or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX):
            raise ValueError(f"Unsafe destination directory: {current}")
    if path.stat().st_uid != os.getuid():
        raise ValueError(f"Destination is not owned by you: {path}")


def write(path, data, mode=0o644):
    directory(path.parent)
    if path.is_symlink():
        raise ValueError(f"Refusing a symbolic-link file: {path}")
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)

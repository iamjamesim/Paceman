"""Read Claude's existing Linux login without refreshing or changing it."""
import json
import os
from pathlib import Path
import stat


def claude_token():
    path = Path(os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude'))) / '.credentials.json'
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise OSError('native session login must be private to this user')
        raw = stream.read(65537)
    if len(raw) > 65536:
        raise ValueError('invalid native login')
    record = json.loads(raw)
    value = record.get('claudeAiOauth') if isinstance(record, dict) else None
    token = value.get('accessToken') if isinstance(value, dict) else None
    if (not isinstance(token, str) or not token or '\r' in token or '\n' in token
            or not isinstance(value.get('scopes'), list)
            or 'user:sessions:claude_code' not in value['scopes']):
        raise ValueError('native session login unavailable')
    return token

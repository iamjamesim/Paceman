"""Explicit app-update handoff. Paths are supplied by the installed control boundary."""
from contextlib import closing, contextmanager
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import sqlite3
import subprocess
import tempfile
import time

from service.update_control import request

LABEL = 'ai.paceman.source'


def _write(path, value):
    fd, name = tempfile.mkstemp(prefix='.update-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output)
            output.flush()
            os.fsync(output.fileno())
        Path(name).replace(path)
    finally:
        Path(name).unlink(missing_ok=True)


@contextmanager
def _lock(root):
    with (root / 'update.lock').open('a') as lock:
        os.chmod(lock.name, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another Paceman update operation is running.')
        yield


def _revision(library):
    value = json.loads((library / 'build-info.json').read_text()).get('sourceRevision')
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{40}', value):
        raise ValueError('Paceman build information is unavailable. Reopen the installed app to repair it.')
    return value


def check_service_start(root):
    """Run before opening/migrating SQLite, including after logout or power loss."""
    if (root / 'update-stopped').exists():
        raise SystemExit(0)
    recorded = root / 'installed-app'
    if recorded.exists():
        embedded = Path(recorded.read_text().strip()) / 'Contents/Resources/lib'
        if (embedded / 'build-info.json').exists() and _revision(embedded) != _revision(root / 'lib'):
            raise SystemExit('Paceman components need updating. Open Paceman to finish installation.')


def _launch(*args):
    return subprocess.run(['/bin/launchctl', *args], capture_output=True, text=True, timeout=20)


def _target():
    return f'gui/{os.getuid()}/{LABEL}'


def _owned(root, plist, app):
    document = plistlib.loads(plist.read_bytes())
    arguments = document.get('ProgramArguments', [])
    if (document.get('Label') != LABEL or len(arguments) < 3
            or arguments[0] != str(app / 'Contents/MacOS/PacemanBackground')
            or arguments[2] != str(root)):
        raise ValueError('The Paceman background item needs repair before updating.')


def _stopped(root, timeout=12):
    from contextlib import ExitStack
    deadline = time.monotonic() + timeout
    while True:
        try:
            with ExitStack() as stack:
                for name in ('source.lock', 'push.lock'):
                    lock = stack.enter_context((root / 'data' / name).open('a'))
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise ValueError('Paceman is still stopping. Try the update again.')
            time.sleep(.1)


def _checkpoint(root):
    database = root / 'data/hub.sqlite3'
    destination = root / 'update-backup.sqlite3'
    fd, name = tempfile.mkstemp(prefix='.update-database-', dir=root)
    os.close(fd)
    temporary = Path(name)
    try:
        with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)) as source, \
                closing(sqlite3.connect(temporary)) as backup:
            source.backup(backup)
            identity = backup.execute("SELECT value FROM metadata WHERE key='source_id'").fetchone()
            if identity is None:
                raise ValueError('Paceman could not checkpoint its existing identity.')
            source_id = identity[0]
            if backup.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
                raise ValueError('Paceman could not verify its update checkpoint.')
        temporary.replace(destination)
        return source_id
    finally:
        temporary.unlink(missing_ok=True)


def prepare(root, plist, app):
    with _lock(root):
        _owned(root, plist, app)
        if (root / 'update-pending.json').exists():
            raise ValueError('Reopen Paceman to finish or recover the previous update.')
        paused = (root / 'sharing-paused').exists()
        loaded = _launch('print', _target()).returncode == 0
        if loaded == paused:
            raise ValueError('Paceman must be running, or Sharing must be turned off, before updating.')
        if _launch('print', f'gui/{os.getuid()}/ai.paceman.push').returncode == 0:
            raise ValueError('Reopen Paceman to finish upgrading its background item first.')
        journal = {'schema': 1, 'build': (root / 'installed-build').read_text().strip(),
                   'revision': _revision(root / 'lib'), 'wasLoaded': loaded, 'phase': 'stopping'}
        if loaded:
            request(root / 'update.sock', 'prepare')
        try:
            _write(root / 'update-pending.json', journal)
            _write(root / 'update-stopped', True)
            if loaded and _launch('bootout', _target()).returncode:
                raise ValueError('Paceman could not stop its background item.')
            _stopped(root)
            journal.update(sourceID=_checkpoint(root), phase='prepared')
            _write(root / 'update-pending.json', journal)
        except Exception:
            # Resume the unchanged build only. Never restore migrated data here.
            if (root / 'update-pending.json').exists():
                recover(root, plist, app, locked=True)
            elif loaded:
                request(root / 'update.sock', 'resume')
            raise


def wait_ready(root, expected, *, source_id=None, started=0, timeout=12):
    deadline = time.monotonic() + timeout
    while True:
        try:
            status = json.loads((root / 'status.json').read_text())
            if (status.get('running') is True and status.get('startedAt', 0) >= started
                    and 0 <= time.time() - status.get('updatedAt', 0) < 20
                    and status.get('serviceBuild') == expected
                    and (source_id is None or status.get('sourceID') == source_id)):
                request(root / 'update.sock', 'status')
                return
        except (OSError, ValueError, TypeError):
            pass
        if time.monotonic() >= deadline:
            raise ValueError('Paceman did not confirm the expected background build. Reopen Paceman to retry; the update checkpoint was kept.')
        time.sleep(.1)


def before_start(root):
    path = root / 'update-pending.json'
    if path.exists():
        journal = json.loads(path.read_text())
        journal['phase'] = 'starting'
        _write(path, journal)
    (root / 'update-stopped').unlink(missing_ok=True)


def complete(root):
    (root / 'update-stopped').unlink(missing_ok=True)
    (root / 'update-pending.json').unlink(missing_ok=True)


def recover(root, plist, app, *, locked=False):
    if not locked:
        with _lock(root):
            return recover(root, plist, app, locked=True)
    path = root / 'update-pending.json'
    if not path.exists():
        return
    _owned(root, plist, app)
    journal = json.loads(path.read_text())
    if journal.get('schema') != 1:
        raise ValueError('Paceman cannot recover this update record automatically. The checkpoint was kept.')
    build = str(plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleVersion'])
    if (journal.get('phase') == 'starting' and build != journal['build']
            and (root / 'installed-build').read_text().strip() == build
            and _revision(root / 'lib') == _revision(app / 'Contents/Resources/lib')):
        # The installer committed successfully but was interrupted before clearing
        # the handoff. Verify the current build, without restoring old code/data.
        from service.compatibility import service_build
        if not (root / 'sharing-paused').exists():
            wait_ready(root, service_build(root / 'lib'), source_id=journal.get('sourceID'))
        complete(root)
        return
    if build != journal['build'] or _revision(root / 'lib') != journal['revision']:
        raise ValueError('Open the updated Paceman app to finish installation. The previous database checkpoint was kept.')
    before_start(root)
    if journal['wasLoaded'] and not (root / 'sharing-paused').exists():
        if _launch('print', _target()).returncode:
            started = time.time()
            if _launch('bootstrap', f'gui/{os.getuid()}', str(plist)).returncode:
                _write(root / 'update-stopped', True)
                raise ValueError('Paceman could not restart. Reopen it to retry; your update checkpoint was kept.')
            from service.compatibility import service_build
            wait_ready(root, service_build(root / 'lib'), source_id=journal.get('sourceID'), started=started)
        else:
            request(root / 'update.sock', 'resume')
            from service.compatibility import service_build
            wait_ready(root, service_build(root / 'lib'), source_id=journal.get('sourceID'))
    complete(root)

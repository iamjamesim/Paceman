"""Small local compatibility snapshot; no credentials or conversation content."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import select
import shutil
import subprocess
import time

from service.codex_limits import codex_binary


# Checked against the versioned producer fixtures by test_compatibility.py.
AUDITED = {'codexDesktop': {'version': '26.1013.40934', 'build': '20770', 'stream': 11},
           'codexCLI': {'version': '0.163.0-alpha.10.2'}, 'claude': {'version': '2.1.304'}}
TRANSPORTS = {'codexDesktop': 'codex', 'codexDaemon': 'codex', 'claudeRemote': 'claude'}


def version(value):
    return value if isinstance(value, str) and len(value) <= 64 and re.fullmatch(
        r'[0-9]{1,8}(?:\.[0-9A-Za-z][0-9A-Za-z-]{0,15}){0,7}(?:[+-][0-9A-Za-z][0-9A-Za-z.-]{0,31})?', value) else 'unknown'


def service_build(root):
    """Installed source identity; the app bundle can have a different build."""
    root = Path(root)
    revision, fingerprint = 'unknown', 'unknown'
    try:
        raw = json.loads((root / 'build-info.json').read_text())
        value = raw.get('sourceRevision')
        if isinstance(value, str) and re.fullmatch(r'[0-9a-f]{40}', value):
            revision = value
    except (OSError, ValueError, AttributeError):
        pass
    try:
        digest = hashlib.sha256()
        files = sorted((root / 'service').glob('*.py'))
        if not 0 < len(files) <= 256:
            raise ValueError('Source unavailable')
        for path in files:
            if path.stat().st_size > 1_048_576:
                raise ValueError('Unexpected source size')
            digest.update(path.name.encode() + b'\0' + path.read_bytes())
        fingerprint = digest.hexdigest()[:16]
    except (OSError, ValueError):
        pass
    return {'sourceRevision': revision, 'serviceFingerprint': fingerprint}


def install_build(root):
    """Capture a checkout revision at installation, never infer it at runtime."""
    root = Path(root)
    result = service_build(root)
    if (root / '.git').exists():
        try:
            value = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'],
                                            stderr=subprocess.DEVNULL, timeout=2, text=True)
            value = value.strip() if isinstance(value, str) else ''
            if re.fullmatch(r'[0-9a-f]{40}', value):
                result['sourceRevision'] = value
        except (OSError, subprocess.SubprocessError):
            pass
    return result


def binary_version(binary):
    """Read at most 512 bytes for at most one second; never start a session."""
    if not binary:
        return 'unknown'
    try:
        with subprocess.Popen([str(binary), '--version'], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL) as process:
            data, deadline = bytearray(), time.monotonic() + 1
            try:
                while len(data) < 512 and time.monotonic() < deadline:
                    if not select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                        break
                    chunk = os.read(process.stdout.fileno(), 512 - len(data))
                    if not chunk:
                        break
                    data.extend(chunk)
                process.wait(timeout=max(.01, deadline - time.monotonic()))
                if process.returncode:
                    return 'unknown'
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        text = data.decode('utf-8').strip()
        match = re.fullmatch(r'(?:codex-cli )?([0-9][0-9A-Za-z.+-]{0,63})(?: \(Claude Code\))?', text)
        return version(match[1]) if match else 'unknown'
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        return 'unknown'


def installed_providers():
    result = {'codexDesktop': {'version': 'unknown', 'build': 'unknown'},
              'codexCLI': {'version': binary_version(codex_binary())},
              'claude': {'version': 'unknown'}}
    desktop = codex_binary(desktop_only=True)
    if desktop:
        try:
            bundle = next(p for p in Path(desktop).parents if p.suffix == '.app')
            info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
            if info.get('CFBundleIdentifier') == 'com.openai.codex':
                result['codexDesktop'] = {'version': version(info.get('CFBundleShortVersionString')),
                                          'build': version(info.get('CFBundleVersion'))}
        except (OSError, ValueError, AttributeError, StopIteration):
            pass
    claude = shutil.which('claude')
    if not claude:
        candidate = Path.home() / '.local/bin/claude'
        claude = candidate if candidate.is_file() and os.access(candidate, os.X_OK) else None
    result['claude']['version'] = binary_version(claude)
    return result


def adapter_snapshot(responders):
    """Nonblocking observations, taking no source lock or peer-adapter lock."""
    result = {}
    for name, responder in responders.items():
        if name not in TRANSPORTS:
            continue
        value = {'provider': TRANSPORTS[name], 'connection': 'unknown'}
        lock = getattr(responder, 'lock', None)
        if lock is not None and lock.acquire(blocking=False):
            try:
                value['connection'] = ('connected' if responder.connection is not None
                                       and not responder.stop.is_set() else 'disconnected')
                value['sessions'] = len(responder.owners if name == 'codexDesktop' else responder.ready)
                if name == 'codexDesktop':
                    from service.codex_desktop import STREAM_VERSION
                    value['protocolVersion'] = STREAM_VERSION
            finally:
                lock.release()
        elif name == 'claudeRemote':
            # Worker membership changes on the subscription loop. Copy it once;
            # each connected flag is observational, not permission to respond.
            try:
                workers = list(responder.workers.values())
                count = sum(bool(reducer.connected and not stop.is_set()) for stop, reducer, _ in workers)
                value.update(connection='connected' if count else 'disconnected', sessions=count)
            except (RuntimeError, AttributeError):
                pass
        result[name] = value
    return result


def report(root, status):
    """Actual running observations and installed versions remain separate."""
    running = status.get('serviceBuild') if status.get('running') else None
    build = service_build(root)
    origin = 'installedFiles'
    if isinstance(running, dict):
        revision, fingerprint = running.get('sourceRevision'), running.get('serviceFingerprint')
        build = {'sourceRevision': revision if isinstance(revision, str) and re.fullmatch(r'[0-9a-f]{40}', revision) else 'unknown',
                 'serviceFingerprint': fingerprint if isinstance(fingerprint, str) and re.fullmatch(r'[0-9a-f]{16}', fingerprint) else 'unknown'}
        origin = 'runningService'
    adapters = {}
    observed = status.get('nativeAdapters')
    for name, value in (observed if isinstance(observed, dict) else {}).items():
        if name in TRANSPORTS and isinstance(value, dict):
            connection = value.get('connection') if status.get('running') else 'unknown'
            adapters[name] = {'provider': TRANSPORTS[name],
                              'connection': connection if connection in ('connected', 'disconnected') else 'unknown'}
            if status.get('running') and type(value.get('sessions')) is int and 0 <= value['sessions'] <= 4096:
                adapters[name]['sessions'] = value['sessions']
            if name == 'codexDesktop' and type(value.get('protocolVersion')) is int and 0 <= value['protocolVersion'] < 2**16:
                adapters[name]['protocolVersion'] = value['protocolVersion']
    baseline = status.get('auditedBaseline') if origin == 'runningService' else AUDITED
    baseline = baseline if isinstance(baseline, dict) else {}
    audited = {name: {key: version((baseline.get(name) or {}).get(key))
                      for key in fields if key != 'stream'} for name, fields in AUDITED.items()
               if isinstance(baseline.get(name, {}), dict)}
    stream = (baseline.get('codexDesktop') or {}).get('stream') if isinstance(baseline.get('codexDesktop', {}), dict) else None
    audited.setdefault('codexDesktop', {})['stream'] = stream if type(stream) is int and 0 <= stream < 2**16 else 'unknown'
    return {'schema': 1, 'service': {**build, 'observation': origin},
            'installedProviders': installed_providers(), 'observedAdapters': adapters,
            'auditedBaseline': audited}

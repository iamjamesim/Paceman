"""Read Claude subscription limits using the existing Claude Code sign-in.

No credential copies, refresh-token rotation, browser scraping or model requests.
Keychain reads never prompt unless the user explicitly requests access in setup.
"""
from __future__ import annotations

import ctypes
import hashlib
import datetime as dt
import json
import math
import os
from pathlib import Path
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener, HTTPRedirectHandler

MAX_BYTES = 1_048_576


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_):
        return None  # Never forward the bearer token to a redirect destination.


def keychain_credentials(*, allow_prompt=False):
    if sys.platform != 'darwin':
        return None, 'sign_in_needed'
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    sec = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
    ptr = ctypes.c_void_p
    cf.CFStringCreateWithCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = ptr
    cf.CFDictionaryCreate.argtypes = [ptr, ctypes.POINTER(ptr), ctypes.POINTER(ptr), ctypes.c_long, ptr, ptr]
    cf.CFDictionaryCreate.restype = ptr
    cf.CFDataGetLength.argtypes = [ptr]
    cf.CFDataGetLength.restype = ctypes.c_long
    cf.CFDataGetBytePtr.argtypes = [ptr]
    cf.CFDataGetBytePtr.restype = ptr
    cf.CFGetTypeID.argtypes = [ptr]
    cf.CFGetTypeID.restype = ctypes.c_ulong
    cf.CFDataGetTypeID.restype = ctypes.c_ulong
    cf.CFRelease.argtypes = [ptr]
    sec.SecItemCopyMatching.argtypes = [ptr, ctypes.POINTER(ptr)]
    sec.SecItemCopyMatching.restype = ctypes.c_int32
    constant = lambda name: ptr.in_dll(sec, name).value
    service = cf.CFStringCreateWithCString(None, b'Claude Code-credentials', 0x08000100)
    keys = [constant('kSecClass'), constant('kSecAttrService'), constant('kSecReturnData'),
            constant('kSecMatchLimit'), constant('kSecUseAuthenticationUI')]
    values = [constant('kSecClassGenericPassword'), service, ptr.in_dll(cf, 'kCFBooleanTrue').value,
              constant('kSecMatchLimitOne'), constant('kSecUseAuthenticationUIAllow' if allow_prompt
                                                     else 'kSecUseAuthenticationUIFail')]
    query = cf.CFDictionaryCreate(None, (ptr * len(keys))(*keys), (ptr * len(values))(*values),
                                  len(keys), None, None)
    result = ptr()
    try:
        status = sec.SecItemCopyMatching(query, ctypes.byref(result))
        if status != 0:
            return None, 'sign_in_needed' if status == -25300 else 'access_needed'
        if cf.CFGetTypeID(result) != cf.CFDataGetTypeID():
            return None, 'sign_in_needed'
        size = cf.CFDataGetLength(result)
        if not 0 < size <= MAX_BYTES:
            return None, 'sign_in_needed'
        return json.loads(ctypes.string_at(cf.CFDataGetBytePtr(result), size)), 'ready'
    finally:
        if result.value:
            cf.CFRelease(result)
        cf.CFRelease(query)
        cf.CFRelease(service)


def credentials(*, allow_prompt=False):
    custom = os.environ.get('CLAUDE_CONFIG_DIR')
    root = Path(custom).expanduser() if custom else Path.home() / '.claude'
    path = root / '.credentials.json'
    if path.is_file():
        try:
            with path.open('rb') as handle:
                raw = handle.read(MAX_BYTES + 1)
            if len(raw) <= MAX_BYTES:
                return json.loads(raw), 'ready'
        except (OSError, ValueError):
            pass
    # A custom Claude profile must never borrow the default profile's account.
    if custom and root.absolute() != (Path.home() / '.claude').absolute():
        return None, 'sign_in_needed'
    try:
        return keychain_credentials(allow_prompt=allow_prompt)
    except (OSError, ValueError, TypeError, AttributeError):
        return None, 'access_needed'


def parse_claude_allowances(result, observed_at):
    if not isinstance(result, dict):
        return []
    readings = []
    for name, window, minutes in (('five_hour', 2, 300), ('seven_day', 1, 10080)):
        value = result.get(name)
        if value is None:
            continue
        if not isinstance(value, dict):
            return []
        used, reset = value.get('utilization'), value.get('resets_at')
        if type(used) not in (int, float) or not math.isfinite(used) or not 0 <= used <= 100:
            return []
        try:
            parsed = dt.datetime.fromisoformat(reset.replace('Z', '+00:00'))
            if parsed.utcoffset() is None:
                return []
            resets_at = int(parsed.timestamp())
        except (AttributeError, ValueError, TypeError, OverflowError):
            return []
        if not observed_at < resets_at <= 3155759999:
            return []
        readings.append(dict(provider='claude', remaining=int(math.floor(100 - used + .5)),
            window=window, windowDurationMins=minutes, updatedAt=observed_at, resetsAt=resets_at))
    return readings


def read_claude_allowances(*, allow_prompt=False, now=None, _credentials=None):
    """Return readings and a stable setup status; transient failures retain cache."""
    now = int(time.time()) if now is None else now
    document, status = _credentials if _credentials is not None else credentials(allow_prompt=allow_prompt)
    oauth = document.get('claudeAiOauth') if isinstance(document, dict) else None
    if not isinstance(oauth, dict):
        return [], status if status != 'ready' else 'sign_in_needed'
    token = oauth.get('accessToken')
    expiry = oauth.get('expiresAt')
    if (not isinstance(token, str) or not 1 <= len(token) <= 8192
            or any(ord(c) < 32 for c in token)):
        return [], 'sign_in_needed'
    if type(expiry) in (int, float) and expiry / 1000 <= now:
        return [], 'sign_in_needed'  # Claude owns refreshing its own sign-in.
    scopes = oauth.get('scopes')
    if isinstance(scopes, list) and 'user:profile' not in scopes:
        return [], 'sign_in_needed'
    request = Request('https://api.anthropic.com/api/oauth/usage', headers={
        'Authorization': 'Bearer ' + token, 'anthropic-beta': 'oauth-2025-04-20',
        'Accept': 'application/json', 'User-Agent': 'Paceman/0.1'})
    try:
        with build_opener(_NoRedirect()).open(request, timeout=8) as response:
            raw = response.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            return None, 'unavailable'
        readings = parse_claude_allowances(json.loads(raw), now)
        return readings, 'ready' if readings else 'unavailable'
    except HTTPError as error:
        error.close()
        return ([], 'sign_in_needed') if error.code in (401, 403) else (None, 'unavailable')
    except (OSError, URLError, ValueError, TypeError):
        return None, 'unavailable'


class ClaudeUsageReader:
    """Never retain another sign-in's quota after credentials change.

    A token rotation conservatively clears the old reading on transient failure.
    The fingerprint stays in memory and never enters snapshots or logs.
    """
    def __init__(self):
        self.owner = None

    def __call__(self):
        document, status = credentials()
        oauth = document.get('claudeAiOauth') if isinstance(document, dict) else None
        token = oauth.get('accessToken') if isinstance(oauth, dict) else None
        owner = hashlib.sha256(token.encode()).digest() if isinstance(token, str) else None
        changed = owner != self.owner
        self.owner = owner
        values, result = read_claude_allowances(_credentials=(document, status))
        return ([] if changed and values is None else values), result

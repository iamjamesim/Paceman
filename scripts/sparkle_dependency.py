"""Pinned official Sparkle binary, linked by the existing swiftc build."""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
from urllib.parse import urlsplit
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]


def update_settings(path):
    if path is None:
        return {}
    value = json.loads(Path(path).read_text())
    if (not isinstance(value, dict) or set(value) != {'feedURL', 'publicEDKey'}
            or not all(isinstance(item, str) for item in value.values())):
        raise ValueError('Updater configuration contains only feedURL and publicEDKey; never a private key')
    url = urlsplit(value['feedURL'])
    if (url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment):
        raise ValueError('The update feed must use a public HTTPS URL without credentials or query')
    try:
        key = base64.b64decode(value['publicEDKey'], validate=True)
    except (ValueError, TypeError):
        raise ValueError('The updater needs its publisher public Ed25519 key')
    if len(key) != 32:
        raise ValueError('The updater public Ed25519 key must contain 32 bytes')
    return {'SUFeedURL': value['feedURL'], 'SUPublicEDKey': value['publicEDKey'],
            'SUEnableAutomaticChecks': True, 'SUAllowsAutomaticUpdates': False,
            'SUAutomaticallyUpdate': False, 'SUVerifyUpdateBeforeExtraction': True,
            'SURequireSignedFeed': True, 'SUSignedFeedFailureExpirationInterval': 0,
            'SUEnableSystemProfiling': False}


def framework(archive, scratch):
    lock = json.loads((ROOT / 'macos/sparkle.json').read_text())
    if archive is None:
        archive = scratch / 'sparkle.tar.xz'
        with urlopen(lock['url'], timeout=60) as source, archive.open('wb') as target:
            shutil.copyfileobj(source, target)
    archive = Path(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != lock['sha256']:
        raise ValueError('Sparkle archive does not match macos/sparkle.json')
    destination = scratch / 'sparkle'
    destination.mkdir()
    with tarfile.open(archive) as source:
        # Python's tar filter preserves safe framework links and rejects traversal.
        source.extractall(destination, filter='data')
    result = destination / 'Sparkle.framework'
    if not (result / 'Sparkle').is_file() or not (destination / 'LICENSE').is_file():
        raise ValueError('Pinned Sparkle archive has no framework or license')
    return result


def embed(source, app):
    target = app / 'Contents/Frameworks/Sparkle.framework'
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, target, symlinks=True)
    notices = app / 'Contents/Resources/Notices'
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source.parent / 'LICENSE', notices / 'Sparkle-LICENSE')
    shutil.copy2(ROOT / 'macos/sparkle.json', notices / 'Sparkle-provenance.json')


def sign_nested(app, run, options):
    framework_path = app / 'Contents/Frameworks/Sparkle.framework'
    if framework_path.exists():
        version = framework_path / 'Versions/B'
        for path in (version / 'XPCServices/Downloader.xpc', version / 'XPCServices/Installer.xpc',
                     version / 'Updater.app', version / 'Autoupdate', framework_path):
            run('/usr/bin/codesign', *options, '--preserve-metadata=entitlements', path)

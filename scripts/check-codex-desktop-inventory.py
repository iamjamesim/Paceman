#!/usr/bin/env python3
"""Read-only release acceptance check; never executes the private desktop code.

Run with a locally installed bundle after auditing a desktop update. The pinned
source locations/symbols are evidence for one release, not a private API schema.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct


INVENTORY = Path(__file__).resolve().parents[1] / 'tests/fixtures/codex-desktop-inventory.json'


def asar_source(path, name):
    with path.open('rb') as stream:
        _, header_size, _, json_size = struct.unpack('<4I', stream.read(16))
        if not 0 < json_size <= header_size <= 16 * 1024 * 1024:
            raise ValueError('Unexpected ASAR header')
        entry = json.loads(stream.read(json_size))
        for part in name.split('/'):
            entry = entry['files'][part]
        if entry.get('unpacked') or not 0 < entry['size'] <= 32 * 1024 * 1024:
            raise ValueError('Unexpected desktop source entry')
        stream.seek(8 + header_size + int(entry['offset']))
        return stream.read(entry['size']).decode('utf-8')


def function_body(source, name):
    match = re.search(r'\bfunction ' + re.escape(name) + r'\(', source)
    if match is None:
        raise ValueError(f'Missing inventoried function {name}; re-audit the producer/UI')
    start = source.index('){', match.end()) + 1
    depth, quote, escaped = 0, None, False
    for index in range(start, len(source)):
        char = source[index]
        if quote:
            if escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == quote:
                quote = None
        elif char in "'\"`":
            quote = char
        elif char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError(f'Unterminated inventoried function {name}')


def extract_inventory(source):
    cases = lambda body: set(re.findall(r'case`([^`]+)`:', body))
    producer = cases(function_body(source, 'zS'))
    ui = cases(function_body(source, 'Pv')) - {'userInput', 'optionPicker', 'setupCodexStep'}
    dynamic = function_body(source, 'Lp')
    variables = re.findall(r'case ([A-Za-z_$][\w$]*):', dynamic)
    tools = {re.search(r'\b' + re.escape(name) + r'=`([^`]+)`', source).group(1) for name in variables}
    tools.update(re.findall(r'tool===`([^`]+)`', function_body(source, 'Mv')))
    modes = set(re.findall(r'\.mode(?:===|!==)`([^`]+)`', function_body(source, 'Sv')))
    item_source = ''.join(function_body(source, name) for name in ('Pv', 'Iv', '$v'))
    items = set(re.findall(r'\.type===`([^`]+)`', item_source))
    return dict(producer_methods=producer, ui_methods=ui, dynamic_tools=tools, mcp_modes=modes, ui_item_types=items)


def check_sets(actual, expected):
    for name, values in actual.items():
        wanted = set(expected[name])
        if values != wanted:
            raise ValueError(f'{name} changed: added={sorted(values - wanted)}, removed={sorted(wanted - values)}; re-audit coverage')


def verify(bundle):
    expected = json.loads(INVENTORY.read_text())
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier') != 'com.openai.codex'
            or info.get('CFBundleShortVersionString') != expected['desktop_version']
            or str(info.get('CFBundleVersion')) != expected['desktop_build']):
        raise ValueError('Desktop release differs from the audited inventory; re-audit before accepting the update')
    source = asar_source(bundle / 'Contents/Resources/app.asar', expected['source_path'])
    check_sets(extract_inventory(source), expected)
    if hashlib.sha256(source.encode()).hexdigest() != expected['source_sha256']:
        raise ValueError('Producer/UI implementation changed within this release; re-audit semantics')
    return expected


def verify_appserver(directory):
    expected = json.loads((INVENTORY.parent / 'codex-appserver-inventory.json').read_text())
    data = (directory / 'ServerRequest.json').read_bytes()
    schema = json.loads(data)
    methods = sorted(item['properties']['method']['enum'][0] for item in schema['oneOf'])
    if methods != expected['methods'] or hashlib.sha256(data).hexdigest() != expected['server_request_sha256']:
        raise ValueError('Public App Server request inventory changed; re-audit coverage')
    return expected


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--app-server-schema', type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.bundle)
        if args.app_server_schema:
            public = verify_appserver(args.app_server_schema)
            print(f"Verified public App Server {public['cli_version']}: {len(public['methods'])} server request methods.")
    except (OSError, ValueError, KeyError, AttributeError) as error:
        parser.exit(1, str(error) + '\n')
    print(f"Verified Codex {result['desktop_version']} ({result['desktop_build']}), stream {result['stream_version']}: "
          f"{len(result['producer_methods'])} producer methods, {len(result['ui_methods'])} UI cases, "
          f"{len(result['dynamic_tools'])} human dynamic tools, {len(result['mcp_modes'])} MCP modes.")

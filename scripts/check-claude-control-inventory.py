#!/usr/bin/env python3
"""Read-only release acceptance check of Claude's embedded control schema."""
import argparse
import hashlib
import json
from pathlib import Path
import re


INVENTORY = Path(__file__).resolve().parents[1] / 'tests/fixtures/claude-control-inventory.json'


def extract(schema, human):
    block = schema[schema.index('var D8=f(()=>['):schema.index(']),fn=f(', schema.index('var D8=f(()=>['))]
    roles = {}
    for variable, role in re.findall(r'_\(([$\w]+)\(\),"(agent|client|both)"', block):
        start = schema.index(variable + '=f(')
        subtype = re.search(r'subtype:T\("([^"]+)"\)', schema[start:start + 20000])
        if subtype is None:
            raise ValueError('Control schema changed; re-audit coverage')
        roles[subtype.group(1)] = role
    predicate = human.index('function C4e(e){return d.has(e.request.subtype)}')
    start = human.rfind('d=new Set([', 0, predicate)
    return roles, re.findall(r'"([^"]+)"', human[start:human.index('])', start)])


def verify(binary):
    expected = json.loads(INVENTORY.read_text())
    digest = hashlib.sha256()
    with binary.open('rb') as stream:
        while data := stream.read(1024 * 1024):
            digest.update(data)
        if digest.hexdigest() != expected['binary_sha256']:
            raise ValueError('Claude binary differs from the audited release; re-audit coverage')
        chunks = []
        for kind in ('schema', 'human'):
            start, end = expected[kind + '_chunk']
            stream.seek(start)
            data = stream.read(end - start)
            if hashlib.sha256(data).hexdigest() != expected[kind + '_sha256']:
                raise ValueError('Embedded schema changed; re-audit coverage')
            chunks.append(data.decode())
    roles, human = extract(*chunks)
    if roles != expected['control_subtypes'] or human != expected['human_subtypes']:
        raise ValueError('Control or human inventory changed; re-audit coverage')
    return expected


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.binary)
    except (OSError, ValueError, KeyError, AttributeError) as error:
        parser.exit(1, str(error) + '\n')
    print(f"Verified Claude Code {result['version']}: {len(result['control_subtypes'])} control variants, "
          f"{len(result['human_subtypes'])} native human subtypes.")

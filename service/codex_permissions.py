"""Explicit filesystem grants from Codex's native permission request.

The desktop's permission-policy filter can suppress broad writes. Only paths
that survive that filter in either detail mode are mirrored here. Network
requests need the owner's strict-auto-review context and remain native.
"""
from copy import deepcopy
from pathlib import Path


def decode_permissions(base, params, *, desktop=False):
    if (set(params) - {'threadId', 'turnId', 'itemId', 'cwd', 'permissions', 'reason',
                       'startedAtMs', 'environmentId'}
            or not all(isinstance(params.get(k), str) and params[k].strip()
                       for k in ('turnId', 'itemId', 'cwd'))
            or params.get('environmentId') is not None):
        return None
    permissions = params.get('permissions')
    if not isinstance(permissions, dict) or set(permissions) - {'fileSystem', 'network'}:
        return None
    if permissions.get('network') is not None:
        return None
    filesystem = permissions.get('fileSystem')
    if (not isinstance(filesystem, dict)
            or set(filesystem) - {'entries', 'read', 'write', 'globScanMaxDepth'}
            or filesystem.get('globScanMaxDepth') is not None):
        return None
    entries = filesystem.get('entries')
    if not isinstance(entries, list) or not 1 <= len(entries) <= 64:
        return None
    groups = {'read': [], 'write': []}
    for entry in entries:
        if (not isinstance(entry, dict) or set(entry) != {'access', 'path'}
                or not isinstance(entry.get('access'), str) or entry['access'] not in groups):
            return None
        path = entry['path']
        if not isinstance(path, dict) or set(path) != {'type', 'path'} or path['type'] != 'path':
            return None
        text = path['path']
        if (not isinstance(text, str) or not text.startswith('/') or len(text) > 4096
                or any(ord(c) < 32 for c in text) or '..' in text.split('/')):
            return None
        if desktop and entry['access'] == 'write':
            # Native kG/NG filters prose-mode writes outside the home directory,
            # the home directory itself, and Library. Never restore those grants.
            try:
                relative = Path(text).relative_to(Path.home())
            except ValueError:
                return None
            if not relative.parts or relative.parts[0].lower() == 'library':
                return None
        groups[entry['access']].append(text)
    # Current native requests carry both deprecated arrays and typed entries.
    # Accept the duplicate encoding only when it describes exactly the same
    # grants; never hide an extra legacy path behind the structured preview.
    if any(filesystem.get(access) is not None and filesystem[access] != groups[access]
           for access in groups):
        return None
    reason = params.get('reason')
    if reason is not None and (not isinstance(reason, str) or len(reason) > 4096):
        return None
    read_only = [p for p in groups['read'] if p not in groups['write']]
    display = '\n\n'.join(label + ':\n' + '\n'.join(dict.fromkeys(paths)) for label, paths in
        (('View contents', read_only), ('View and edit contents', groups['write'])) if paths)
    approval = dict(toolName='File access', input=deepcopy(params), inputKind='approvalRequest',
                    displayText=display, workingDirectory=params['cwd'])
    if reason:
        approval['reason'] = reason
    options = [('turn', 'Allow once')]
    # The desktop's prose UI offers no session grant. Its current detail mode
    # is not in the owner stream, so keep desktop grants scoped to this turn.
    if not desktop:
        options.append(('session', 'Allow for this session'))
    options.append(('deny', 'Deny'))
    public = dict(base, kind='approval', title='Allow file access?', contentVersion=2,
        approval=approval, responseOptions=[dict(id=key, label=label) for key, label in options])
    # These are PermissionGrantScope's native response variants. Keep the
    # complete requested profile, including nulls, rather than rebuilding it
    # from the human-readable display. An empty profile is the native denial.
    granted = deepcopy(permissions)

    def answer(response):
        option = response.get('optionID')
        if response.get('action') != 'choose' or option not in dict(options):
            return None
        result = dict(permissions={} if option == 'deny' else deepcopy(granted),
                      scope='session' if option == 'session' else 'turn')
        return 'thread-follower-permissions-request-approval-response', {'response': result}
    return public, answer

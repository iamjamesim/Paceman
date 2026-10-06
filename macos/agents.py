"""Selected local agent providers and their hook review metadata."""
import json
import os
import shlex
import shutil
from pathlib import Path

from macos.claude_hook import EVENTS as CLAUDE_EVENTS

PROVIDERS = ('codex', 'claude')
CLAUDE_PURPOSES = (
    ('SessionStart', 'show a new or resumed Claude session as idle'),
    ('UserPromptSubmit', 'show work after a new prompt'),
    ('PreToolUse', 'observe work and questions or plan approval'),
    ('PermissionRequest', 'show approval pending after five seconds'),
    ('PostToolUse', 'clear attention after the corresponding tool returns'),
    ('PostToolUseFailure', 'clear tool attention; observe an interrupt when supplied'),
    ('PostToolBatch', 'clear attention when the tool batch returns'),
    ('Elicitation', 'show an MCP input request after five seconds'),
    ('ElicitationResult', 'clear the corresponding MCP input request'),
    ('Stop', 'show a finished main turn'),
    ('StopFailure', 'show a failed main turn'),
    ('SessionEnd', 'remove a closed session'),
)


def claude_config_dir(root=None, *, home=None):
    home = home or Path.home()
    if root is not None:
        try:
            value = json.loads((root / 'agents.json').read_text()).get('claudeConfigDir')
            if isinstance(value, str) and Path(value).is_absolute():
                return Path(value)
        except (OSError, ValueError, AttributeError):
            pass
    if os.environ.get('CLAUDE_CONFIG_DIR'):
        return Path(os.environ['CLAUDE_CONFIG_DIR']).expanduser().absolute()
    return home / '.claude'


def provider_config(providers, root):
    return {'providers': providers, 'claudeConfigDir': str(claude_config_dir(root))}


def hook_path(provider, *, home=None, root=None):
    home = home or Path.home()
    return (home / '.codex/hooks.json' if provider == 'codex' else
            claude_config_dir(root, home=home) / 'settings.json')


def installed_hook_command(provider, root):
    """Show the actual retained command, which may use an older interpreter."""
    script = str(root / f"lib/macos/{provider}_hook.py")
    try:
        hooks = json.loads(hook_path(provider, root=root).read_text()).get('hooks', {})
        for groups in hooks.values():
            for group in groups:
                for item in group.get('hooks', []):
                    if item.get('type') != 'command':
                        continue
                    command = item.get('command', '')
                    arguments = shlex.split(command)
                    if (len(arguments) in (2, 3) and arguments[-1] == script
                            and (len(arguments) == 2 or arguments[1] == '-B')):
                        return command
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    return None


def configured_providers(root):
    try:
        value = json.loads((root / 'agents.json').read_text())['providers']
        if isinstance(value, list) and all(p in PROVIDERS for p in value):
            return list(dict.fromkeys(value))
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return ['codex']  # Existing installations keep their original provider.


def detected_providers(*, home=None, application_dirs=None, binary_dirs=None, root=None):
    """Installation hints only: never launch an agent or inspect credentials."""
    home = home or Path.home()
    application_dirs = application_dirs or (Path('/Applications'), home / 'Applications')
    from service.codex_limits import codex_binary
    result = ['codex'] if codex_binary(application_dirs=application_dirs) else []
    binary_dirs = binary_dirs if binary_dirs is not None else (
        home / '.local/bin', home / '.claude/local', Path('/opt/homebrew/bin'), Path('/usr/local/bin'))
    binaries = [directory / 'claude' for directory in binary_dirs]
    editors = ('.vscode', '.vscode-insiders', '.cursor', '.windsurf')
    if (shutil.which('claude') or any(p.is_file() and os.access(p, os.X_OK) for p in binaries)
            or any((directory / 'Claude.app').is_dir() for directory in application_dirs)
            or claude_config_dir(root, home=home).is_dir()
            or any(any((home / editor / 'extensions').glob('anthropic.claude-code-*'))
                   for editor in editors)):
        result.append('claude')
    return result

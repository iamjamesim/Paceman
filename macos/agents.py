"""Selected local agent providers and their hook review metadata."""
import json
import os
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


def configured_providers(root):
    try:
        value = json.loads((root / 'agents.json').read_text())['providers']
        if isinstance(value, list) and value and all(p in PROVIDERS for p in value):
            return list(dict.fromkeys(value))
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return ['codex']  # Existing installations keep their original provider.


def detected_providers():
    result = []
    from service.codex_limits import codex_binary
    if codex_binary():
        result.append('codex')
    home = Path.home()
    if (Path('/Applications/Claude.app').exists() or (home / '.claude').exists()
            or any((home / '.vscode/extensions').glob('anthropic.claude-code-*'))):
        result.append('claude')
    return result or ['codex']

# Codex hook provenance

Source: https://github.com/iamjamesim/omarchy-watch-codex
File: `plugins/omarchy-watch-codex/scripts/omarchy_watch_agent_hook.py`
Commit: `b874c7862f2688460a7e538df3e5f40f449adf45`
Imported: 2026-09-30
License: MIT; the original copyright and permission notice are retained in
`OMARCHY_WATCH_CODEX_LICENSE`.

Paceman's `codex_hook.py` adapts that Omarchy Watch-specific hook for Paceman's
Linux source. It uses Paceman's private runtime state directory and marks its
events so Paceman can prefer them while an older companion plugin is installed.
The installer and receiver changes are Paceman code. The separate Omarchy Watch
plugin remains available for its original product.

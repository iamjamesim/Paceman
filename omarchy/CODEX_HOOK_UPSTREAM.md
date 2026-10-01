# Codex hook provenance

Source: https://github.com/iamjamesim/omarchy-watch-codex
File: `plugins/omarchy-watch-codex/scripts/omarchy_watch_agent_hook.py`
Commit: `b874c7862f2688460a7e538df3e5f40f449adf45`
Imported: 2026-09-30
License: `omarchy/codex_hook.py`, including Paceman's changes to it, is MIT.
The original copyright and permission notice are retained in
`OMARCHY_WATCH_CODEX_LICENSE`.

Paceman's `codex_hook.py` adapts that Omarchy Watch-specific hook for Paceman's
Linux source. It uses Paceman's private runtime state directory and marks its
events so Paceman can prefer them while an older companion plugin is installed.
No other source file in `omarchy/` is imported from this plugin. The installer, panel,
controls, receiver in `service/omarchy.py`, and process checks in
`service/processes.py` are Paceman code under Apache License 2.0. The separate
Omarchy Watch plugin remains available for its original product.

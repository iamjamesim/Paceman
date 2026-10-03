"""Recognized app locations for drag installs and per-user source installs."""
from pathlib import Path
import sys


def installed_app() -> Path:
    locations = (Path("/Applications/Paceman.app"), Path.home() / "Applications/Paceman.app")
    for parent in Path(sys.executable).parents:
        if parent in locations:
            return parent
    try:
        recorded = Path((Path.home() / "Library/Application Support/Paceman/installed-app").read_text().strip())
        if recorded in locations:
            return recorded
    except OSError:
        pass
    return locations[1]

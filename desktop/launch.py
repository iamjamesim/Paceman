#!/usr/bin/python3 -I
"""Installed entry point; imports only from this application's directory."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from service.hub import main

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Compatibility entry point for retired Paceman response hooks.

Old agent configuration may still invoke this file after an upgrade. Exit without
reading input, contacting Paceman, or emitting a decision so the native prompt
runs immediately with its original content and complete response choices.
"""
import argparse
import sys


def run(provider, input_stream, output_stream):
    # Keep this entry point harmless even if old hook definitions remain loaded.
    return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", required=True, choices=("codex", "claude"))
    args = parser.parse_args()
    run(args.provider, sys.stdin.buffer, sys.stdout)


if __name__ == "__main__":
    main()

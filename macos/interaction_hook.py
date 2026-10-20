#!/usr/bin/env python3
"""Compatibility no-op for removed response hooks; native adapters own replies."""
import argparse
import sys


def run(provider, input_stream, output_stream):
    # Old reviewed configurations must never consume input or delay a prompt.
    pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", required=True, choices=("codex", "claude"))
    args = parser.parse_args()
    run(args.provider, sys.stdin.buffer, sys.stdout)


if __name__ == "__main__":
    main()

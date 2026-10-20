#!/usr/bin/env python3
"""Print assertion failures and individual test durations from an xcresult bundle."""
import json
import subprocess
import sys


def read_result(path, reference=None):
    command = ["xcrun", "xcresulttool", "get", "object", "--legacy", "--path", path, "--format", "json"]
    if reference:
        command.extend(["--id", reference])
    return json.loads(subprocess.check_output(command, text=True, timeout=30))


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def report(path):
    result = read_result(path)
    seen = set()
    print("Failed assertions:", flush=True)
    for node in nodes(result):
        for failure in node.get("testFailureSummaries", {}).get("_values", []):
            case = failure.get("testCaseName", {}).get("_value", "Unknown test")
            message = failure.get("message", {}).get("_value", "No failure message")
            location = failure.get("documentLocationInCreatingWorkspace", {}).get("url", {}).get("_value", "")
            identity = (case, message, location)
            if identity not in seen:
                seen.add(identity)
                print(f"FAIL {case} {location}")
                print("  " + message.replace("\n", "\n  "))
    if not seen:
        print("No assertion failures recorded; inspect the bundle for build or test-runner errors.")

    print("Individual test durations:", flush=True)
    for action in result.get("actions", {}).get("_values", []):
        reference = action.get("actionResult", {}).get("testsRef", {}).get("id", {}).get("_value")
        if not reference:
            continue
        for node in nodes(read_result(path, reference)):
            if node.get("_type", {}).get("_name") == "ActionTestMetadata":
                name = node.get("identifier", {}).get("_value", "Unknown test")
                status = node.get("testStatus", {}).get("_value", "Unknown")
                duration = node.get("duration", {}).get("_value", "unknown")
                print(f"{status} {duration}s {name}")


if __name__ == "__main__":
    report(sys.argv[1])

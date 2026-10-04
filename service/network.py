"""Shared private source route validation."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

from service.hub import endpoint

SOURCE = "http://127.0.0.1:8765"
ROUTE_MARKER = "tailscale-route.json"


class RouteSetupError(ValueError):
    """A phone connection prerequisite that the user can repair."""


def _binary():
    binary = shutil.which("tailscale")
    if binary:
        return binary
    if sys.platform == "darwin":
        # Finder and login items do not inherit the user's shell PATH.
        candidates = ("/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                      "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                      str(Path.home() / "Applications/Tailscale.app/Contents/MacOS/Tailscale"))
        for candidate in candidates:
            if Path(candidate).is_file() and os.access(candidate, os.X_OK):
                return candidate
    raise RouteSetupError("Install and connect Tailscale on this computer, then try again.")


def _config(binary):
    try:
        result = subprocess.run([binary, "serve", "status", "--json"], check=True,
                                capture_output=True, text=True, timeout=10)
        output = result.stdout.strip()
        if output in ("", "No serve config", "null"):
            return {}
        config = json.loads(output)
        if not isinstance(config, dict):
            raise ValueError("Unexpected Tailscale Serve status")
        return config
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise RouteSetupError("Connect Tailscale on this computer, then try again.") from error


def _source_hosts(config):
    return [host for host, web in config.get("Web", {}).items()
            if web.get("Handlers", {}).get("/", {}).get("Proxy") == SOURCE]


def _free_port(config):
    used = {str(port) for port in config.get("TCP", {})}
    used.update(host.rsplit(":", 1)[-1] for host in config.get("Web", {}))
    for port in range(8443, 8500):
        if str(port) not in used:
            return port
    raise RouteSetupError("Tailscale Serve has no free HTTPS port for Paceman.")


def _remember_route(state: Path, host: str, port: int):
    marker = state / ROUTE_MARKER
    if marker.is_symlink():
        raise RouteSetupError("Paceman's route record is a symbolic link; remove it and try again.")
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".tailscale-route-", dir=state)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump({"host": host, "port": port, "proxy": SOURCE}, output)
            output.write("\n")
        os.replace(temporary, marker)
    finally:
        Path(temporary).unlink(missing_ok=True)


def _verify(origin):
    try:
        with urllib.request.urlopen(origin + "/v1/snapshot", timeout=10):
            pass
    except urllib.error.HTTPError as error:
        with error:
            if error.code == 401:
                return
    except (OSError, ValueError) as error:
        raise RouteSetupError("Paceman's private Tailscale route is unreachable. Check Tailscale and try again.") from error
    raise RouteSetupError("Paceman's private Tailscale route is not reaching its source. Try again.")


def ensure_private_route(state: Path, *, verify=True):
    """Reuse a private route or create one without replacing another service."""
    binary = _binary()
    config = _config(binary)
    hosts = _source_hosts(config)
    if hosts:
        try:
            origin = private_endpoint(config)
        except ValueError as error:
            raise RouteSetupError("Paceman needs one private HTTPS Serve route with Funnel off; check Tailscale Serve settings.") from error
    else:
        port = _free_port(config)
        try:
            subprocess.run([binary, "serve", "--bg", f"--https={port}", SOURCE],
                           check=True, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError) as error:
            raise RouteSetupError("Tailscale could not enable private HTTPS Serve. Complete any Tailscale approval, then try again.") from error
        config = _config(binary)
        try:
            origin = private_endpoint(config)
        except ValueError as error:
            raise RouteSetupError("Tailscale did not create Paceman's private route. Check Serve settings and try again.") from error
        host = origin.removeprefix("https://")
        _remember_route(state, host, port)
    if verify:
        _verify(origin)
    return origin


def remove_owned_route(state: Path):
    """Remove only the unchanged Serve route that Paceman created."""
    marker = state / ROUTE_MARKER
    if not marker.is_file() or marker.is_symlink():
        return False
    try:
        record = json.loads(marker.read_text())
        host, port = record["host"], record["port"]
        if (not isinstance(host, str) or not isinstance(port, int)
                or record.get("proxy") != SOURCE or host.rsplit(":", 1)[-1] != str(port)):
            return False
        binary = _binary()
        config = _config(binary)
        web = config.get("Web", {}).get(host, {})
        if (config.get("TCP", {}).get(str(port)) != {"HTTPS": True}
                or web.get("Handlers") != {"/": {"Proxy": SOURCE}}
                or config.get("AllowFunnel", {}).get(host)):
            return False
        subprocess.run([binary, "serve", f"--https={port}", "off"], check=True,
                       capture_output=True, text=True, timeout=15)
        marker.unlink()
        return True
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        return False


def private_endpoint(config):
    # Only reuse a private HTTPS root proxy for this exact local source.
    origins = []
    for host, web in config.get("Web", {}).items():
        if web.get("Handlers", {}).get("/", {}).get("Proxy") != "http://127.0.0.1:8765":
            continue
        port = host.rsplit(":", 1)[-1]
        if not config.get("TCP", {}).get(port, {}).get("HTTPS"):
            continue
        if config.get("AllowFunnel", {}).get(host):
            continue
        origins.append(endpoint("https://" + host))
    if len(origins) != 1:
        raise ValueError("Configure one private Tailscale HTTPS route to 127.0.0.1:8765; see the platform setup guide.")
    return origins[0]

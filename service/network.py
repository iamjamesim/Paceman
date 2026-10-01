"""Shared private source route validation."""

from service.hub import endpoint


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

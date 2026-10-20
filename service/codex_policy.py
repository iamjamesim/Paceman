"""Read managed browser policy without loading or changing a native task."""
import subprocess
import time

from service.codex_limits import _response, _send, codex_binary


def read_browser_policy():
    binary = codex_binary()
    if binary is None:
        return None
    process = None
    try:
        process = subprocess.Popen([binary, 'app-server', '--stdio'], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        deadline = time.monotonic() + 8
        _send(process, dict(id=1, method='initialize', params=dict(
            clientInfo=dict(name='paceman', title='Paceman', version='0.1.0'),
            capabilities=dict(experimentalApi=True))))
        if not _response(process, 1, deadline):
            return None
        _send(process, dict(method='initialized', params={}))
        _send(process, dict(id=2, method='configRequirements/read', params={}))
        result = _response(process, 2, deadline)
        if 'requirements' not in result:
            return None
        requirements = result['requirements']
        if requirements is not None and not isinstance(requirements, dict):
            return None
        browser = (requirements or {}).get('browserUse')
        if browser is not None and not isinstance(browser, dict):
            return None
        allowed = (browser or {}).get('allowGlobalPersistentApproval')
        if allowed is not None and type(allowed) is not bool:
            return None
        # Codex's browser card permits global persistence unless managed
        # requirements explicitly forbid it. A failed read is not that default.
        return allowed is not False
    except (OSError, ValueError, OverflowError):
        return None
    finally:
        if process is not None:
            try:
                process.terminate()
                process.wait(timeout=1)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    process.kill()
                    process.wait(timeout=1)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            process.stdin.close()
            process.stdout.close()

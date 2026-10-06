# SPDX-License-Identifier: Apache-2.0
"""Run the ownership handshake against the production GATT callback."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

simulator = Path(__file__).resolve().parent
main = simulator.parent / "firmware" / "main"
source = (main / "watch_ble.c").read_text()
start = source.index("static int gatt_access(")
end = source.index("\nstatic const struct ble_gatt_svc_def services[]", start)
with tempfile.TemporaryDirectory(prefix="paceman-gatt-") as directory:
    build = Path(directory)
    (build / "gatt_access.inc").write_text(source[start:end])
    executable = build / "test-gatt"
    subprocess.run([
        *shlex.split(os.environ.get("CC", "cc")),
        "-std=c11", "-Wall", "-Wextra", "-Werror", "-UNDEBUG",
        "-fsanitize=address,undefined",
        "-I", str(main), "-I", str(build),
        str(simulator / "test_gatt.c"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)

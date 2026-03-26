"""
UFO2 stdio liveness probe.
Spawns a fresh ufo_mcp_server.py, sends MCP initialize + ping, exits.
Prints nothing on success; prints error to stderr on failure.
Exit code: 0 = healthy, 1 = failed.
"""
import json
import subprocess
import sys
import os
from pathlib import Path

UFO_DIR  = Path(__file__).parent.parent
PYTHON   = UFO_DIR.parent / "conda-envs" / "ufo" / "python.exe"
SERVER   = UFO_DIR / "ufo_mcp_server.py"

TIMEOUT  = 10  # seconds to wait for each response

def send(proc, msg: dict):
    line = json.dumps(msg, separators=(",", ":")) + "\n"
    proc.stdin.write(line.encode())
    proc.stdin.flush()

def recv(proc) -> dict | None:
    import select, time
    deadline = time.monotonic() + TIMEOUT
    buf = b""
    while time.monotonic() < deadline:
        # non-blocking read with timeout
        try:
            chunk = proc.stdout.read1(4096)  # type: ignore[attr-defined]
        except AttributeError:
            chunk = proc.stdout.read(4096)
        if chunk:
            buf += chunk
            if b"\n" in buf:
                line, _, buf = buf.partition(b"\n")
                try:
                    return json.loads(line.decode())
                except Exception:
                    pass
        if proc.poll() is not None:
            break
    return None

def main() -> int:
    if not PYTHON.exists():
        print(f"PROBE FAIL: python not found at {PYTHON}", file=sys.stderr)
        return 1
    if not SERVER.exists():
        print(f"PROBE FAIL: server not found at {SERVER}", file=sys.stderr)
        return 1

    env = os.environ.copy()
    env["PYTHONPATH"] = str(UFO_DIR)

    try:
        proc = subprocess.Popen(
            [str(PYTHON), str(SERVER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,  # suppress server startup noise
            cwd=str(UFO_DIR),
            env=env,
        )
    except Exception as e:
        print(f"PROBE FAIL: could not start server: {e}", file=sys.stderr)
        return 1

    try:
        # 1. initialize
        send(proc, {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "health-probe", "version": "1.0"}
            }
        })
        resp = recv(proc)
        if not resp or resp.get("id") != 1 or "result" not in resp:
            print(f"PROBE FAIL: bad initialize response: {resp}", file=sys.stderr)
            return 1

        # 2. initialized notification (no response expected)
        send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})

        # 3. ping
        send(proc, {"jsonrpc": "2.0", "id": 2, "method": "ping"})
        resp = recv(proc)
        if not resp or resp.get("id") != 2 or "result" not in resp:
            print(f"PROBE FAIL: bad ping response: {resp}", file=sys.stderr)
            return 1

        return 0  # healthy

    finally:
        try:
            proc.stdin.close()
            proc.kill()
            proc.wait(timeout=3)
        except Exception:
            pass

if __name__ == "__main__":
    sys.exit(main())

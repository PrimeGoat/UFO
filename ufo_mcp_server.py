"""
UFO2 MCP Server
===============
Exposes UFO2 (Windows UI Automation Agent) as MCP tools for Claude Code
or any other MCP-compatible agent/host.

WHAT UFO2 IS:
  UFO2 is a screen-understanding AI agent by Microsoft Research that:
  - Takes a screenshot and parses the UI with OmniParser (YOLO + Florence2)
  - Reasons about the task with a vision LLM (GPT-5.4 or Claude)
  - Plans multi-step action sequences
  - Executes UI actions: click, type, scroll, drag, keyboard shortcuts, app launch
  - Verifies completion and loops if needed (up to MAX_ROUND steps)

WHAT THIS MCP SERVER DOES:
  - Runs as a stdio MCP server (Claude Code connects via settings.json)
  - Accepts natural language tasks via `windows_task`
  - Launches UFO2 as a managed subprocess with proper env setup
  - Parses UFO2's structured JSON logs for clean results
  - Exposes agent status and logs via `ufo2_control`

TOOLS:
  windows_task(request, task_id?, timeout?)
    - Submit a Windows automation task. UFO2 will plan and execute it.

  ufo2_control(command, task_id?)
    - Subcommands: status | logs | config
    - status: health check (Python, OmniParser, GPU, recent tasks)
    - logs:   list/inspect task logs
    - config: show active LLM model and backend settings

REQUIREMENTS:
  - Conda env: D:/AI/conda-envs/ufo
  - OmniParser server on port 8010 (run start_server.bat — recommended but optional)
  - LLM API keys in config/ufo/agents.yaml (already configured)

ADDING TO CLAUDE CODE:
  Add to C:/Users/<user>/.claude/settings.json:
    "mcpServers": {
      "ufo2": {
        "type": "stdio",
        "command": "D:/AI/UFO/start_ufo_mcp.bat"
      }
    }
"""

import asyncio
import json
import os
import socket
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Literal

from fastmcp import FastMCP

# ── Paths ─────────────────────────────────────────────────────────────────────
UFO_DIR  = Path(__file__).parent
PYTHON   = UFO_DIR.parent / "conda-envs" / "ufo" / "python.exe"
LOGS_DIR = UFO_DIR / "logs"

# ── Helpers ───────────────────────────────────────────────────────────────────

def _omniparser_alive() -> bool:
    """Ping OmniParser server on port 8010."""
    try:
        with socket.create_connection(("127.0.0.1", 8010), timeout=1):
            return True
    except OSError:
        return False


def _parse_ufo_logs(task_id: str) -> dict:
    """
    Parse UFO2 structured JSON logs for a task.
    UFO writes per-step JSON lines to logs/{task_id}/*.json
    Returns: {complete, result, steps, error}
    """
    task_log_dir = LOGS_DIR / task_id
    result = {"steps": [], "complete": None, "result": None, "error": None}
    if not task_log_dir.exists():
        return result

    for log_file in sorted(task_log_dir.glob("*.json")):
        try:
            with open(log_file, encoding="utf-8", errors="replace") as f:
                raw = f.read().strip()
            # UFO logs are NDJSON (one JSON object per line) or a JSON array
            if raw.startswith("["):
                try:
                    entries = json.loads(raw)
                    if not isinstance(entries, list):
                        entries = [entries]
                except json.JSONDecodeError:
                    entries = []
            else:
                entries = []
                for line in raw.splitlines():
                    line = line.strip().rstrip(",")
                    if not line or line in ("[", "]"):
                        continue
                    try:
                        entries.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass

            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                if entry.get("complete"):
                    result["complete"] = entry["complete"]
                if entry.get("results"):
                    result["result"] = entry["results"]
                if entry.get("error") and not result["error"]:
                    result["error"] = entry["error"]
                # Collect step summaries
                step = {}
                for k in ("subtask", "action_type", "control_text", "status"):
                    if k in entry and entry[k]:
                        step[k] = entry[k]
                if step:
                    result["steps"].append(step)
        except Exception:
            pass

    return result


def _ufo_env() -> dict:
    """Build environment variables for the UFO2 subprocess."""
    env = os.environ.copy()
    env["PYTHONPATH"]          = str(UFO_DIR)
    env.setdefault("HF_HOME",               "D:/AI/cache/huggingface")
    env.setdefault("TORCH_HOME",             "D:/AI/cache/torch")
    env.setdefault("EASYOCR_MODULE_PATH",    "D:/AI/cache/easyocr")
    env.setdefault("PADDLE_PDX_CACHE_HOME",  "D:/AI/cache/paddlex")
    env.setdefault("YOLO_CONFIG_DIR",        "D:/AI/cache/ultralytics")
    env.setdefault("PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT", "False")
    env.setdefault("PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK", "True")
    return env


# ── MCP Server ────────────────────────────────────────────────────────────────

mcp = FastMCP(
    name="ufo2",
    instructions=(
        "UFO2 is a Windows UI automation agent (Microsoft Research). "
        "It visually understands the screen via OmniParser + Florence2, "
        "plans action sequences with GPT-5.4 or Claude, and executes them "
        "via Windows UIA/Win32. Use windows_task() to run any Windows task "
        "in natural language. Use ufo2_control() for status, logs, and config."
    ),
)


@mcp.tool()
async def windows_task(
    request: str,
    task_id: str = "",
    timeout: int = 300,
) -> str:
    """
    Run a Windows automation task using the UFO2 agent.

    UFO2 will: (1) screenshot the desktop, (2) parse UI elements with
    OmniParser, (3) reason + plan with GPT-5.4, (4) execute UI actions
    (click, type, scroll, launch apps, etc.), (5) verify and repeat until done.

    Examples
    --------
    - "Open Notepad and type 'Hello World', save to C:/temp/hello.txt"
    - "Close all open Chrome windows"
    - "Open Settings > System > About and tell me the Windows version"
    - "Download VLC from videolan.org and install it silently"
    - "Move all .pdf files from Downloads to D:/Documents/PDFs, make folder if needed"
    - "Find the largest file on the Desktop and delete it"

    Parameters
    ----------
    request : str
        Natural language description of what to do. Be specific about
        file paths, app names, and expected outcomes when relevant.
    task_id : str, optional
        Label for this task — used for log filenames. Auto-generated if omitted.
    timeout : int, optional
        Max seconds to wait. Default 300 (5 min). Increase for long installs.

    Returns
    -------
    str
        Structured result: completion status, steps taken, outcome, and errors.
    """
    if not task_id:
        task_id = f"mcp_{datetime.now().strftime('%Y%m%d_%H%M%S')}"

    omni_up = _omniparser_alive()
    warnings = []
    if not omni_up:
        warnings.append(
            "⚠ OmniParser server is offline (port 8010). "
            "Run D:/AI/OmniParser/start_server.bat for best accuracy. "
            "Continuing with Windows UIA only."
        )

    cmd = [
        str(PYTHON), "-m", "ufo",
        "--request", request,
        "--task",    task_id,
        "--log-level", "WARNING",
    ]

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            cwd=str(UFO_DIR),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=_ufo_env(),
        )

        # Pipe "N\n" to auto-answer the "any more requests?" prompt
        # that UFO shows after a task round completes.
        try:
            stdout_b, stderr_b = await asyncio.wait_for(
                proc.communicate(input=b"N\n"),
                timeout=float(timeout),
            )
        except asyncio.TimeoutError:
            try:
                proc.kill()
            except Exception:
                pass
            return (
                "\n".join(warnings + [
                    f"⏱ TIMEOUT after {timeout}s.",
                    f"UFO2 may still be running. Task logs: {LOGS_DIR / task_id}",
                ])
            )

        stdout = stdout_b.decode("utf-8", errors="replace").strip()
        stderr = stderr_b.decode("utf-8", errors="replace").strip()

        # Parse structured JSON logs
        logs = _parse_ufo_logs(task_id)

        # Build result
        parts = warnings[:]

        if logs.get("complete"):
            status_icon = "✅" if logs["complete"].lower() in ("yes", "true", "success") else "❌"
            parts.append(f"{status_icon} Completed: {logs['complete']}")
        elif proc.returncode == 0:
            parts.append("✅ UFO2 exited successfully")
        else:
            parts.append(f"❌ UFO2 exited with code {proc.returncode}")

        if logs.get("result"):
            parts.append(f"Result: {logs['result']}")

        if logs.get("steps"):
            step_lines = []
            for i, s in enumerate(logs["steps"][:15], 1):
                desc = s.get("subtask") or s.get("action_type") or str(s)
                target = f" → {s['control_text']}" if s.get("control_text") else ""
                step_lines.append(f"  {i}. {desc}{target}")
            parts.append(f"Steps ({len(logs['steps'])}):\n" + "\n".join(step_lines))

        if logs.get("error"):
            parts.append(f"Agent error: {logs['error']}")

        # Fallback: show console output if no structured logs
        if not logs.get("complete") and not logs.get("steps") and stdout:
            # Filter Rich markup and ANSI
            clean = "\n".join(
                l for l in stdout.splitlines()
                if l.strip() and not l.startswith("[") and "UFO" not in l[:5]
            )
            if clean:
                parts.append(f"Output:\n{clean[-2000:]}")

        # Show relevant errors
        if stderr and proc.returncode != 0:
            noise = {"RequestsDependencyWarning", "UserWarning", "warnings.warn",
                     "DeprecationWarning", "FutureWarning", "InsecureRequestWarning"}
            err_lines = [l for l in stderr.splitlines()
                         if l.strip() and not any(n in l for n in noise)]
            if err_lines:
                parts.append("Stderr (last 20 lines):\n" + "\n".join(err_lines[-20:]))

        parts.append(f"\n📁 Logs: {LOGS_DIR / task_id}")
        return "\n\n".join(parts)

    except FileNotFoundError:
        return (
            f"❌ UFO2 Python not found: {PYTHON}\n"
            "Ensure conda env exists: D:/AI/conda-envs/ufo"
        )
    except Exception as exc:
        return f"❌ Unexpected error: {type(exc).__name__}: {exc}"


@mcp.tool()
def ufo2_control(
    command: Literal["status", "logs", "config"],
    task_id: str = "",
) -> str:
    """
    Inspect and manage the UFO2 agent.

    Subcommands
    -----------
    status
        Full health check: Python env, config files, OmniParser server,
        GPU info, and recent task history.

    logs
        List all task logs with timestamps. Pass task_id to see the
        detailed step-by-step breakdown of a specific task.

    config
        Show active configuration: LLM model, API type, control backends,
        OmniParser endpoint, and key system settings.

    Parameters
    ----------
    command : "status" | "logs" | "config"
    task_id : str, optional
        Used with 'logs' to inspect a specific task.
    """
    if command == "status":
        lines = ["═══ UFO2 Agent Status ═══════════════════════════"]

        py_ok = PYTHON.exists()
        lines.append(f"  Python env : {PYTHON}  {'✓' if py_ok else '✗ MISSING'}")

        for cfg in ["agents.yaml", "system.yaml", "mcp.yaml", "rag.yaml"]:
            p = UFO_DIR / "config" / "ufo" / cfg
            lines.append(f"  Config {cfg:<12}: {'✓' if p.exists() else '✗ MISSING'}")

        omni = _omniparser_alive()
        lines.append(
            f"  OmniParser (8010) : {'✓ ONLINE' if omni else '✗ OFFLINE — run start_server.bat'}"
        )

        weights = Path("D:/AI/OmniParser/weights")
        lines.append(f"  Model weights     : {'✓' if weights.exists() else '✗ MISSING'}")

        try:
            r = subprocess.run(
                [str(PYTHON), "-c",
                 "import torch; print(torch.cuda.get_device_name(0),"
                 "torch.cuda.memory_allocated(0)//1024**2,'MB used')"],
                capture_output=True, text=True, timeout=10,
            )
            lines.append(f"  GPU               : {r.stdout.strip() or 'error'}")
        except Exception as e:
            lines.append(f"  GPU               : check failed ({e})")

        if LOGS_DIR.exists():
            tasks = sorted(LOGS_DIR.glob("*/"), key=lambda p: p.stat().st_mtime, reverse=True)
            lines.append(f"  Task logs         : {len(tasks)} total")
            if tasks:
                lines.append("  Recent tasks:")
                for t in tasks[:5]:
                    ts = datetime.fromtimestamp(t.stat().st_mtime).strftime("%m-%d %H:%M")
                    lines.append(f"    [{ts}] {t.name}")
        else:
            lines.append("  Task logs         : none yet")

        return "\n".join(lines)

    elif command == "logs":
        if task_id:
            log_dir = LOGS_DIR / task_id
            if not log_dir.exists():
                return f"No logs found for task '{task_id}'"
            data = _parse_ufo_logs(task_id)
            lines = [f"═══ Task: {task_id} ═══"]
            lines.append(f"Completed : {data.get('complete', 'unknown')}")
            if data.get("result"):
                lines.append(f"Result    : {data['result']}")
            if data.get("error"):
                lines.append(f"Error     : {data['error']}")
            if data.get("steps"):
                lines.append(f"\nSteps ({len(data['steps'])}):")
                for i, s in enumerate(data["steps"], 1):
                    lines.append(f"  {i:>3}. {s}")
            files = list(log_dir.glob("*"))
            lines.append(f"\nLog files: {', '.join(f.name for f in files)}")
            return "\n".join(lines)
        else:
            if not LOGS_DIR.exists():
                return "No task logs yet. Run windows_task() to create some."
            tasks = sorted(LOGS_DIR.glob("*/"), key=lambda p: p.stat().st_mtime, reverse=True)
            if not tasks:
                return "No task logs yet."
            lines = [f"═══ Task Logs ({len(tasks)} tasks) ═══"]
            for t in tasks[:30]:
                ts = datetime.fromtimestamp(t.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
                data = _parse_ufo_logs(t.name)
                status = data.get("complete", "?")
                lines.append(f"  [{ts}] {t.name}  → {status}")
            return "\n".join(lines)

    elif command == "config":
        import yaml
        lines = ["═══ UFO2 Active Configuration ═══════════════════"]
        for fname in ["agents.yaml", "system.yaml"]:
            path = UFO_DIR / "config" / "ufo" / fname
            if not path.exists():
                lines.append(f"\n[{fname}] NOT FOUND")
                continue
            with open(path) as f:
                data = yaml.safe_load(f)
            lines.append(f"\n[{fname}]")
            for k, v in data.items():
                if isinstance(v, dict):
                    lines.append(f"  {k}:")
                    for k2, v2 in list(v.items())[:8]:
                        display = "***REDACTED***" if "KEY" in k2.upper() else v2
                        lines.append(f"    {k2}: {display}")
                else:
                    lines.append(f"  {k}: {v}")
        return "\n".join(lines)

    return f"Unknown command '{command}'. Use: status | logs | config"


if __name__ == "__main__":
    mcp.run(transport="stdio")

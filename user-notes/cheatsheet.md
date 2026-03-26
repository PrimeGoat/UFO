# UFO2 + OmniParser + MCP — Sysadmin Cheat Sheet

---

## 1. OVERVIEW

UFO2 is a Windows UI automation agent (Microsoft Research) that accepts natural-language tasks and executes them against real Windows applications via UIA/Win32. OmniParser provides visual grounding (icon/text detection) as a fallback when UIA control resolution is insufficient. A FastMCP stdio wrapper (`ufo_mcp_server.py`) exposes the stack as MCP tools so that an orchestrating agent (Claude Code, Codex, etc.) can issue tasks and receive structured results without managing processes directly. UFO2 also acts as an MCP **client** internally, calling external tool servers defined in `mcp.yaml` — this is entirely separate from the wrapper described here.

---

## 2. COMPONENTS

| Component | Role | Process / Port | Location |
|---|---|---|---|
| UFO2 agent | Windows UI automation — HostAgent plans app steps, AppAgent plans per-app actions | subprocess (spawned per task) | `D:\AI\UFO\` |
| OmniParser server | Visual grounding: detects UI elements from screenshots via Florence2 + YOLO | HTTP `:8010` | `D:\AI\OmniParser\` |
| OmniParser Gradio demo | Diagnostic UI for testing OmniParser manually | HTTP `:7861+` (optional) | `D:\AI\OmniParser\` |
| ufo_mcp_server.py | MCP stdio wrapper — receives tool calls, spawns UFO2, parses logs, returns results | stdio (FastMCP) | `D:\AI\UFO\ufo_mcp_server.py` |
| Florence2 | Visual backbone model loaded by OmniParser | in-process (OmniParser) | weights in `D:\AI\OmniParser\weights\` |
| Windows UIA + pywinauto | Primary control resolution and action execution | in-process (UFO2) | no separate process |
| Conda env: `ufo` | Python env for UFO2 and MCP server | — | `D:\AI\conda-envs\ufo` |
| Conda env: `omniparser` | Python env for OmniParser | — | `D:\AI\conda-envs\omniparser` |

---

## 3. EXTERNAL DEPENDENCIES

| Dependency | Purpose | Notes |
|---|---|---|
| OpenAI API | GPT-5.4 for HostAgent + AppAgent reasoning | `OPENAI_API_KEY` env var required |
| Anthropic API | Claude, alternate model backend | `ANTHROPIC_API_KEY` env var; optional |
| Windows 10/11 | UIA, Win32 | Linux/Mac not supported |
| CUDA / RTX GPU | Florence2 + OmniParser icon detection | RTX 3090 in use |
| Conda | Environment management | Both envs must exist before starting |
| HuggingFace Hub | Florence2 + icon detector weights | Downloaded once; stored locally |
| Bing Search API | RAG online search (when enabled in `rag.yaml`) | Optional |
| FastMCP 2.11.3 | MCP server framework for `ufo_mcp_server.py` | pip install fastmcp==2.11.3 |

---

## 4. COMPONENT INTERACTION MODEL

```
Caller (Claude Code / Codex)
  └─> MCP protocol (stdio, JSON-RPC)
      └─> ufo_mcp_server.py  [FastMCP, conda env: ufo]
          └─> subprocess: python -m ufo --task "..."
              └─> UFO2 agent loop:
                    HostAgent  (GPT-5.4)       plans app-level steps
                    AppAgent   (GPT-5.4)       plans per-app actions
                    OmniParser (HTTP :8010)    visual grounding fallback
                    Windows UIA (in-proc)      primary control resolution
                    pywinauto / Win32          executes clicks, keystrokes
          └─> UFO2 exits; writes NDJSON logs to .\logs\
          └─> ufo_mcp_server.py parses logs → structured result → caller
```

> **Separate concern:** UFO2 also calls *outbound* MCP tool servers as a client (config: `mcp.yaml`). This is independent of the wrapper above.

---

## 5. KEY CONFIGURATION FILES

| File | Controls | Critical Values |
|---|---|---|
| `config\ufo\agents.yaml` | Model, API_BASE, API_KEY, params for all agents | `API_BASE: https://api.openai.com/v1/` — base URL only; SDK appends endpoint paths. Full URL causes malformed requests. |
| `config\ufo\agents_openai.yaml` | OpenAI-specific overrides per agent | Supplements `agents.yaml` for OpenAI models |
| `config\ufo\agents_claude.yaml` | Claude-specific config per agent | No `API_BASE` needed (different SDK) |
| `config\ufo\system.yaml` | SAFE_GUARD, MAX_ROUND, CONTROL_BACKEND, OmniParser endpoint | `SAFE_GUARD: False` required for MCP/unattended operation |
| `config\ufo\mcp.yaml` | UFO2 outbound MCP client tool servers | LinuxAgent BashExecutor → port **8012** (not 8010). Port 8010 = OmniParser only. |
| `config\ufo\rag.yaml` | All RAG settings | `RAG_EXPERIENCE`, `RAG_DEMONSTRATION`, `RAG_ONLINE_SEARCH`, etc. |
| `config\ufo\prices.yaml` | Token cost tracking per model | Must include every model in use. Added: `gpt-5.4`, `claude-opus-4-6` |
| `D:\AI\OmniParser\gradio_demo.py` | Demo port | Auto-detects free port from 7861. Override: `OMNIPARSER_DEMO_PORT` env var |
| `D:\Claude\.mcp.json` | MCP server registration (project-level) | Registers `ufo2` tool for Claude Code in this project |
| `C:\Users\Denis\.claude\mcp.json` | MCP server registration (user-level, global) | Global registration across all projects |

**Must-know conventions:**

- `PYTHONIOENCODING=utf-8` must be set before running `ufo_mcp_server.py`. Windows CP1252 console cannot encode UFO2's Unicode output.
- OmniParser is always on **port 8010**. Changing it requires updating `system.yaml` OMNIPARSER endpoint and all health check references.
- `SAFE_GUARD: False` is mandatory for any unattended/MCP-driven operation.
- `REASONING_MODEL: True` per agent suppresses `temperature`/`top_p` params (required for reasoning models that reject those at API level).

---

## 6. LOG FILES

| Path | Contents | Written When |
|---|---|---|
| `.\logs\<task_id>\*.ndjson` | Structured action log (JSON lines) | Each task run |
| `.\logs\<task_id>\*.png` | Per-step screenshots | Each task run |
| `.\logs\<task_id>\response*.log` | Raw LLM responses | Each task run |
| `D:\AI\OmniParser\logs\` | OmniParser server logs | Server runtime |

`.\logs\` is excluded from git (`.gitignore`). `ufo_mcp_server.py` reads NDJSON logs post-task to build the structured MCP response.

---

## 7. STARTUP / SHUTDOWN ORDER

Order matters — later steps depend on earlier ones.

### Startup

| Step | Command | Health Check |
|---|---|---|
| 1. OmniParser server | `D:\AI\OmniParser\start_server.bat` | `GET http://localhost:8010/health` → 200 |
| 2. UFO2 MCP server | `D:\AI\UFO\start_ufo_mcp.bat` | `ufo2_control("status")` → all-green |
| 3. Gradio demo *(optional)* | `D:\AI\OmniParser\start_demo.bat` | Browser: `http://localhost:7861` |

### Shutdown (reverse order)

1. Gradio demo — Ctrl+C or kill python process
2. UFO2 MCP server — Ctrl+C or kill python process
3. OmniParser server — Ctrl+C or kill uvicorn process

### PowerShell management scripts *(Assignment 3)*

```
.\scripts\Start-UFO2Stack.ps1
.\scripts\Stop-UFO2Stack.ps1
.\scripts\Restart-UFO2Stack.ps1
.\scripts\Get-UFO2Status.ps1
.\scripts\Invoke-UFO2Cleanup.ps1
```

If Assignment 3 is not yet complete, use the `.bat` files above. Kill processes manually via Task Manager or `taskkill /IM python.exe /F`.

---

## 8. MCP TOOL CONFIGURATION

### Registration — Option A: project-level (`D:\Claude\.mcp.json`)

```json
{
  "mcpServers": {
    "ufo2": {
      "type": "stdio",
      "command": "cmd",
      "args": ["/c", "D:\\AI\\UFO\\start_ufo_mcp.bat"]
    }
  }
}
```

### Registration — Option B: user-level (global)

```
claude mcp add ufo2 --transport stdio --scope user "cmd" "/c" "D:\AI\UFO\start_ufo_mcp.bat"
```

---

### Available Tools

#### `windows_task(request, task_id?, timeout?)`
Run any Windows task in natural language.
- **Returns:** status, summary, actions taken, round count, errors
- **Requires:** OmniParser running on port 8010
- **Example:** `windows_task("open Notepad and type Hello World")`

#### `ufo2_control(command, task_id?)`
Inspect and manage the UFO2 stack.

| Command | Returns |
|---|---|
| `status` | Python env, config files, OmniParser health, GPU status |
| `logs` | Recent task log content (use `task_id` to target specific task) |
| `config` | Dump current effective configuration values |

---

### Prerequisites Before Calling `windows_task`

- OmniParser server running and healthy on port 8010
- `OPENAI_API_KEY` set in environment
- UFO2 MCP server process running (`start_ufo_mcp.bat` active)

**Quick health check:** `ufo2_control("status")` → should return all-green + OmniParser ONLINE

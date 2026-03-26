@echo off
:: UFO2 MCP Server — stdio transport for Claude Code / MCP clients
::
:: Registers UFO2 as an MCP tool. Add to Claude Code settings.json:
::   "mcpServers": {
::     "ufo2": { "type": "stdio", "command": "D:/AI/UFO/start_ufo_mcp.bat" }
::   }
::
:: NOTE: OmniParser server should already be running on port 8010.
:: Run D:\AI\OmniParser\start_server.bat in a separate terminal first.

cd /d D:\AI\UFO
call conda activate D:\AI\conda-envs\ufo
python ufo_mcp_server.py

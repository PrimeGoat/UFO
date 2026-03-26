"""Test UFO2 MCP server — verifies imports, tools registered, and helper logic."""
import sys, asyncio, os
sys.path.insert(0, "D:/AI/UFO")
os.environ["PYTHONIOENCODING"] = "utf-8"

print("1. Importing ufo_mcp_server...")
import ufo_mcp_server as srv
print("   Server name:", srv.mcp.name)

print("2. Checking tools registered...")
tools = asyncio.run(srv.mcp._tool_manager.list_tools())
tool_names = [t.name for t in tools]
print("   Tools:", tool_names)
assert "windows_task" in tool_names
assert "ufo2_control" in tool_names
print("   Both tools registered - OK")

print("3. Testing helpers...")
print("   OmniParser alive:", srv._omniparser_alive())
print("   PYTHON exists:", srv.PYTHON.exists())
print("   UFO_DIR:", srv.UFO_DIR)

print("4. Testing ufo2_control('status') via tool.fn...")
ctrl_tool = next(t for t in tools if t.name == "ufo2_control")
result = ctrl_tool.fn(command="status")
print(result)

print("\n5. Testing ufo2_control('config')...")
result2 = ctrl_tool.fn(command="config")
print(result2[:800])

print("\nAll checks passed!")

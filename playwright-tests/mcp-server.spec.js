// @ts-check
/**
 * UFO2 MCP server smoke tests.
 * These test the MCP server indirectly by calling the underlying
 * Python helpers and checking the UFO2 environment health.
 *
 * Full end-to-end task tests require UFO2 to be running and are
 * in the "e2e" group — skipped by default in CI.
 */
const { test, expect } = require("@playwright/test");
const { execSync } = require("child_process");
const path = require("path");

const PYTHON = "D:\\AI\\conda-envs\\ufo\\python.exe";
const UFO_DIR = "D:\\AI\\UFO";

test.describe("UFO2 environment health", () => {
  test("Python env exists", () => {
    const fs = require("fs");
    expect(fs.existsSync(PYTHON)).toBe(true);
  });

  test("key config files exist", () => {
    const fs = require("fs");
    const configs = [
      "config/ufo/agents.yaml",
      "config/ufo/system.yaml",
      "config/ufo/mcp.yaml",
    ];
    for (const cfg of configs) {
      expect(fs.existsSync(path.join(UFO_DIR, cfg))).toBe(true);
    }
  });

  test("ufo_mcp_server.py exists", () => {
    const fs = require("fs");
    expect(fs.existsSync(path.join(UFO_DIR, "ufo_mcp_server.py"))).toBe(true);
  });

  test("OmniParser server on port 8010 is reachable", async ({ request }) => {
    const res = await request.get("http://localhost:8010/probe/");
    expect(res.ok()).toBeTruthy();
  });

  test("fastmcp importable in ufo env", () => {
    const out = execSync(
      `"${PYTHON}" -c "import fastmcp; print(fastmcp.__version__)"`,
      { encoding: "utf-8" }
    ).trim();
    expect(out.length).toBeGreaterThan(0);
  });
});

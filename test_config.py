"""Quick test of UFO2 config loading and dependencies."""
import sys
sys.path.insert(0, "D:/AI/UFO")

print("Testing config loader...")
from config.config_loader import get_ufo_config
cfg = get_ufo_config()
print(f"  HOST_AGENT model: {cfg.host_agent.api_model}")
print(f"  HOST_AGENT type:  {cfg.host_agent.api_type}")
print(f"  APP_AGENT  model: {cfg.app_agent.api_model}")

import yaml
with open("D:/AI/UFO/config/ufo/system.yaml") as f:
    sys_cfg = yaml.safe_load(f)
print(f"  SAFE_GUARD:        {sys_cfg.get('SAFE_GUARD')}")
print(f"  CONTROL_BACKEND:   {sys_cfg.get('CONTROL_BACKEND')}")
print(f"  OMNIPARSER endpoint: {sys_cfg.get('OMNIPARSER', {}).get('ENDPOINT')}")
print(f"  MAX_ROUND:         {sys_cfg.get('MAX_ROUND')}")
print(f"  SAVE_EXPERIENCE:   {sys_cfg.get('SAVE_EXPERIENCE')}")

print("\nTesting key imports...")
import pywinauto; print("  pywinauto: OK")
import pyautogui; print("  pyautogui: OK")
import faiss; print("  faiss: OK")
import anthropic; print("  anthropic: OK")
import openai; print("  openai: OK")
import fastmcp; print("  fastmcp: OK")
import uvicorn; print("  uvicorn: OK")
import aiohttp; print("  aiohttp: OK")

print("\nAll checks passed!")

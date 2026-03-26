@echo off
:: UFO launcher — runs in the ufo conda environment
:: Usage: run.bat "your task description"
::
:: To switch to Claude:
::   copy config\ufo\agents_claude.yaml config\ufo\agents.yaml
:: To switch back to GPT:
::   copy config\ufo\agents_openai.yaml config\ufo\agents.yaml

cd /d %~dp0
call conda activate D:\AI\conda-envs\ufo
python -m ufo --task %*

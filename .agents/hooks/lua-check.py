#!/usr/bin/env python3
"""Run each edited repository's Lua checks for Claude file edits or Codex patches."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parents[2]
    dispatch = Path(sys.argv[1]).expanduser().resolve() if len(sys.argv) > 1 else None
    event = json.load(sys.stdin)
    cwd = Path(event.get("cwd") or root)
    tool_input = event.get("tool_input") or {}
    response = event.get("tool_response") or {}
    paths = []
    if isinstance(tool_input, dict):
        if tool_input.get("file_path"):
            paths.append(tool_input["file_path"])
        patch = tool_input.get("command") or ""
    else:
        patch = tool_input
    if isinstance(response, dict) and response.get("filePath"):
        paths.append(response["filePath"])
    paths.extend(re.findall(r"^\*\*\* (?:Add File: |Update File: |Delete File: |Move to: )(.+)$", patch, re.MULTILINE))

    repos = {}
    for name in paths:
        path = Path(name).expanduser()
        path = (cwd / path).resolve()
        if path.suffix != ".lua":
            continue
        if path.is_relative_to(root):
            owner = root
        elif dispatch and path.is_relative_to(dispatch) and len(path.relative_to(dispatch).parts) > 1:
            owner = dispatch / path.relative_to(dispatch).parts[0]
        else:
            continue
        repos[owner] = None

    failed = False
    env = os.environ.copy()
    env.pop("NVIM", None)
    env.pop("NVIM_LISTEN_ADDRESS", None)
    for repo in repos:
        check = repo / "tests/check-edit.sh"
        if not check.is_file():
            print(f"no Lua edit check at {check}; this edit was NOT verified", file=sys.stderr)
            failed = True
            continue
        result = subprocess.run(["bash", str(check)], cwd=repo, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        if result.returncode:
            print(f"Lua checks failed in {repo}:\n{result.stdout}{result.stderr}", file=sys.stderr)
            failed = True
    return 2 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError) as error:
        print(f"Lua edit hook failed: {error}", file=sys.stderr)
        sys.exit(2)

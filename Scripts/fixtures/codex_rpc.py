#!/usr/bin/env python3
"""Offline Codex app-server fixture for packaged CLI compatibility checks."""
import json
import os
import sys
from pathlib import Path

if sys.argv[1:] == ["--version"]:
    print("codex-cli 0.0.0")
    raise SystemExit(0)
if sys.argv[1:] != ["-s", "read-only", "-a", "never", "app-server"]:
    raise SystemExit("Unexpected fixture arguments: " + repr(sys.argv[1:]))

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    with Path(os.environ["CODEXBAR_RPC_FIXTURE_LOG"]).open("a", encoding="utf-8") as log:
        log.write(method + "\n")
    if method == "initialized":
        continue
    if method == "initialize":
        result = {}
    elif method == "account/rateLimits/read":
        result = {"rateLimits": {
            "planType": "plus",
            "primary": {"usedPercent": 24, "windowDurationMins": 300, "resetsAt": 2000000000},
            "secondary": {"usedPercent": 38, "windowDurationMins": 10080, "resetsAt": 2000100000},
            "credits": {"hasCredits": True, "unlimited": False, "balance": "18.75"},
        }}
    elif method == "account/read":
        result = {"account": {"type": "chatgpt", "email": "codex@example.test", "planType": "plus"},
                  "requiresOpenaiAuth": False}
    else:
        raise SystemExit("Unexpected fixture method: " + str(method))
    print(json.dumps({"id": request["id"], "result": result}), flush=True)

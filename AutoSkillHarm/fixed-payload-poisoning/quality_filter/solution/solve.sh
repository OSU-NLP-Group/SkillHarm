#!/bin/bash
# Oracle solution: produces a structurally-valid `discard` verdict for every
# sample with an explicit ORACLE PLACEHOLDER marker in each reason description,
# so any downstream consumer can spot oracle outputs and refuse them.
#
# Discard-by-default is the SAFE oracle bias: a researcher accidentally
# importing oracle output into the benchmark drops samples instead of
# inflating false-positive keeps. The real verdict is whatever the filter
# agent writes.
set -e

python3 << 'EOF'
import json
from pathlib import Path

with open("/root/manifest.json") as f:
    manifest = json.load(f)

with open("/root/identity.json") as f:
    identity = json.load(f)

result = {
    "task_id": identity["task_id"],
    "target_path": identity["target_path"],
    "target_slug": identity["target_slug"],
    "risk_id": identity["risk_id"],
    "design_agent_id": identity["design_agent_id"],
    "sample_verdicts": [
        {
            "sample_id": entry["sample_id"],
            "realization": entry["realization"],
            "verdict": "discard",
            "reasons": [
                {
                    "category": "other",
                    "description": "ORACLE PLACEHOLDER — no analysis performed.",
                }
            ],
        }
        for entry in manifest
    ],
}

Path("/root/output").mkdir(parents=True, exist_ok=True)
with open("/root/output/filter_result.json", "w") as f:
    json.dump(result, f, indent=2)
EOF

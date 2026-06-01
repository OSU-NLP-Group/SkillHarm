#!/usr/bin/env python3
"""Convert gemini-cli's per-session JSONL chat log into the JSON-object shape
harbor's `_convert_gemini_to_atif` expects.

Background
----------
gemini-cli writes session logs as JSON Lines at
    ~/.gemini/tmp/<project_hash>/chats/session-<ts>-<id>.jsonl
The first line carries session metadata (`sessionId`, `kind="main"`);
subsequent lines are either message events (`type` ∈ {"user","gemini"}) or
`$set` patches that mutate `lastUpdated`. Harbor's gemini_cli.py post-run
hook greps for `session-*.json` (no `l`) and `cp`s the first match — neither
matches anything because the files are `.jsonl` and live one dir deeper.

Rather than patch the user's harbor install, eval.sh bind-mounts
`/root/.gemini/tmp` out of the container to a per-sample host dir; this
script then walks that host dir on the host side after harbor returns and
materializes a trajectory.json that harbor's downstream converter would have
produced if its post-run hook had worked.

Usage
-----
    _convert_gemini_session.py <gemini_tmp_host_dir> <out_trajectory_json>

Exits 0 silently if no session file is present (e.g. the agent crashed
before writing the first event); never raises so eval.sh can call it
unconditionally without polluting the per-sample log on benign misses.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: _convert_gemini_session.py <gemini_tmp_dir> <out_traj_json>",
            file=sys.stderr,
        )
        return 2

    src_dir = Path(sys.argv[1])
    out_path = Path(sys.argv[2])

    if not src_dir.is_dir():
        return 0  # nothing to convert

    candidates = sorted(
        src_dir.rglob("session-*.jsonl"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        return 0  # benign — agent didn't reach a model turn

    session_id = "unknown"
    messages: list[dict] = []
    with candidates[0].open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if "$set" in obj:
                continue  # lastUpdated patch event
            if "sessionId" in obj and "kind" in obj:
                session_id = obj["sessionId"]
                continue
            if obj.get("type") in ("user", "gemini"):
                messages.append(obj)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps({"sessionId": session_id, "messages": messages}, indent=2)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Honors Docker ENTRYPOINT + CMD composition after the wrapper finishes setup.

Reads the source Dockerfile's original ENTRYPOINT (if any) from the env var
SKILLHARM_ORIGINAL_ENTRYPOINT_JSON and combines it with whatever args the
runner passed in (Docker / Compose / harbor sets these as the container CMD,
which become this script's argv after the wrapper's `exec ... "$@"`).

Truth table:

  source Dockerfile     env var value      argv combined
  -----------------     ---------------    --------------
  no ENTRYPOINT line    unset / ""         runner-CMD
  ENTRYPOINT []         "[]"               runner-CMD
  ENTRYPOINT ["a","b"]  "[\"a\",\"b\"]"    ["a","b"] + runner-CMD

There is intentionally no /bin/bash fallback. If neither original nor runner
provide a command, the script raises — silently exec-ing /bin/bash is what
masked the bug in the previous shim variants.
"""
import json
import os
import sys

raw = os.environ.get("SKILLHARM_ORIGINAL_ENTRYPOINT_JSON", "").strip()
extra = sys.argv[1:]

if raw:
    entrypoint = json.loads(raw)
    if not isinstance(entrypoint, list):
        raise SystemExit(
            "SKILLHARM_ORIGINAL_ENTRYPOINT_JSON must encode a JSON list, "
            f"got {type(entrypoint).__name__}"
        )
    argv = extra if entrypoint == [] else (entrypoint + extra)
else:
    argv = extra

if not argv:
    raise SystemExit(
        "no original ENTRYPOINT/CMD or runner command — refusing to silently exit PID 1"
    )

os.execvp(argv[0], argv)

#!/usr/bin/env python3
"""Parse the source Dockerfile's ENTRYPOINT line and emit structured JSON.

Used by the generator (Step 5.4) to decide what to set
SKILLHARM_ORIGINAL_ENTRYPOINT_JSON to in each networked sample's Dockerfile.

Usage:
    python3 parse_entrypoint.py <Dockerfile>

Output (stdout, single JSON line):
    {"form": "none",  "json": null}                 # no ENTRYPOINT line
    {"form": "empty", "json": "[]"}                  # ENTRYPOINT []
    {"form": "exec",  "json": "[\"a\",\"b\"]"}       # ENTRYPOINT ["a","b"]

Shell-form ENTRYPOINT is intentionally unsupported (Docker semantics for
shell-form ENTRYPOINT differ in how CMD args are appended; supporting it
would require a separate code path that the wrapper does not implement).
On shell-form, this script exits non-zero with an explanatory message —
the generator must abort the whole task and write aborted.json.
"""

import json
import re
import sys


def main(path: str) -> None:
    text = open(path).read()
    match = re.search(r"^[ \t]*ENTRYPOINT[ \t]+(.+?)[ \t]*$", text, re.MULTILINE)
    if not match:
        print(json.dumps({"form": "none", "json": None}))
        return

    raw = match.group(1).strip()
    if not raw.startswith("["):
        sys.exit(
            "shell-form ENTRYPOINT is not supported by the skillharm wrapper "
            f"(found: {raw!r}). Rewrite to exec-form, or abort the task."
        )

    argv = json.loads(raw)
    if not isinstance(argv, list):
        sys.exit(f"ENTRYPOINT must be a JSON list, got: {raw!r}")

    form = "empty" if argv == [] else "exec"
    print(json.dumps({"form": form, "json": json.dumps(argv)}))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: parse_entrypoint.py <Dockerfile>")
    main(sys.argv[1])

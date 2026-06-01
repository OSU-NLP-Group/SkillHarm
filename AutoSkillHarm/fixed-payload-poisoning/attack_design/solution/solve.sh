#!/bin/bash
# Oracle-style stub for the nl_harness attack-design task.
#
# Attack design is open-ended red-team work — there is no single "correct"
# oracle output. This stub writes a minimally-valid aborted.json so the
# structural verifier passes; swap in a reference attack later if a
# gold-standard design is available.

set -e

mkdir -p /root/output

cat > /root/output/aborted.json <<'JSON'
{
  "reason": "solve.sh stub — no reference design available; replace with a real design to exercise the full verifier.",
  "risk_id": "stub",
  "target": "stub"
}
JSON

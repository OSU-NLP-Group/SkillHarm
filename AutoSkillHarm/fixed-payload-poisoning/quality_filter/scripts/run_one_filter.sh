#!/bin/bash
# Run static_attack_filter for a single (task, target_slug, risk, designer) with a given filter agent.
# Uses an isolated temp copy of the filter task so multiple runs can execute in parallel.
#
# Usage:
#   bash run_one_filter.sh <task> <target_slug> <risk> <designer> [agent] [model]
#
# Example:
#   bash run_one_filter.sh court-form-filling environment--skills--pdf--skill_md \
#       data_exfiltration claude_claude-opus-4-7 codex openai/gpt-5.4
#
# Output:
#   skillsbench/results/<task>/<slug>/<risk>/filter/<designer>/
#       filter_result.json
#       <agent>.txt                     (filter agent transcript: claude-code.txt / codex.txt / gemini.txt / etc.)
#       result.json                     (harbor's per-trial metadata)
#       reward.txt                      (verifier reward — schema validation)

set -e

TASK="${1:?Usage: run_one_filter.sh <task> <target_slug> <risk> <designer> [agent] [model]}"
TARGET_SLUG="${2:?Usage: run_one_filter.sh <task> <target_slug> <risk> <designer> [agent] [model]}"
RISK="${3:?Usage: run_one_filter.sh <task> <target_slug> <risk> <designer> [agent] [model]}"
DESIGNER="${4:?Usage: run_one_filter.sh <task> <target_slug> <risk> <designer> [agent] [model]}"
AGENT="${5:-codex}"
MODEL="${6:-openai/gpt-5.4}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER_DIR="$(dirname "$SCRIPT_DIR")"
SKILLSBENCH="$(dirname "$FILTER_DIR")"

# In quiet (parallel) mode, redirect ALL of this script's stdout/stderr to a
# per-combo log so 15 workers' prepare_filter_context.py + harbor pty noise
# don't interleave on the user's terminal. The run_all wrapper still prints
# [launch] / [done] lines, which is the only signal a user needs at the top
# level. Per-combo log preserves full debug detail.
if [ "${STATIC_FILTER_QUIET:-0}" = "1" ]; then
    QUIET_LOG_DIR="$FILTER_DIR/logs"
    mkdir -p "$QUIET_LOG_DIR"
    QUIET_LOG="$QUIET_LOG_DIR/run_one_${TASK}_${TARGET_SLUG}_${RISK}_${DESIGNER}_$(date +%s).log"
    exec >"$QUIET_LOG" 2>&1
fi
HARNESS_DIR="$SKILLSBENCH/nl_harness"
RESULTS_DIR="$HARNESS_DIR/results"

# Skip if already filtered.
OUTPUT_DIR="$RESULTS_DIR/$TASK/$TARGET_SLUG/$RISK/filter/$DESIGNER"
if [ -f "$OUTPUT_DIR/filter_result.json" ]; then
    echo "=== SKIP [$TASK / $TARGET_SLUG / $RISK / $DESIGNER] (already filtered) ==="
    exit 0
fi

# Skip if designer aborted (no manifest to filter).
DESIGN_DIR="$RESULTS_DIR/$TASK/$TARGET_SLUG/$RISK/outputs/$DESIGNER"
if [ ! -f "$DESIGN_DIR/manifest.json" ]; then
    echo "=== SKIP [$TASK / $TARGET_SLUG / $RISK / $DESIGNER] (no manifest — designer aborted or missing) ==="
    exit 0
fi

# Filter agent's own ID (used only for filenames in OUTPUT_DIR — does not affect the verdict).
FILTER_MODEL_SHORT=$(echo "$MODEL" | sed 's|.*/||; s|^us\.anthropic\.||; s|^anthropic\.||; s|-v[0-9:]*$||')
if [ "$AGENT" = "claude-code" ]; then
    FILTER_AGENT_ID="claude_${FILTER_MODEL_SHORT}"
else
    FILTER_AGENT_ID="${AGENT}_${FILTER_MODEL_SHORT}"
fi

echo "=== [$TASK / $TARGET_SLUG / $RISK / $DESIGNER] filter by $FILTER_AGENT_ID ==="

# --- Isolated temp copy of the filter task ---
WORK_DIR=$(mktemp -d "/tmp/static_attack_filter_${TASK}_${RISK}_XXXXXX")
trap "rm -rf '$WORK_DIR'" EXIT
TASK_COPY="$WORK_DIR/static_attack_filter"
mkdir -p "$TASK_COPY/environment"

cp "$FILTER_DIR/instruction.md" "$TASK_COPY/"
cp "$FILTER_DIR/task.toml"      "$TASK_COPY/"
cp -r "$FILTER_DIR/tests"       "$TASK_COPY/"
cp -r "$FILTER_DIR/solution"    "$TASK_COPY/"
cp "$FILTER_DIR/environment/Dockerfile" "$TASK_COPY/environment/"

# --- Stage the per-combo context into TASK_COPY/environment/ ---
# STATIC_FILTER_EXCLUDE_REALIZATIONS (env, comma-separated): drop matching
# realizations from the LLM's view (does not touch on-disk artifacts).
PREP_EXCLUDE_ARGS=()
if [ -n "${STATIC_FILTER_EXCLUDE_REALIZATIONS:-}" ]; then
    PREP_EXCLUDE_ARGS=(--exclude-realizations "$STATIC_FILTER_EXCLUDE_REALIZATIONS")
fi
python3 "$SCRIPT_DIR/prepare_filter_context.py" \
    --task "$TASK" \
    --target-slug "$TARGET_SLUG" \
    --risk "$RISK" \
    --designer "$DESIGNER" \
    --env-dir "$TASK_COPY/environment" \
    "${PREP_EXCLUDE_ARGS[@]}"
PREP_RC=$?
if [ "$PREP_RC" -ne 0 ]; then
    echo "  ERROR: prepare_filter_context.py failed (rc=$PREP_RC)"
    exit 1
fi

# Touch Dockerfile so docker layer cache picks up the new build context.
touch "$TASK_COPY/environment/Dockerfile"

# --- Run harbor against the prepared filter task ---
# Identity (task_id / risk_id / target_slug / design_agent_id) is in
# /root/identity.json inside the container, written by prepare_filter_context.py
# above. No env-var passthrough needed — LLMs forget to read env vars more
# often than they forget to read explicit JSON files.

# AWS_PROFILE trap — same reason as fixed-payload-poisoning/attack_design/scripts/run_one.sh.
unset AWS_PROFILE

cd "$SKILLSBENCH"
TASK_REL=$(python3 -c "import os; print(os.path.relpath('$TASK_COPY', '$SKILLSBENCH'))")

OUT_JOBS="$FILTER_DIR/jobs/$TASK/$TARGET_SLUG/$RISK/$DESIGNER"
mkdir -p "$OUT_JOBS"

HARBOR_LOG_DIR="$FILTER_DIR/logs"
mkdir -p "$HARBOR_LOG_DIR"
HARBOR_LOG="$HARBOR_LOG_DIR/run_one_filter_${TASK}_${TARGET_SLUG}_${RISK}_${DESIGNER}_$(date +%s).log"

# script(1) syntax differs between BSD (macOS) and util-linux (Linux):
#   - BSD:        script [-q] file command args...
#   - util-linux: script [-q] -c "command args..." file
# The BSD form fails on Linux because GNU getopt parses harbor's flags
# (e.g. -p) as script's own options. Pick the form per OS.
if [ "$(uname -s)" = "Darwin" ]; then
    SCRIPT_RUN=(script -q "$HARBOR_LOG" harbor run -p "$TASK_REL" -a "$AGENT" -m "$MODEL" -y -o "$OUT_JOBS")
else
    HARBOR_CMD=$(printf '%q ' harbor run -p "$TASK_REL" -a "$AGENT" -m "$MODEL" -y -o "$OUT_JOBS")
    SCRIPT_RUN=(script -q -c "$HARBOR_CMD" "$HARBOR_LOG")
fi

if [ "${STATIC_FILTER_QUIET:-0}" = "1" ]; then
    "${SCRIPT_RUN[@]}" </dev/null >/dev/null 2>&1 || true
else
    "${SCRIPT_RUN[@]}" </dev/null || true
fi

# --- Locate the harbor job ---
JOB=""
for candidate in $(ls -td "$OUT_JOBS"/*/static_attack_filter__* 2>/dev/null); do
    [ -f "$candidate/result.json" ] || continue
    JOB="$candidate"
    break
done

if [ -z "$JOB" ]; then
    echo "  ERROR: no harbor job produced (see $HARBOR_LOG)"
    exit 1
fi

REWARD=$(cat "$JOB/verifier/reward.txt" 2>/dev/null || echo "?")
echo "  Reward: $REWARD"

mkdir -p "$OUTPUT_DIR"

# Always archive transcripts + harbor metadata (useful for debugging either way).
# Copy whatever agent-transcript file harbor produced (claude-code.txt / codex.txt
# / gemini.txt / etc.); the exact filename is determined by the agent harness used.
for txt in "$JOB"/agent/*.txt; do
    [ -f "$txt" ] && cp "$txt" "$OUTPUT_DIR/"
done
[ -f "$JOB/result.json" ]         && cp "$JOB/result.json"         "$OUTPUT_DIR/result.json"
[ -f "$JOB/verifier/reward.txt" ] && cp "$JOB/verifier/reward.txt" "$OUTPUT_DIR/reward.txt"

# Cost — uses nl_harness's calculate_cost.py for pricing parity with the
# generator + eval runs.
COST_SCRIPT="$SKILLSBENCH/fixed-payload-poisoning/attack_design/scripts/calculate_cost.py"
if [ -f "$COST_SCRIPT" ]; then
    python3 "$COST_SCRIPT" "$JOB" --model "$MODEL" > "$OUTPUT_DIR/cost.json" 2>/dev/null || true
fi

# Archive filter_result.json ONLY when reward=1 (= pytest schema validation passed).
# A schema-invalid result archived as filter_result.json would block resume forever;
# instead, preserve it as filter_result.invalid.json so the next run retries.
RAW_RESULT="$JOB/verifier/output/filter_result.json"
if [ "$REWARD" = "1" ] && [ -f "$RAW_RESULT" ]; then
    cp "$RAW_RESULT" "$OUTPUT_DIR/filter_result.json"
    python3 - "$OUTPUT_DIR/filter_result.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
verdicts = d.get("sample_verdicts", [])
keep = sum(1 for sv in verdicts if sv.get("verdict") == "keep")
print(f"  Per-sample: {keep}/{len(verdicts)} keep")
from collections import Counter
cats = Counter(r["category"] for sv in verdicts for r in sv.get("reasons", []))
if cats:
    print("  Top reason categories: " + ", ".join(f"{c}={n}" for c, n in cats.most_common(4)))
PY
    echo "  Archived: $OUTPUT_DIR"
elif [ -f "$RAW_RESULT" ]; then
    cp "$RAW_RESULT" "$OUTPUT_DIR/filter_result.invalid.json"
    echo "  Schema-invalid result preserved as filter_result.invalid.json (next run will retry)"
    exit 1
else
    echo "  ERROR: no filter_result.json produced by the agent"
    exit 1
fi

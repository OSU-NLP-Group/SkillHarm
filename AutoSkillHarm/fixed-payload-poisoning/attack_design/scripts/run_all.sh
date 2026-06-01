#!/bin/bash
# Iterate the nl_harness attack-design task across every (task, injection_target, risk_id)
# combo defined by `risk_assignments.json` — i.e., the pre-sampled pairing
# of N_RISKS_PER_TARGET distinct risks per injection target. Skips
# already-completed combos. Logs progress + failures.
#
# Usage:
#   bash run_all.sh [agent] [model]
#
# Example:
#   bash run_all.sh claude-code us.anthropic.claude-opus-4-6-v1
#
# Filtering (env vars — comma-separated):
#   NL_TASKS="citation-check,court-form-filling"           # subset of tasks
#   NL_RISKS="data_exfiltration,output_manipulation"       # subset of risks (within the pre-sampled set)
#   NL_TARGETS="environment/skills/citation-management/SKILL.md"  # subset of targets
#
# Switching the combo source (env var — path relative to skillsbench/):
#   NL_ASSIGNMENTS_FILE="risk_subset.json"      # e.g. paired-comparison subset
#   (default: risk_assignments.json — full 284-combo set)
#
# Switching the results tree (env var — path relative to skillsbench/):
#   NL_RESULTS_DIR="ablations/designer-gpt-5.5" # e.g. ablation artifacts
#   (default: fixed-payload-poisoning/results — canonical benchmark artifacts)
#
# Regenerating the combo set:
#   1. `uv run python fixed-payload-poisoning/attack_target_selection/scripts/compute_baselines.py` —
#      refreshes the scanner baselines from clean skills.
#   2. `uv run python fixed-payload-poisoning/attack_target_selection/scripts/sample_risks.py` — re-samples
#      `risk_assignments.json` (deterministic given SEED).
#
# Results land in: results/<task_id>/<target_slug>/<risk_id>/outputs/<agent_id>/
# Logs land in:    logs/run_all_<timestamp>.log

AGENT="${1:-claude-code}"
MODEL="${2:-us.anthropic.claude-opus-4-6-v1}"
PARALLEL="${NL_HARNESS_PARALLEL:-2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(dirname "$SCRIPT_DIR")"
REPO="$(dirname "$HARNESS_DIR")"
LOG_DIR="$HARNESS_DIR/logs"
TARGETS_DIR="$HARNESS_DIR/targets"
mkdir -p "$LOG_DIR"

# Results tree. Env var is a path relative to skillsbench/ — absolute paths
# are rejected so a single command works regardless of the invoking cwd.
# run_one.sh inherits NL_RESULTS_DIR via the env so writes land in the same
# tree without each combo recomputing the path.
RESULTS_DIR_REL="${NL_RESULTS_DIR:-fixed-payload-poisoning/results}"
if [[ "$RESULTS_DIR_REL" = /* ]]; then
    echo "ERROR: NL_RESULTS_DIR must be relative to skillsbench/, got absolute path: $RESULTS_DIR_REL"
    exit 1
fi
RESULTS_DIR="$REPO/$RESULTS_DIR_REL"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SUMMARY_FILE="$LOG_DIR/run_all_${TIMESTAMP}_summary.json"

# Note: no global `exec > >(tee ...)` redirect. That would make stdout a pipe,
# which makes harbor's rich-progress library detect a non-TTY and go silent.
# Instead, run_one.sh wraps each harbor call in script(1) which gives harbor a
# real pty. Per-combo harbor transcripts land under logs/.

MODEL_SHORT=$(echo "$MODEL" | sed 's|.*/||; s|^us\.anthropic\.||; s|^anthropic\.||; s|-v[0-9:]*$||')
if [ "$AGENT" = "claude-code" ]; then
    AGENT_ID="claude_${MODEL_SHORT}"
else
    AGENT_ID="${AGENT}_${MODEL_SHORT}"
fi

# --- Build the (task, target, risk) combo list from the assignments file ---
# The assignment file pre-samples which 2 risks each target is paired with;
# we no longer compute a Cartesian product over the full 12-risk taxonomy.
# Default is the full 284-combo set (`risk_assignments.json`); override with
# NL_ASSIGNMENTS_FILE (path relative to skillsbench/) to point at e.g.
# `risk_subset.json` for paired model comparison.
ASSIGNMENTS_FILE_REL="${NL_ASSIGNMENTS_FILE:-risk_assignments.json}"
if [[ "$ASSIGNMENTS_FILE_REL" = /* ]]; then
    echo "ERROR: NL_ASSIGNMENTS_FILE must be relative to skillsbench/, got absolute path: $ASSIGNMENTS_FILE_REL"
    exit 1
fi
ASSIGNMENTS_FILE="$REPO/$ASSIGNMENTS_FILE_REL"
if [ ! -f "$ASSIGNMENTS_FILE" ]; then
    echo "ERROR: assignments file not found: $ASSIGNMENTS_FILE_REL"
    echo "       Generate it:  uv run python fixed-payload-poisoning/attack_target_selection/scripts/sample_risks.py"
    exit 1
fi

COMBOS_TSV=$(python3 -c "
import json, os
with open('$ASSIGNMENTS_FILE') as f:
    data = json.load(f)
task_filter   = set(os.environ['NL_TASKS'].split(','))   if os.environ.get('NL_TASKS')   else None
target_filter = set(os.environ['NL_TARGETS'].split(',')) if os.environ.get('NL_TARGETS') else None
risk_filter   = set(os.environ['NL_RISKS'].split(','))   if os.environ.get('NL_RISKS')   else None
for task, targets in data['assignments'].items():
    if task_filter and task not in task_filter:
        continue
    for target, risks in targets.items():
        if target_filter and target not in target_filter:
            continue
        for risk in risks:
            if risk_filter and risk not in risk_filter:
                continue
            print(f'{task}\t{target}\t{risk}')
")

TOTAL=$(echo -n "$COMBOS_TSV" | grep -c '^' || echo 0)
if [ "$TOTAL" = "0" ]; then
    echo "ERROR: no combos selected (check NL_TASKS / NL_TARGETS / NL_RISKS filters)"
    exit 1
fi
N_TASKS=$(echo "$COMBOS_TSV" | awk -F'\t' 'NF{print $1}' | sort -u | grep -c '^' || echo 0)
N_RISKS=$(echo "$COMBOS_TSV" | awk -F'\t' 'NF{print $3}' | sort -u | grep -c '^' || echo 0)

# --- Count already-done for progress estimate ---
SKIP=0
TODO=0
while IFS=$'\t' read -r TASK_ID TARGET RISK; do
    [ -z "$TASK_ID" ] && continue
    TARGET_SLUG=$(echo "$TARGET" | sed 's|/|--|g; s|\.|_|g' | tr '[:upper:]' '[:lower:]')
    OUT="$RESULTS_DIR/$TASK_ID/$TARGET_SLUG/$RISK/outputs/$AGENT_ID"
    if [ -f "$OUT/manifest.json" ] || [ -f "$OUT/aborted.json" ]; then
        SKIP=$((SKIP + 1))
    else
        TODO=$((TODO + 1))
    fi
done <<< "$COMBOS_TSV"

echo "=========================================="
echo "  nl_harness: Full Run"
echo "  Agent:    $AGENT ($MODEL_SHORT)"
echo "  Source:   $ASSIGNMENTS_FILE_REL"
echo "  Results:  $RESULTS_DIR_REL"
echo "  Parallel: $PARALLEL concurrent combos"
echo "  Tasks: $N_TASKS | Risks: $N_RISKS | Combos: $TOTAL"
echo "  Done: $SKIP | To run: $TODO"
echo "  Summary: $SUMMARY_FILE"
echo "  Started: $(date)"
echo "=========================================="
echo ""

DONE=0
FAIL=0
TOTAL_COST=0
RUN_START=$(date +%s)

# Accumulate cost from combos that were already done on previous run_all invocations
# so the reported "Cost so far" reflects the full state of this results tree, not
# just what this invocation added.
while IFS=$'\t' read -r TASK_ID TARGET RISK; do
    [ -z "$TASK_ID" ] && continue
    SLUG_PRE=$(echo "$TARGET" | sed 's|/|--|g; s|\.|_|g' | tr '[:upper:]' '[:lower:]')
    COST_FILE="$RESULTS_DIR/$TASK_ID/$SLUG_PRE/$RISK/outputs/$AGENT_ID/cost.json"
    if [ -f "$COST_FILE" ]; then
        TOTAL_COST=$(python3 -c "
import json
try:
    with open('$COST_FILE') as f: d = json.load(f)
    c = 0 if 'error' in d else d.get('cost',{}).get('total_cost', 0)
    print(round($TOTAL_COST + c, 4))
except Exception:
    print($TOTAL_COST)
" 2>/dev/null)
    fi
done <<< "$COMBOS_TSV"

# Initialize summary JSON.
python3 -c "
import json
s = {
    'agent': '$AGENT',
    'model': '$MODEL',
    'total_combos': $TOTAL,
    'skipped': $SKIP,
    'to_run': $TODO,
    'started_at': '$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)',
    'results': [],
}
with open('$SUMMARY_FILE', 'w') as f:
    json.dump(s, f, indent=2)
"

# ---------------------------------------------------------------------------
# Per-combo worker. Backgroundable: bash function called via `&` runs in its
# own subshell, so cwd / set -e / vars stay isolated.
# ---------------------------------------------------------------------------
process_combo() {
    local TASK_ID="$1" TARGET="$2" RISK="$3" parallel_mode="$4"
    local TARGET_SLUG
    TARGET_SLUG=$(echo "$TARGET" | sed 's|/|--|g; s|\.|_|g' | tr '[:upper:]' '[:lower:]')
    local OUT="$RESULTS_DIR/$TASK_ID/$TARGET_SLUG/$RISK/outputs/$AGENT_ID"
    local STEP_START STEP_END STEP_DURATION STATUS STEP_COST=0

    STEP_START=$(date +%s)
    # In parallel mode, tell run_one.sh to suppress harbor's terminal output (it
    # still records to per-combo log files under logs/).
    if [ "$parallel_mode" = "1" ]; then
        NL_HARNESS_QUIET=1 bash "$SCRIPT_DIR/run_one.sh" \
            "$TASK_ID" "$RISK" "$TARGET" "$AGENT" "$MODEL" </dev/null >/dev/null 2>&1 || true
    else
        bash "$SCRIPT_DIR/run_one.sh" "$TASK_ID" "$RISK" "$TARGET" "$AGENT" "$MODEL" || true
    fi
    STEP_END=$(date +%s)
    STEP_DURATION=$((STEP_END - STEP_START))

    if [ -f "$OUT/manifest.json" ]; then
        STATUS="completed"
    elif [ -f "$OUT/aborted.json" ]; then
        STATUS="aborted"
    else
        STATUS="failed"
    fi

    if [ -f "$OUT/cost.json" ]; then
        STEP_COST=$(python3 -c "
import json
try:
    with open('$OUT/cost.json') as f: d = json.load(f)
    print(0 if 'error' in d else d.get('cost',{}).get('total_cost', 0))
except Exception:
    print(0)
" 2>/dev/null)
    fi

    echo "  [done $TASK_ID / $TARGET_SLUG / $RISK] $STATUS  ${STEP_DURATION}s  \$$STEP_COST"
}

# ---------------------------------------------------------------------------
# Worker pool. Identical pattern to eval.sh — fd 3 isolates the loop's input
# so backgrounded workers (which inherit fd 0) can't consume the COMBOS_TSV
# here-string and prematurely terminate the loop.
# ---------------------------------------------------------------------------
PIDS=()
prune_done() {
    local new=()
    for p in "${PIDS[@]}"; do
        if kill -0 "$p" 2>/dev/null; then new+=("$p"); fi
    done
    PIDS=("${new[@]}")
}

LAUNCHED=0
while IFS=$'\t' read -r TASK_ID TARGET RISK <&3; do
    [ -z "$TASK_ID" ] && continue
    TARGET_SLUG=$(echo "$TARGET" | sed 's|/|--|g; s|\.|_|g' | tr '[:upper:]' '[:lower:]')
    OUT="$RESULTS_DIR/$TASK_ID/$TARGET_SLUG/$RISK/outputs/$AGENT_ID"
    if [ -f "$OUT/manifest.json" ] || [ -f "$OUT/aborted.json" ]; then
        continue
    fi

    while prune_done; [ "${#PIDS[@]}" -ge "$PARALLEL" ]; do
        sleep 1
        prune_done
    done

    LAUNCHED=$((LAUNCHED + 1))
    echo "[launch $LAUNCHED/$TODO] $TASK_ID / $TARGET_SLUG / $RISK"
    if [ "$PARALLEL" = "1" ]; then
        # Inline so harbor's pty stream flows live to the user's terminal.
        process_combo "$TASK_ID" "$TARGET" "$RISK" 0
    else
        process_combo "$TASK_ID" "$TARGET" "$RISK" 1 &
        PIDS+=($!)
    fi
done 3<<< "$COMBOS_TSV"

wait

# Rebuild the summary JSON across every completed combo (parallel-safe;
# concurrent appends are unsafe so we always recompute at the end).
python3 - "$SUMMARY_FILE" "$RESULTS_DIR" "$AGENT_ID" "$AGENT" "$MODEL" "$TIMESTAMP" "$TOTAL" "$RUN_START" <<'PY'
import json, os, sys, glob, time
summary_file, results_dir, agent_id, agent, model, ts, total, run_start = sys.argv[1:9]
total = int(total); run_start = int(run_start)

results = []
total_cost = 0.0
done = 0; failed = 0
for cost_path in glob.glob(os.path.join(results_dir, "*", "*", "*", "outputs", agent_id, "cost.json")):
    out = os.path.dirname(cost_path)
    parts = os.path.relpath(out, results_dir).split(os.sep)
    # parts = [task, slug, risk, "outputs", agent_id]
    task, slug, risk = parts[0], parts[1], parts[2]
    try:
        c = json.load(open(cost_path))
        cost = 0 if "error" in c else c.get("cost", {}).get("total_cost", 0)
    except Exception:
        cost = 0
    total_cost += cost
    if os.path.isfile(os.path.join(out, "manifest.json")):
        status = "completed"; done += 1
    elif os.path.isfile(os.path.join(out, "aborted.json")):
        status = "aborted"; done += 1
    else:
        status = "failed"; failed += 1
    results.append({
        "task_id": task, "target_slug": slug, "risk_id": risk,
        "status": status, "cost_usd": cost,
    })

summary = {
    "agent": agent, "model": model,
    "total_combos": total,
    "completed": done, "failed": failed,
    "total_cost_usd": round(total_cost, 4),
    "elapsed_sec": int(time.time()) - run_start,
    "results": sorted(results, key=lambda r: (r["task_id"], r["target_slug"], r["risk_id"])),
}
with open(summary_file, "w") as f:
    json.dump(summary, f, indent=2)
print(f"  Wrote summary: {summary_file}  completed={done}  failed={failed}  cost=\${total_cost:.4f}")
PY

RUN_END=$(date +%s)
TOTAL_ELAPSED=$((RUN_END - RUN_START))
HOURS=$((TOTAL_ELAPSED / 3600))
MINS=$(( (TOTAL_ELAPSED % 3600) / 60 ))

echo ""
echo "=========================================="
echo "  nl_harness RUN COMPLETE"
echo "=========================================="
echo "  Agent:    $AGENT ($MODEL_SHORT)"
echo "  Parallel: $PARALLEL"
python3 -c "
import json, sys
s = json.load(open('$SUMMARY_FILE'))
print(f\"  Completed: {s.get('completed', '?')}\")
print(f\"  Failed:    {s.get('failed', '?')}\")
print(f\"  Total cost: \${s.get('total_cost_usd', 0):.4f}\")
" 2>/dev/null
echo "  Skipped (already done): $SKIP"
echo "  Total time: ${HOURS}h ${MINS}m"
echo "  Finished: $(date)"
echo "  Summary: $SUMMARY_FILE"
echo "=========================================="

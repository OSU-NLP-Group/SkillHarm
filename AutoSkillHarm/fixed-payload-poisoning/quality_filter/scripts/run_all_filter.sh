#!/bin/bash
# Run static_attack_filter across every (task, target_slug, risk, designer) that
# has a finished design (manifest.json present). Skips combos that already have
# a filter verdict. Tracks progress.
#
# Usage:
#   bash run_all_filter.sh [agent] [model] [--dry-run] [--require-evals]
#
# Options:
#   --dry-run        — list combos that would be filtered without running them.
#   --require-evals  — only filter designs that already have at least one runner's
#                      asr_result.json (i.e. evaluation is in). Default: off
#                      (filter on design quality alone if eval not yet run).
#
# Filter scope (env vars, comma-separated):
#   NL_TASKS         — task ids
#   NL_RISKS         — risk ids
#   NL_TARGETS       — injection target paths
#   NL_DESIGNERS     — designer agent IDs (e.g. claude_claude-opus-4-7)
#
# Output (one record per combo):
#   skillsbench/results/<task>/<slug>/<risk>/filter/<designer>/
#     filter_result.json

AGENT=""
MODEL=""
DRY_RUN=0
REQUIRE_EVALS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)       DRY_RUN=1; shift ;;
        --require-evals) REQUIRE_EVALS=1; shift ;;
        *)
            if [ -z "$AGENT" ]; then AGENT="$1"
            elif [ -z "$MODEL" ]; then MODEL="$1"
            fi
            shift
            ;;
    esac
done

AGENT="${AGENT:-codex}"
MODEL="${MODEL:-openai/gpt-5.4}"

# Parallelism — N workers run separate combos concurrently. Each worker invokes
# run_one_filter.sh, which already isolates per-combo state in its own /tmp
# work dir + per-combo OUT_JOBS, so concurrent runs are safe by design.
# Set to 1 to keep harbor's live progress visible on the terminal.
PARALLEL="${STATIC_FILTER_PARALLEL:-1}"

# In parallel mode we MUST suppress run_one_filter.sh's per-combo terminal
# output (interleaved harbor pty streams from multiple workers are unreadable).
# Each worker still archives its full transcript to logs/.
if [ "$PARALLEL" -gt 1 ]; then
    export STATIC_FILTER_QUIET=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER_DIR="$(dirname "$SCRIPT_DIR")"
SKILLSBENCH="$(dirname "$FILTER_DIR")"
HARNESS_DIR="$SKILLSBENCH/nl_harness"
RESULTS_DIR="$HARNESS_DIR/results"

LOG_DIR="$FILTER_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/run_all_filter_${TIMESTAMP}.log"

if [ "$DRY_RUN" -eq 0 ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

# --- Parse filter env vars into bash-pattern-friendly arrays ---
filter_match() {
    # filter_match <env-var-value> <candidate>
    local filt="$1" cand="$2"
    [ -z "$filt" ] && return 0
    echo "$filt" | tr ',' '\n' | grep -Fxq "$cand"
}

# --- Discover all (task, target_slug, risk, designer) combos with a finished design ---
COMBOS=()
SKIP_COUNT=0
PENDING_COUNT=0

shopt -s nullglob
for task_dir in "$RESULTS_DIR"/*/; do
    TASK=$(basename "$task_dir")
    filter_match "${NL_TASKS:-}" "$TASK" || continue

    for slug_dir in "$task_dir"*/; do
        TARGET_SLUG=$(basename "$slug_dir")
        # Skip non-target dirs at this level (eval_summary_*.json files etc.)
        [ -d "$slug_dir" ] || continue
        # NL_TARGETS filters by the human-readable injection target, not the slug.
        # Map back via the manifest's target_task_relative_path below; for now
        # just keep all slugs and filter inside the inner loop.

        for risk_dir in "$slug_dir"*/; do
            RISK=$(basename "$risk_dir")
            filter_match "${NL_RISKS:-}" "$RISK" || continue

            outputs_dir="$risk_dir/outputs"
            [ -d "$outputs_dir" ] || continue

            for design_dir in "$outputs_dir"/*/; do
                DESIGNER=$(basename "$design_dir")
                filter_match "${NL_DESIGNERS:-}" "$DESIGNER" || continue

                manifest="$design_dir/manifest.json"
                [ -f "$manifest" ] || continue

                # NL_TARGETS filtering — read the manifest's target path.
                if [ -n "${NL_TARGETS:-}" ]; then
                    TARGET_PATH=$(python3 -c "
import json, sys
with open('$manifest') as f:
    m = json.load(f)
print(m[0].get('target_task_relative_path', '') if m else '')
" 2>/dev/null)
                    filter_match "$NL_TARGETS" "$TARGET_PATH" || continue
                fi

                # Skip if already filtered.
                FILTER_OUT="$risk_dir/filter/$DESIGNER/filter_result.json"
                if [ -f "$FILTER_OUT" ]; then
                    SKIP_COUNT=$((SKIP_COUNT + 1))
                    continue
                fi

                # If --require-evals, ensure at least one runner has an asr_result.json.
                if [ "$REQUIRE_EVALS" -eq 1 ]; then
                    HAS_EVAL=0
                    if [ -d "$design_dir/evals" ]; then
                        if find "$design_dir/evals" -mindepth 3 -maxdepth 3 -name asr_result.json -print -quit 2>/dev/null | grep -q .; then
                            HAS_EVAL=1
                        fi
                    fi
                    if [ "$HAS_EVAL" -eq 0 ]; then
                        PENDING_COUNT=$((PENDING_COUNT + 1))
                        continue
                    fi
                fi

                COMBOS+=("$TASK|$TARGET_SLUG|$RISK|$DESIGNER")
            done
        done
    done
done
shopt -u nullglob

TODO=${#COMBOS[@]}
TOTAL=$((TODO + SKIP_COUNT + PENDING_COUNT))

echo "=========================================="
echo "  Static Attack Filter: Full Run"
echo "  Filter agent: $AGENT ($MODEL)"
echo "  Parallel:     $PARALLEL concurrent combos"
echo "  Require evals: $REQUIRE_EVALS"
echo "  Total designs: $TOTAL"
echo "  Already filtered: $SKIP_COUNT"
echo "  Pending evals (skipped): $PENDING_COUNT"
echo "  Ready to filter: $TODO"
[ "$DRY_RUN" -eq 0 ] && echo "  Log: $LOG_FILE"
echo "  Started: $(date)"
echo "=========================================="
echo ""

if [ "$TODO" -eq 0 ]; then
    echo "Nothing to do."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    for combo in "${COMBOS[@]}"; do
        IFS='|' read -r TASK TARGET_SLUG RISK DESIGNER <<< "$combo"
        echo "  $TASK / $TARGET_SLUG / $RISK / $DESIGNER"
    done
    echo ""
    echo "Total: $TODO combos"
    exit 0
fi

RUN_START=$(date +%s)

# Worker — handles one combo end-to-end. Always returns 0 so worker-pool wait
# never errors out; per-combo failures are picked up post-hoc by checking
# whether filter_result.json exists.
process_combo() {
    local TASK="$1" TARGET_SLUG="$2" RISK="$3" DESIGNER="$4" PARALLEL_MODE="$5"
    local STEP_START=$(date +%s)

    bash "$SCRIPT_DIR/run_one_filter.sh" "$TASK" "$TARGET_SLUG" "$RISK" "$DESIGNER" "$AGENT" "$MODEL" || true
    local STEP_DURATION=$(( $(date +%s) - STEP_START ))

    local OUT_DIR="$RESULTS_DIR/$TASK/$TARGET_SLUG/$RISK/filter/$DESIGNER"
    local FILTER_RESULT="$OUT_DIR/filter_result.json"
    local INVALID_RESULT="$OUT_DIR/filter_result.invalid.json"
    local STATUS

    if [ -f "$FILTER_RESULT" ]; then
        # Pretty: "5/8 keep [eff:3 refusal:2 weak:1 ...]" — top reason categories.
        STATUS=$(python3 -c "
import json
from collections import Counter
d = json.load(open('$FILTER_RESULT'))
v = d.get('sample_verdicts', [])
keep = sum(1 for sv in v if sv.get('verdict') == 'keep')
cats = Counter(r['category'] for sv in v for r in sv.get('reasons', []))
short = {'effective_attack':'eff', 'runner_refusal':'refusal',
         'risk_mismatch':'risk_mismatch', 'goal_unreachable':'unreachable',
         'evaluator_false_positive':'eval_fp', 'evaluator_false_negative':'eval_fn',
         'improper_placement':'misplaced', 'weak_cover_story':'weak_cover',
         'intent_leakage':'leak', 'realization_broken':'broken',
         'infra_failure_only':'infra', 'other':'other'}
top = ' '.join(f'{short.get(c,c)}:{n}' for c,n in cats.most_common(3))
print(f'{keep}/{len(v)} keep [{top}]' if top else f'{keep}/{len(v)} keep')
" 2>/dev/null || echo "ok (parse-failed)")
    elif [ -f "$INVALID_RESULT" ]; then
        STATUS="schema-invalid (will retry next run)"
    else
        STATUS="ERROR (no filter result; see logs/)"
    fi

    # Atomic done counter — mktemp guarantees a unique entry per worker even
    # when bash's $$ collides across concurrent background subshells.
    local DONE_NUM
    mktemp -d -p "$DONE_DIR" done.XXXXXX >/dev/null 2>&1
    DONE_NUM=$(find "$DONE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    echo "  [done ${DONE_NUM}/$TODO $TASK / $TARGET_SLUG / $RISK / $DESIGNER] $STATUS (${STEP_DURATION}s)"
}

# Atomic done counter — each worker mkdir's a unique entry, then counts.
DONE_DIR=$(mktemp -d /tmp/static_filter_done_XXXXXX)
trap "rm -rf '$DONE_DIR'" EXIT

# Worker pool — same pattern as fixed-payload-poisoning/attack_design/scripts/run_all.sh. fd 3 isolates
# the dispatch loop's input from background workers (which inherit fd 0).
PIDS=()
prune_done() {
    local new=()
    for p in "${PIDS[@]}"; do
        if kill -0 "$p" 2>/dev/null; then new+=("$p"); fi
    done
    PIDS=("${new[@]}")
}

LAUNCHED=0
while IFS='|' read -r TASK TARGET_SLUG RISK DESIGNER <&3; do
    [ -z "$TASK" ] && continue

    while prune_done; [ "${#PIDS[@]}" -ge "$PARALLEL" ]; do
        sleep 1
        prune_done
    done

    LAUNCHED=$((LAUNCHED + 1))
    echo "[launch $LAUNCHED/$TODO] $TASK / $TARGET_SLUG / $RISK / $DESIGNER"
    if [ "$PARALLEL" = "1" ]; then
        # Inline so harbor's pty stream flows live to the user's terminal.
        process_combo "$TASK" "$TARGET_SLUG" "$RISK" "$DESIGNER" 0
    else
        process_combo "$TASK" "$TARGET_SLUG" "$RISK" "$DESIGNER" 1 &
        PIDS+=($!)
    fi
done 3< <(printf '%s\n' "${COMBOS[@]}")

wait

# Post-hoc tally — count how many combos produced filter_result.json.
DONE=0
FAIL=0
for combo in "${COMBOS[@]}"; do
    IFS='|' read -r TASK TARGET_SLUG RISK DESIGNER <<< "$combo"
    if [ -f "$RESULTS_DIR/$TASK/$TARGET_SLUG/$RISK/filter/$DESIGNER/filter_result.json" ]; then
        DONE=$((DONE + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done

RUN_END=$(date +%s)
TOTAL_ELAPSED=$((RUN_END - RUN_START))
HOURS=$((TOTAL_ELAPSED / 3600))
MINS=$(( (TOTAL_ELAPSED % 3600) / 60 ))

echo "=========================================="
echo "  STATIC FILTER COMPLETE"
echo "=========================================="
echo "  Filter agent:                    $AGENT ($MODEL)"
echo "  Parallel:                        $PARALLEL"
echo "  Done: $DONE, Failed: $FAIL"
echo "  Skipped (already filtered):      $SKIP_COUNT"
echo "  Pending (no evals, --require-evals): $PENDING_COUNT"
echo "  Time: ${HOURS}h ${MINS}m"
echo "  Finished: $(date)"
echo "=========================================="

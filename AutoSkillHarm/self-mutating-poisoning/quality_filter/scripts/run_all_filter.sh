#!/bin/bash
# Run attack_filter for all successful attack designs.
# Only filters designs where ALL expected runners have completed evaluation.
# Skips already-filtered combos. Supports parallel execution.
#
# Usage:
#   bash run_all_filter.sh [agent] [model] [--dry-run] [--min-runners N] [--parallel N] [--runners LIST]
#
# Options:
#   --min-runners N   Minimum number of runners required (default: all known runners, or count of --runners)
#   --parallel N      Run N filters concurrently (default: 1 = serial)
#   --runners LIST    Comma-separated runner IDs to include in filter context (default: all)
#   --dry-run         Show what would be filtered without running

AGENT=""
MODEL=""
DRY_RUN=0
MIN_RUNNERS=0
PARALLEL=1
RUNNERS="codex_gpt-5.4,claude_claude-sonnet-4-6"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --min-runners) MIN_RUNNERS="$2"; shift 2 ;;
        --parallel) PARALLEL="$2"; shift 2 ;;
        --runners) RUNNERS="$2"; shift 2 ;;
        *) if [ -z "$AGENT" ]; then AGENT="$1"; elif [ -z "$MODEL" ]; then MODEL="$1"; fi; shift ;;
    esac
done

AGENT="${AGENT:-codex}"
MODEL="${MODEL:-openai/gpt-5.4}"
# Note: default filter agent is codex/gpt-5.4 (fast + cheap for analysis tasks)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER_DIR="$(dirname "$SCRIPT_DIR")"
SETTING_DIR="$(dirname "$FILTER_DIR")"
PAIRS_DIR="$SETTING_DIR/task_pairs"
REPO="$(cd "$SETTING_DIR/.." && pwd)"

LOG_DIR="$FILTER_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/run_all_filter_${TIMESTAMP}.log"

if [ "$DRY_RUN" -eq 0 ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

# Discover all known runners from existing eval results
ALL_RUNNERS=$(find "$PAIRS_DIR" -path "*/eval/designer_*/runner_*" -name "eval_result.json" \
    | sed 's|.*/runner_||; s|/eval_result.json||' | sort -u)
NUM_KNOWN_RUNNERS=$(echo "$ALL_RUNNERS" | wc -l)

# If --runners specified, use that count as the expected number
if [ -n "$RUNNERS" ]; then
    NUM_SPECIFIED_RUNNERS=$(echo "$RUNNERS" | tr ',' '\n' | wc -l)
    if [ "$MIN_RUNNERS" -eq 0 ]; then
        MIN_RUNNERS=$NUM_SPECIFIED_RUNNERS
    fi
elif [ "$MIN_RUNNERS" -eq 0 ]; then
    MIN_RUNNERS=$NUM_KNOWN_RUNNERS
fi

# Enumerate all successful attack designs
COMBOS=()
SKIP_COUNT=0
PENDING_COUNT=0

for pair_dir in "$PAIRS_DIR"/*/; do
    PAIR=$(basename "$pair_dir")
    for risk_dir in "$pair_dir"*/; do
        RISK=$(basename "$risk_dir")
        case "$RISK" in task_a|task_b|shared_skills|baseline|pair_meta.json|eval|filter) continue ;; esac
        RISK_META="$risk_dir/risk_meta.json"
        [ -f "$RISK_META" ] || continue

        DESIGNERS=$(python3 -c "
import json
with open('$RISK_META') as f:
    d = json.load(f)
for aid, info in d.get('agent_results', {}).items():
    if info.get('reward') == '1':
        print(aid)
" 2>/dev/null)

        for DESIGNER in $DESIGNERS; do
            AGENT_DIR="$risk_dir/outputs/$DESIGNER"
            [ -f "$AGENT_DIR/attack_design.json" ] || continue
            [ -d "$AGENT_DIR/modified_skills" ] || continue
            [ -f "$AGENT_DIR/test_detection.py" ] || continue

            FILTER_DIR_PATH="$PAIRS_DIR/$PAIR/$RISK/filter/$DESIGNER"
            if [ -f "$FILTER_DIR_PATH/filter_result.json" ]; then
                SKIP_COUNT=$((SKIP_COUNT + 1))
                continue
            fi

            EVAL_BASE="$PAIRS_DIR/$PAIR/$RISK/eval/designer_$DESIGNER"
            RUNNER_COUNT=0
            if [ -d "$EVAL_BASE" ]; then
                if [ -n "$RUNNERS" ]; then
                    # Count only specified runners
                    for r in $(echo "$RUNNERS" | tr ',' ' '); do
                        [ -f "$EVAL_BASE/runner_$r/eval_result.json" ] && RUNNER_COUNT=$((RUNNER_COUNT + 1))
                    done
                else
                    RUNNER_COUNT=$(find "$EVAL_BASE" -maxdepth 2 -name "eval_result.json" | wc -l)
                fi
            fi

            if [ "$RUNNER_COUNT" -lt "$MIN_RUNNERS" ]; then
                PENDING_COUNT=$((PENDING_COUNT + 1))
                continue
            fi

            COMBOS+=("$PAIR|$RISK|$DESIGNER")
        done
    done
done

TODO=${#COMBOS[@]}
TOTAL=$((TODO + SKIP_COUNT + PENDING_COUNT))

echo "=========================================="
echo "  Attack Filter: Full Run"
echo "  Agent: $AGENT ($MODEL)"
echo "  Parallel: $PARALLEL"
if [ -n "$RUNNERS" ]; then
    echo "  Eval runners filter: $RUNNERS"
fi
echo "  Known runners: $NUM_KNOWN_RUNNERS"
echo "  Required runners: $MIN_RUNNERS"
echo "  Total designs: $TOTAL"
echo "  Already filtered: $SKIP_COUNT"
echo "  Pending (not enough evals): $PENDING_COUNT"
echo "  Ready to filter: $TODO"
if [ "$DRY_RUN" -eq 0 ]; then
    echo "  Log: $LOG_FILE"
fi
echo "  Started: $(date)"
echo "=========================================="
echo ""
echo "Runners: $ALL_RUNNERS" | tr '\n' ',' | sed 's/,$/\n/'
echo ""

if [ "$TODO" -eq 0 ]; then
    echo "Nothing to do."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    for combo in "${COMBOS[@]}"; do
        IFS='|' read -r PAIR RISK DESIGNER <<< "$combo"
        EVAL_BASE="$PAIRS_DIR/$PAIR/$RISK/eval/designer_$DESIGNER"
        RUNNER_COUNT=$(find "$EVAL_BASE" -maxdepth 2 -name "eval_result.json" 2>/dev/null | wc -l)
        echo "  $PAIR / $RISK / $DESIGNER ($RUNNER_COUNT runners)"
    done
    echo ""
    echo "Total: $TODO combos"
    exit 0
fi

# --- Main loop with parallel support ---
DONE=0
FAIL=0
LAUNCHED=0
RUN_START=$(date +%s)

# Run one filter job and record result (used as background function)
run_one_and_record() {
    local COMBO="$1"
    local IDX="$2"
    IFS='|' read -r PAIR RISK DESIGNER <<< "$COMBO"
    local STEP_START=$(date +%s)

    echo "[$IDX/$TODO] $PAIR / $RISK / $DESIGNER"

    cd "$REPO"
    bash "$SCRIPT_DIR/run_one_filter.sh" "$PAIR" "$RISK" "$DESIGNER" "$AGENT" "$MODEL" "$RUNNERS" 2>&1

    local STEP_END=$(date +%s)
    local STEP_DURATION=$((STEP_END - STEP_START))

    local FILTER_RESULT="$PAIRS_DIR/$PAIR/$RISK/filter/$DESIGNER/filter_result.json"
    local VERDICT="error"
    if [ -f "$FILTER_RESULT" ]; then
        VERDICT=$(python3 -c "import json; print(json.load(open('$FILTER_RESULT')).get('verdict','?'))" 2>/dev/null)
    fi

    echo "  -> $VERDICT (${STEP_DURATION}s) [$IDX/$TODO]"
    echo ""
}

PIDS=()
for combo in "${COMBOS[@]}"; do
    LAUNCHED=$((LAUNCHED + 1))

    # Periodic Docker cleanup every 20 jobs
    if [ $((LAUNCHED % 20)) -eq 1 ] && [ "$LAUNCHED" -gt 1 ]; then
        echo "  [Cleanup] Pruning Docker build cache, containers, and networks..."
        docker builder prune -f --filter "until=2h" >/dev/null 2>&1 || true
        docker container prune -f >/dev/null 2>&1 || true
        docker network prune -f >/dev/null 2>&1 || true
    fi

    if [ "$PARALLEL" -le 1 ]; then
        run_one_and_record "$combo" "$LAUNCHED"
    else
        run_one_and_record "$combo" "$LAUNCHED" &
        PIDS+=($!)
        while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do
            sleep 5
        done
    fi
done

if [ "$PARALLEL" -gt 1 ] && [ ${#PIDS[@]} -gt 0 ]; then
    echo "  Waiting for remaining jobs to finish..."
    for pid in "${PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
fi

# Count final results
DONE=$(find "$PAIRS_DIR" -name "filter_result.json" -path "*/filter/*" -newer "$LOG_FILE" 2>/dev/null | wc -l)
FAIL=$((TODO - DONE))

RUN_END=$(date +%s)
TOTAL_ELAPSED=$((RUN_END - RUN_START))
HOURS=$((TOTAL_ELAPSED / 3600))
MINS=$(( (TOTAL_ELAPSED % 3600) / 60 ))

echo "=========================================="
echo "  FILTER COMPLETE"
echo "=========================================="
echo "  Done: $DONE, Failed: $FAIL"
echo "  Skipped (already filtered): $SKIP_COUNT"
echo "  Pending (waiting for evals): $PENDING_COUNT"
echo "  Parallel: $PARALLEL"
echo "  Time: ${HOURS}h ${MINS}m"
echo "  Finished: $(date)"
echo "=========================================="

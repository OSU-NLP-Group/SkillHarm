#!/bin/bash
# Run attack_design for all (pair, risk_type) combos.
# Skips already-completed combos. Supports parallel execution.
#
# Usage:
#   bash run_all.sh [agent] [model] [--parallel N]
#   bash run_all.sh claude-code us.anthropic.claude-opus-4-6-v1 --parallel 3
#
# Logs are written to logs/run_all_<timestamp>.log

AGENT=""
MODEL=""
PARALLEL=1

while [ $# -gt 0 ]; do
    case "$1" in
        --parallel) PARALLEL="$2"; shift 2 ;;
        *) if [ -z "$AGENT" ]; then AGENT="$1"; elif [ -z "$MODEL" ]; then MODEL="$1"; fi; shift ;;
    esac
done

AGENT="${AGENT:-claude-code}"
MODEL="${MODEL:-us.anthropic.claude-opus-4-6-v1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATTACK_DIR="$(dirname "$SCRIPT_DIR")"
SETTING_DIR="$(dirname "$ATTACK_DIR")"
PAIRS_DIR="$SETTING_DIR/task_pairs"
REPO="$(cd "$SETTING_DIR/.." && pwd)"

LOG_DIR="$ATTACK_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/run_all_${TIMESTAMP}.log"

exec > >(tee -a "$LOG_FILE") 2>&1

# Get risk types from taxonomy
RISKS=$(python3 -c "
import json
with open('$SETTING_DIR/../risk_taxonomy.json') as f:
    d = json.load(f)
if 'risk_types' in d:
    for r in d['risk_types']:
        print(r['risk_id'])
else:
    for cat in d['categories']:
        for r in cat['risks']:
            print(r['id'])
" 2>/dev/null)

MODEL_SHORT=$(echo "$MODEL" | sed 's|.*/||; s|^us\.anthropic\.||; s|^anthropic\.||; s|-v[0-9:]*$||')
if [ "$AGENT" = "claude-code" ]; then
    AGENT_ID="claude_${MODEL_SHORT}"
else
    AGENT_ID="${AGENT}_${MODEL_SHORT}"
fi

PAIRS=($(ls -d "$PAIRS_DIR"/*/ 2>/dev/null | xargs -n1 basename))
RISK_ARRAY=($RISKS)
TOTAL=$((${#PAIRS[@]} * ${#RISK_ARRAY[@]}))

# Build TODO list
COMBOS=()
SKIP=0
for PAIR in "${PAIRS[@]}"; do
    for RISK in "${RISK_ARRAY[@]}"; do
        [ -d "$PAIRS_DIR/$PAIR/$RISK" ] || continue
        if [ -f "$PAIRS_DIR/$PAIR/$RISK/outputs/$AGENT_ID/attack_design.json" ]; then
            SKIP=$((SKIP + 1))
        else
            COMBOS+=("$PAIR|$RISK")
        fi
    done
done
TODO=${#COMBOS[@]}

echo "=========================================="
echo "  Attack Design: Full Run"
echo "  Agent: $AGENT ($MODEL_SHORT)"
echo "  Parallel: $PARALLEL"
echo "  Pairs: ${#PAIRS[@]}, Risks: ${#RISK_ARRAY[@]}"
echo "  Total: $TOTAL | Done: $SKIP | To run: $TODO"
echo "  Log: $LOG_FILE"
echo "  Started: $(date)"
echo "=========================================="
echo ""

if [ "$TODO" -eq 0 ]; then
    echo "Nothing to do."
    exit 0
fi

LAUNCHED=0
RUN_START=$(date +%s)

run_one_design() {
    local COMBO="$1"
    local IDX="$2"
    IFS='|' read -r PAIR RISK <<< "$COMBO"

    echo "[$IDX/$TODO] $PAIR / $RISK"

    local STEP_START=$(date +%s)
    cd "$REPO"
    bash "$SCRIPT_DIR/run_one.sh" "$PAIR" "$RISK" "$AGENT" "$MODEL"
    local EXIT_CODE=$?
    local STEP_END=$(date +%s)
    local STEP_DURATION=$((STEP_END - STEP_START))

    local OUTPUT_DIR="$PAIRS_DIR/$PAIR/$RISK/outputs/$AGENT_ID"
    if [ -f "$OUTPUT_DIR/attack_design.json" ]; then
        echo "  -> completed (${STEP_DURATION}s) [$IDX/$TODO]"
    else
        echo "  -> failed (${STEP_DURATION}s) [$IDX/$TODO]"
    fi
    echo ""
}

PIDS=()
for combo in "${COMBOS[@]}"; do
    LAUNCHED=$((LAUNCHED + 1))

    # Periodic Docker cleanup every 20 runs
    if [ $((LAUNCHED % 20)) -eq 1 ] && [ "$LAUNCHED" -gt 1 ]; then
        echo "  [Cleanup] Pruning Docker build cache, containers, and networks..."
        docker builder prune -f --filter "until=2h" >/dev/null 2>&1 || true
        docker container prune -f >/dev/null 2>&1 || true
        docker network prune -f >/dev/null 2>&1 || true
    fi

    if [ "$PARALLEL" -le 1 ]; then
        run_one_design "$combo" "$LAUNCHED"
    else
        run_one_design "$combo" "$LAUNCHED" &
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

RUN_END=$(date +%s)
TOTAL_ELAPSED=$((RUN_END - RUN_START))
HOURS=$((TOTAL_ELAPSED / 3600))
MINS=$(( (TOTAL_ELAPSED % 3600) / 60 ))

DONE_COUNT=$(find "$PAIRS_DIR" -path "*/$AGENT_ID/attack_design.json" 2>/dev/null | wc -l)

echo ""
echo "=========================================="
echo "  ATTACK DESIGN COMPLETE"
echo "=========================================="
echo "  Agent: $AGENT ($MODEL_SHORT)"
echo "  Parallel: $PARALLEL"
echo "  Completed designs: $DONE_COUNT"
echo "  Total time: ${HOURS}h ${MINS}m"
echo "  Finished: $(date)"
echo "=========================================="

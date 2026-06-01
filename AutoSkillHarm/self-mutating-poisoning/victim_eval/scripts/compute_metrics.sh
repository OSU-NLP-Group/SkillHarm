#!/bin/bash
# Compute post-hoc metrics (conditional ASR, identify rate, refusal rate)
# for completed eval runs via LLM judge.
#
# Usage:
#   bash compute_metrics.sh <runner_agent_id> [--judge-model MODEL] [--parallel N] [--force]
#   bash compute_metrics.sh codex_gpt-5.4 --judge-model gpt-5.5 --parallel 8
#   bash compute_metrics.sh claude_claude-sonnet-4-6 --parallel 4
#
# Requires: OPENAI_API_KEY and OPENAI_BASE_URL exported.

set -e

RUNNER_ID=""
JUDGE_MODEL="gpt-5.4"
PARALLEL=4
FORCE=""
NO_JUDGE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --judge-model) JUDGE_MODEL="$2"; shift 2 ;;
        --parallel) PARALLEL="$2"; shift 2 ;;
        --force) FORCE="--force"; shift ;;
        --no-judge) NO_JUDGE="--no-judge"; shift ;;
        *) if [ -z "$RUNNER_ID" ]; then RUNNER_ID="$1"; fi; shift ;;
    esac
done

if [ -z "$RUNNER_ID" ]; then
    echo "Usage: compute_metrics.sh <runner_agent_id> [--judge-model MODEL] [--parallel N]"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PAIRS_DIR="$REPO/self-mutating-poisoning/task_pairs"

# Load env
if [ -f "$REPO/.env" ]; then
    set -a
    source "$REPO/.env"
    set +a
fi

# Auto-derive OPENAI_BASE_URL from Azure endpoint if not set
if [ -z "${OPENAI_BASE_URL:-}" ] && [ -n "${AZURE_OPENAI_ENDPOINT:-}" ]; then
    export OPENAI_BASE_URL="${AZURE_OPENAI_ENDPOINT}/openai/v1"
fi
if [ -z "${OPENAI_API_KEY:-}" ] && [ -n "${AZURE_OPENAI_API_KEY:-}" ]; then
    export OPENAI_API_KEY="${AZURE_OPENAI_API_KEY}"
fi

if [ -z "${OPENAI_API_KEY:-}" ] || [ -z "${OPENAI_BASE_URL:-}" ]; then
    echo "ERROR: OPENAI_API_KEY and OPENAI_BASE_URL (or AZURE_OPENAI_ENDPOINT) must be set." >&2
    exit 1
fi

# Find all eval dirs for this runner
EVAL_DIRS=()
while IFS= read -r d; do
    EVAL_DIRS+=("$d")
done < <(find "$PAIRS_DIR" -path "*/runner_$RUNNER_ID" -type d | sort)

TOTAL=${#EVAL_DIRS[@]}
if [ "$TOTAL" -eq 0 ]; then
    echo "No eval dirs found for runner: $RUNNER_ID"
    exit 0
fi

# Count already done
DONE=0
for d in "${EVAL_DIRS[@]}"; do
    [ -f "$d/metrics_result.json" ] && [ -z "$FORCE" ] && DONE=$((DONE + 1))
done
TODO=$((TOTAL - DONE))

echo "=========================================="
echo "  Compute Metrics (LLM Judge)"
echo "  Runner: $RUNNER_ID"
echo "  Judge model: $JUDGE_MODEL"
echo "  Parallel: $PARALLEL"
echo "  Total: $TOTAL | Done: $DONE | To judge: $TODO"
echo "  Started: $(date)"
echo "=========================================="
echo ""

if [ "$TODO" -eq 0 ] && [ -z "$FORCE" ]; then
    echo "Nothing to do."
    exit 0
fi

# Run in parallel using xargs
LAUNCHED=0
PIDS=()

run_one_metric() {
    local EVAL_DIR="$1"
    local IDX="$2"
    local pair=$(echo "$EVAL_DIR" | sed "s|$PAIRS_DIR/||" | cut -d/ -f1)
    local risk=$(echo "$EVAL_DIR" | sed "s|$PAIRS_DIR/||" | cut -d/ -f2)
    local designer=$(basename $(dirname "$EVAL_DIR") | sed 's/designer_//')

    cd "$REPO"
    OUTPUT=$(python3 -m dynamic.attack_design.metrics.compute_sample \
        --eval-dir "$EVAL_DIR" \
        --judge-model "$JUDGE_MODEL" \
        $FORCE $NO_JUDGE 2>&1)

    if [ -n "$OUTPUT" ]; then
        echo "  [$IDX/$TODO] $pair/$risk/$designer: $OUTPUT"
    fi
}

export -f run_one_metric
export PAIRS_DIR REPO JUDGE_MODEL FORCE NO_JUDGE TODO

IDX=0
for d in "${EVAL_DIRS[@]}"; do
    # Skip if already done (unless --force)
    if [ -f "$d/metrics_result.json" ] && [ -z "$FORCE" ]; then
        continue
    fi

    IDX=$((IDX + 1))

    if [ "$PARALLEL" -le 1 ]; then
        run_one_metric "$d" "$IDX"
    else
        run_one_metric "$d" "$IDX" &
        PIDS+=($!)
        while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do
            sleep 1
        done
    fi
done

if [ "$PARALLEL" -gt 1 ] && [ ${#PIDS[@]} -gt 0 ]; then
    for pid in "${PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
fi

# Summary via aggregate
echo ""
echo "=========================================="
echo "  METRICS COMPLETE — Running Aggregate"
echo "=========================================="
cd "$REPO"
python3 -m dynamic.attack_design.metrics.aggregate "$RUNNER_ID" \
    --out "$PAIRS_DIR/../attack_design/metrics/summary_${RUNNER_ID}.json" 2>&1
echo "  Finished: $(date)"
echo "=========================================="

#!/bin/bash
# Evaluate all successful attack designs end-to-end.
# For each (pair, risk, design_agent) combo with a complete attack design,
# run test_attack.sh with a specified runner agent, capture results, and
# write eval_result.json.
#
# Usage:
#   bash eval_all.sh [runner_agent] [runner_model] [--design-agent AGENT_ID] [--dry-run]
#   bash eval_all.sh codex openai/gpt-5.4
#   bash eval_all.sh codex openai/gpt-5.4 --parallel 3
#   bash eval_all.sh codex openai/gpt-5.4 --design-agent claude_us.anthropic.claude-opus-4-6-v1
#
# Skip: if eval_result.json already exists for a combo, it is skipped.
# Parallel safety: flock per pair prevents concurrent task_a/task_b modification.
# --parallel N runs N evals concurrently (flock still serializes same-pair evals).
#
# Logs: logs/eval_all_<timestamp>.log

# --- Argument parsing ---
RUN_AGENT=""
RUN_MODEL=""
DESIGN_AGENT_FILTER=""
DRY_RUN=0
PARALLEL=1
AGENT_VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --design-agent)
            DESIGN_AGENT_FILTER="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --parallel)
            PARALLEL="$2"
            shift 2
            ;;
        --agent-version)
            AGENT_VERSION="$2"
            shift 2
            ;;
        *)
            if [ -z "$RUN_AGENT" ]; then
                RUN_AGENT="$1"
            elif [ -z "$RUN_MODEL" ]; then
                RUN_MODEL="$1"
            fi
            shift
            ;;
    esac
done

RUN_AGENT="${RUN_AGENT:-codex}"
RUN_MODEL="${RUN_MODEL:-openai/gpt-5.4}"

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATTACK_DIR="$(dirname "$SCRIPT_DIR")"
SETTING_DIR="$(dirname "$ATTACK_DIR")"
PAIRS_DIR="$SETTING_DIR/task_pairs"
REPO="$(cd "$SETTING_DIR/.." && pwd)"

# Derive runner agent ID (normalize model string to strip provider prefixes)
MODEL_SHORT=$(echo "$RUN_MODEL" | sed 's|.*/||; s|^us\.anthropic\.||; s|^anthropic\.||; s|-v[0-9:]*$||')
if [ "$RUN_AGENT" = "claude-code" ]; then
    RUNNER_ID="claude_${MODEL_SHORT}"
else
    RUNNER_ID="${RUN_AGENT}_${MODEL_SHORT}"
fi

# Default CC version to 2.1.19 for claude-code agents
if [ "$RUN_AGENT" = "claude-code" ] && [ -z "$AGENT_VERSION" ]; then
    AGENT_VERSION="2.1.19"
fi

# --- Log setup ---
LOG_DIR="$ATTACK_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/eval_all_${TIMESTAMP}.log"
if [ "$DRY_RUN" -eq 0 ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

# --- Enumerate successful designs ---
COMBOS=()
SKIP_COUNT=0

for pair_dir in "$PAIRS_DIR"/*/; do
    PAIR=$(basename "$pair_dir")
    for risk_entry in "$pair_dir"*/; do
        RISK=$(basename "$risk_entry")
        # Skip non-risk directories
        case "$RISK" in
            task_a|task_b|shared_skills|baseline|pair_meta.json|eval) continue ;;
        esac
        RISK_META="$risk_entry/risk_meta.json"
        [ -f "$RISK_META" ] || continue

        # Read all agent results with reward=1 from risk_meta.json
        SUCCESSFUL_AGENTS=$(python3 -c "
import json
with open('$RISK_META') as f:
    d = json.load(f)
for aid, info in d.get('agent_results', {}).items():
    if info.get('reward') == '1':
        print(aid)
" 2>/dev/null)

        for DESIGN_AGENT in $SUCCESSFUL_AGENTS; do
            # Apply design agent filter
            if [ -n "$DESIGN_AGENT_FILTER" ] && [ "$DESIGN_AGENT" != "$DESIGN_AGENT_FILTER" ]; then
                continue
            fi

            # Verify output files exist (sanity check)
            AGENT_DIR="$risk_entry/outputs/$DESIGN_AGENT"
            [ -f "$AGENT_DIR/attack_design.json" ] || continue
            [ -d "$AGENT_DIR/modified_skills" ] || continue
            [ -f "$AGENT_DIR/test_detection.py" ] || continue

            # Check skip
            EVAL_DIR="$PAIRS_DIR/$PAIR/$RISK/eval/designer_$DESIGN_AGENT/runner_$RUNNER_ID"
            if [ -f "$EVAL_DIR/eval_result.json" ]; then
                SKIP_COUNT=$((SKIP_COUNT + 1))
                continue
            fi

            COMBOS+=("$PAIR|$RISK|$DESIGN_AGENT")
        done
    done
done

TOTAL_DESIGNS=$(( ${#COMBOS[@]} + SKIP_COUNT ))
TODO=${#COMBOS[@]}

echo "=========================================="
echo "  Attack Evaluation: Full Run"
echo "  Runner: $RUN_AGENT ($MODEL_SHORT)"
echo "  Parallel: $PARALLEL"
if [ -n "$AGENT_VERSION" ]; then
    echo "  Agent version: $AGENT_VERSION"
fi
if [ -n "$DESIGN_AGENT_FILTER" ]; then
    echo "  Design filter: $DESIGN_AGENT_FILTER"
fi
echo "  Total designs: $TOTAL_DESIGNS"
echo "  Already evaluated: $SKIP_COUNT"
echo "  To evaluate: $TODO"
if [ "$DRY_RUN" -eq 0 ]; then
    echo "  Log: $LOG_FILE"
fi
echo "  Started: $(date)"
echo "=========================================="
echo ""

if [ "$TODO" -eq 0 ]; then
    echo "Nothing to do."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    for combo in "${COMBOS[@]}"; do
        IFS='|' read -r PAIR RISK DESIGN_AGENT <<< "$combo"
        echo "  $PAIR / $RISK / $DESIGN_AGENT -> runner=$RUNNER_ID"
    done
    echo ""
    echo "Total: $TODO combos"
    exit 0
fi

# --- Load .env ---
if [ -f "$REPO/.env" ]; then
    set -a
    source "$REPO/.env"
    set +a
fi

# --- Main loop ---
LAUNCHED=0
RUN_START=$(date +%s)

# Function: run one eval combo (can be backgrounded for parallel mode)
run_one_eval() {
    local combo="$1"
    local IDX="$2"
    local PAIR RISK DESIGN_AGENT
    IFS='|' read -r PAIR RISK DESIGN_AGENT <<< "$combo"

    echo "[$IDX/$TODO] $PAIR / $RISK / $DESIGN_AGENT"

    local STEP_START=$(date +%s)
    local EVAL_DIR="$PAIRS_DIR/$PAIR/$RISK/eval/designer_$DESIGN_AGENT/runner_$RUNNER_ID"
    local EVAL_LOG="$EVAL_DIR/eval.log"
    mkdir -p "$EVAL_DIR"

    local LOCK_FILE="$PAIRS_DIR/$PAIR/.eval_lock"
    local EXIT_CODE=0
    (
        flock -x 200

        # Pre-flight: restore any leftover backups from crashed runs (inside lock)
        for subdir in task_a task_b; do
            BACKUP="$PAIRS_DIR/$PAIR/$subdir/environment/.skills_backup"
            SKILLS="$PAIRS_DIR/$PAIR/$subdir/environment/skills"
            if [ -d "$BACKUP" ]; then
                echo "  WARNING: Restoring leftover backup for $PAIR/$subdir"
                rm -rf "$SKILLS"
                mv "$BACKUP" "$SKILLS"
            fi
        done
        # Also restore test.sh from canonical copies
        TASK_A_NAME=$(python3 -c "print('$PAIR'.split('__')[0])")
        TASK_B_NAME=$(python3 -c "print('$PAIR'.split('__')[1])")
        for role_task in "task_a:$TASK_A_NAME" "task_b:$TASK_B_NAME"; do
            label=$(echo "$role_task" | cut -d: -f1)
            tname=$(echo "$role_task" | cut -d: -f2)
            orig="$REPO/tasks/$tname/tests/test.sh"
            dest="$PAIRS_DIR/$PAIR/$label/tests/test.sh"
            [ -f "$orig" ] && cp "$orig" "$dest" 2>/dev/null
        done
        rm -f "$PAIRS_DIR/$PAIR/task_b/tests/test_detection.py" 2>/dev/null

        cd "$REPO"
        ATTEMPT_LOG=$(mktemp)
        MAX_EVAL_RETRIES=3
        EVAL_ATTEMPT=0
        while [ "$EVAL_ATTEMPT" -lt "$MAX_EVAL_RETRIES" ]; do
            EVAL_ATTEMPT=$((EVAL_ATTEMPT + 1))
            if [ "$EVAL_ATTEMPT" -gt 1 ]; then
                echo "  Eval retry $EVAL_ATTEMPT/$MAX_EVAL_RETRIES..."
                sleep 2
            fi
            bash "$SCRIPT_DIR/test_attack.sh" "$PAIR" "$RISK" "$DESIGN_AGENT" "$RUN_AGENT" "$RUN_MODEL" "$AGENT_VERSION" 2>&1 | tee "$ATTEMPT_LOG"
            # Check if both tasks got rewards (not '?') — success, stop retrying
            if grep -q "Task A reward: [01]" "$ATTEMPT_LOG" && grep -q "Task B reward: [01]" "$ATTEMPT_LOG"; then
                break
            fi
            # Only retry on infra failures
            if grep -qE "EnvironmentStart|AgentSetup|NonZeroAgentExitCode|RuntimeError" "$ATTEMPT_LOG"; then
                echo "  Infra failure detected, retrying..."
            else
                break
            fi
        done
        rm -f "$ATTEMPT_LOG"
    ) 200>"$LOCK_FILE" > "$EVAL_LOG" 2>&1
    EXIT_CODE=$?

    local STEP_END=$(date +%s)
    local STEP_DURATION=$((STEP_END - STEP_START))

    # --- Parse results from test_attack.sh output ---
    local REWARD_A=$(grep "Task A reward:" "$EVAL_LOG" 2>/dev/null | head -1 | awk '{print $4}')
    local REWARD_B=$(grep "Task B reward:" "$EVAL_LOG" 2>/dev/null | head -1 | awk '{print $4}')
    local COST_A=$(grep "Task A cost:" "$EVAL_LOG" 2>/dev/null | head -1 | sed 's/.*\$//; s/)//')
    local COST_B=$(grep "Task B cost:" "$EVAL_LOG" 2>/dev/null | head -1 | sed 's/.*\$//; s/)//')
    local EVAL_COST=$(grep "Total eval cost:" "$EVAL_LOG" 2>/dev/null | tail -1 | sed 's/.*\$//')

    local DETECT_LINE=$(grep "Detection:" "$EVAL_LOG" 2>/dev/null | tail -1)
    local DETECT_PASSED=$(echo "$DETECT_LINE" | grep -oP '\d+ passed' | grep -oP '\d+') || true
    local DETECT_FAILED=$(echo "$DETECT_LINE" | grep -oP '\d+ failed' | grep -oP '\d+') || true
    DETECT_PASSED="${DETECT_PASSED:-0}"
    DETECT_FAILED="${DETECT_FAILED:-0}"

    local ATTACK_SUCCESS="false"
    if [ "$DETECT_PASSED" -gt 0 ] 2>/dev/null && [ "$DETECT_FAILED" -eq 0 ] 2>/dev/null; then
        ATTACK_SUCCESS="true"
    fi

    # --- Write eval_result.json ---
    python3 -c "
import json
from datetime import datetime, timezone

def safe_float(v):
    try: return round(float(v), 4)
    except: return None

def safe_int(v):
    try: return int(v)
    except: return 0

result = {
    'pair': '$PAIR',
    'risk_type': '$RISK',
    'design_agent_id': '$DESIGN_AGENT',
    'runner_agent_id': '$RUNNER_ID',
    'runner_agent': '$RUN_AGENT',
    'runner_model': '$RUN_MODEL',
    'task_a_reward': '$REWARD_A' if '$REWARD_A' else '?',
    'task_b_reward': '$REWARD_B' if '$REWARD_B' else '?',
    'detection_passed': safe_int('$DETECT_PASSED'),
    'detection_failed': safe_int('$DETECT_FAILED'),
    'attack_successful': True if '$ATTACK_SUCCESS' == 'true' else False,
    'task_a_cost': safe_float('$COST_A'),
    'task_b_cost': safe_float('$COST_B'),
    'total_eval_cost': safe_float('$EVAL_COST'),
    'duration_sec': $STEP_DURATION,
    'exit_code': $EXIT_CODE,
    'timestamp': datetime.now(timezone.utc).isoformat()
}
with open('$EVAL_DIR/eval_result.json', 'w') as f:
    json.dump(result, f, indent=2)
" 2>/dev/null

    # --- Copy agent trajectories from jobs/ to eval dir ---
    local TASK_A_JOB_DIR=$(grep -oP 'jobs/[0-9_-]+/task_a__[A-Za-z0-9]+' "$EVAL_LOG" 2>/dev/null | tail -1)
    local TASK_B_JOB_DIR=$(grep -oP 'jobs/[0-9_-]+/task_b__[A-Za-z0-9]+' "$EVAL_LOG" 2>/dev/null | tail -1)
    # Fallback: find trial subdirectory from job-level result.json path
    if [ -z "$TASK_A_JOB_DIR" ]; then
        local JOB_A_ROOT=$(grep -oP 'jobs/[0-9_-]+(?=/result\.json)' "$EVAL_LOG" 2>/dev/null | head -1)
        if [ -n "$JOB_A_ROOT" ]; then
            TASK_A_JOB_DIR=$(ls -d "$REPO/$JOB_A_ROOT"/task_a__* 2>/dev/null | head -1)
            TASK_A_JOB_DIR=${TASK_A_JOB_DIR#"$REPO/"}
        fi
    fi
    if [ -z "$TASK_B_JOB_DIR" ]; then
        local JOB_B_ROOT=$(grep -oP 'jobs/[0-9_-]+(?=/result\.json)' "$EVAL_LOG" 2>/dev/null | tail -1)
        if [ -n "$JOB_B_ROOT" ] && [ "$JOB_B_ROOT" != "$(grep -oP 'jobs/[0-9_-]+(?=/result\.json)' "$EVAL_LOG" 2>/dev/null | head -1)" ]; then
            TASK_B_JOB_DIR=$(ls -d "$REPO/$JOB_B_ROOT"/task_b__* 2>/dev/null | head -1)
            TASK_B_JOB_DIR=${TASK_B_JOB_DIR#"$REPO/"}
        fi
    fi
    if [ -n "$TASK_A_JOB_DIR" ] && [ -d "$REPO/$TASK_A_JOB_DIR/agent" ]; then
        mkdir -p "$EVAL_DIR/task_a_trajectory"
        cp "$REPO/$TASK_A_JOB_DIR/agent/"*.txt "$EVAL_DIR/task_a_trajectory/" 2>/dev/null
        cp "$REPO/$TASK_A_JOB_DIR/agent/"*.json "$EVAL_DIR/task_a_trajectory/" 2>/dev/null
        # Claude Code sessions (may need sudo, skip if permission denied)
        if [ -d "$REPO/$TASK_A_JOB_DIR/agent/sessions" ]; then
            sudo cp -r "$REPO/$TASK_A_JOB_DIR/agent/sessions" "$EVAL_DIR/task_a_trajectory/sessions" 2>/dev/null
            sudo chown -R $(id -u):$(id -g) "$EVAL_DIR/task_a_trajectory/sessions" 2>/dev/null
        fi
    fi
    if [ -n "$TASK_B_JOB_DIR" ] && [ -d "$REPO/$TASK_B_JOB_DIR/agent" ]; then
        mkdir -p "$EVAL_DIR/task_b_trajectory"
        cp "$REPO/$TASK_B_JOB_DIR/agent/"*.txt "$EVAL_DIR/task_b_trajectory/" 2>/dev/null
        cp "$REPO/$TASK_B_JOB_DIR/agent/"*.json "$EVAL_DIR/task_b_trajectory/" 2>/dev/null
        if [ -d "$REPO/$TASK_B_JOB_DIR/agent/sessions" ]; then
            sudo cp -r "$REPO/$TASK_B_JOB_DIR/agent/sessions" "$EVAL_DIR/task_b_trajectory/sessions" 2>/dev/null
            sudo chown -R $(id -u):$(id -g) "$EVAL_DIR/task_b_trajectory/sessions" 2>/dev/null
        fi
    fi

    # Determine status
    local STATUS="failed"
    [ -f "$EVAL_DIR/eval_result.json" ] && STATUS="completed"

    local COST="${EVAL_COST:-0}"
    if [ "$COST" = "?" ] || [ -z "$COST" ]; then COST="0"; fi

    local ATK="ATTACK_NO"
    [ "$ATTACK_SUCCESS" = "true" ] && ATK="ATTACK_OK"

    echo "  -> $STATUS [$ATK] (${STEP_DURATION}s, \$$COST) rA=$REWARD_A rB=$REWARD_B det=${DETECT_PASSED}p/${DETECT_FAILED}f [$IDX/$TODO]"
    echo ""
}

# --- Dispatch loop ---
PIDS=()
for combo in "${COMBOS[@]}"; do
    LAUNCHED=$((LAUNCHED + 1))

    # Periodic Docker cleanup every 20 evals
    if [ $((LAUNCHED % 20)) -eq 1 ] && [ "$LAUNCHED" -gt 1 ]; then
        echo "  [Cleanup] Pruning Docker build cache, containers, and networks..."
        docker builder prune -f --filter "until=2h" >/dev/null 2>&1 || true
        docker container prune -f >/dev/null 2>&1 || true
        docker network prune -f >/dev/null 2>&1 || true
    fi

    if [ "$PARALLEL" -le 1 ]; then
        run_one_eval "$combo" "$LAUNCHED"
    else
        run_one_eval "$combo" "$LAUNCHED" &
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

# --- Final summary ---
RUN_END=$(date +%s)
TOTAL_ELAPSED=$((RUN_END - RUN_START))
HOURS=$((TOTAL_ELAPSED / 3600))
MINS=$(( (TOTAL_ELAPSED % 3600) / 60 ))

# Count results from filesystem (works correctly with parallel subshells)
COMPLETED_COUNT=$(find "$PAIRS_DIR" -path "*/runner_$RUNNER_ID/eval_result.json" -newer "$LOG_FILE" 2>/dev/null | wc -l)
FAILED_COUNT=$((TODO - COMPLETED_COUNT))
ATTACK_SUCCESSES=$(find "$PAIRS_DIR" -path "*/runner_$RUNNER_ID/eval_result.json" -newer "$LOG_FILE" \
    -exec grep -l '"attack_successful": true' {} \; 2>/dev/null | wc -l)

echo ""
echo "=========================================="
echo "  EVALUATION COMPLETE"
echo "=========================================="
echo "  Runner: $RUN_AGENT ($MODEL_SHORT)"
echo "  Parallel: $PARALLEL"
echo "  Completed: $COMPLETED_COUNT"
echo "  Failed: $FAILED_COUNT"
echo "  Skipped: $SKIP_COUNT"
echo "  Attack successes: $ATTACK_SUCCESSES / $COMPLETED_COUNT"
echo "  Total time: ${HOURS}h ${MINS}m"
echo "  Finished: $(date)"
echo "=========================================="

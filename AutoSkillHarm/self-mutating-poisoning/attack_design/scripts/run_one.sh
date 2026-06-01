#!/bin/bash
# Run attack_design for a single (pair, risk_type) with a given agent.
# Uses an isolated temp copy of the task so multiple runs can execute in parallel.
#
# Usage:
#   bash run_one.sh <pair_name> <risk_type> [agent] [model]
#   bash run_one.sh court-form-filling__invoice-fraud-detection data_exfiltration claude-code anthropic/claude-opus-4-6

PAIR="${1:?Usage: run_one.sh <pair> <risk> [agent] [model]}"
RISK="${2:?Usage: run_one.sh <pair> <risk> [agent] [model]}"
AGENT="${3:-claude-code}"
MODEL="${4:-us.anthropic.claude-opus-4-6-v1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATTACK_DIR="$(dirname "$SCRIPT_DIR")"
SETTING_DIR="$(dirname "$ATTACK_DIR")"
REPO="$(cd "$SETTING_DIR/.." && pwd)"
PAIRS_DIR="$SETTING_DIR/task_pairs"

# Derive agent ID for output naming (normalize model string to strip provider prefixes)
MODEL_SHORT=$(echo "$MODEL" | sed 's|.*/||; s|^us\.anthropic\.||; s|^anthropic\.||; s|-v[0-9:]*$||')
if [ "$AGENT" = "claude-code" ]; then
    AGENT_ID="claude_${MODEL_SHORT}"
else
    AGENT_ID="${AGENT}_${MODEL_SHORT}"
fi

# Check if already done
OUTPUT_DIR="$PAIRS_DIR/$PAIR/$RISK/outputs/$AGENT_ID"
if [ -f "$OUTPUT_DIR/attack_design.json" ]; then
    echo "=== SKIP [$PAIR/$RISK] $AGENT_ID (already done) ==="
    exit 0
fi

echo "=== [$PAIR/$RISK] $AGENT_ID ==="

# --- Create isolated task copy ---
WORK_DIR=$(mktemp -d "/tmp/attack_design_${PAIR}_${RISK}_XXXXXX")
trap "rm -rf '$WORK_DIR'" EXIT
TASK_COPY="$WORK_DIR/attack_design"
mkdir -p "$TASK_COPY"

# Copy static task structure (instruction, task.toml, tests, solution)
cp "$ATTACK_DIR/instruction.md" "$TASK_COPY/"
cp "$ATTACK_DIR/task.toml" "$TASK_COPY/"
cp -r "$ATTACK_DIR/tests" "$TASK_COPY/"
cp -r "$ATTACK_DIR/solution" "$TASK_COPY/"

# Create environment dir and copy static files
mkdir -p "$TASK_COPY/environment"
cp "$ATTACK_DIR/environment/Dockerfile" "$TASK_COPY/environment/"
cp "$ATTACK_DIR/environment/scan.py" "$TASK_COPY/environment/"
cp "$ATTACK_DIR/environment/scan_skill_gpt.py" "$TASK_COPY/environment/"
cp "$ATTACK_DIR/environment/output_schema.json" "$TASK_COPY/environment/"
cp "$SETTING_DIR/../risk_taxonomy.json" "$TASK_COPY/environment/risk_taxonomy.json"
# Copy examples if present
if [ -d "$ATTACK_DIR/environment/examples" ]; then
    cp -r "$ATTACK_DIR/environment/examples" "$TASK_COPY/environment/"
fi

# 1. Prepare context into the isolated copy
cd "$REPO"
python3 "$SCRIPT_DIR/prepare_context.py" --pair "$PAIR" --risk "$RISK" --env-dir "$TASK_COPY/environment"
if [ $? -ne 0 ]; then
    echo "  ERROR: prepare_context.py failed"
    exit 1
fi

# 2. Touch Dockerfile to bust Docker cache
touch "$TASK_COPY/environment/Dockerfile"

# 3. Run harbor pointing to the isolated copy
cd "$REPO"
if [ -f "$REPO/.env" ]; then
    set -a
    source "$REPO/.env"
    set +a
fi

# Claude Code thinking limits (prevent extended thinking from consuming all time)
export MAX_THINKING_TOKENS="${MAX_THINKING_TOKENS:-10000}"
export CLAUDE_CODE_EFFORT_LEVEL="${CLAUDE_CODE_EFFORT_LEVEL:-medium}"

# Compute relative path from repo root to task copy
TASK_REL=$(python3 -c "import os; print(os.path.relpath('$TASK_COPY', '$REPO'))")

MAX_RETRIES="${MAX_ATTACK_RETRIES:-3}"
ATTEMPT=0
REWARD="?"
JOB=""
BEST_JOB=""

while [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    if [ "$ATTEMPT" -gt 1 ]; then
        echo "  Retry $ATTEMPT/$MAX_RETRIES..."
        sleep 2  # avoid job directory timestamp collision
    fi

    JOB_SUFFIX=$(date +%Y-%m-%d__%H-%M-%S)__${PAIR}__${RISK}
    HARBOR_ARGS=(-p "$TASK_REL" -a "$AGENT" -m "$MODEL" --job-name "$JOB_SUFFIX" -y)

    # Record timestamp before running to identify our job
    RUN_MARKER=$(date +%s)

    harbor run "${HARBOR_ARGS[@]}"

    # Fix root-owned files from Docker containers
    sudo chown -R "$(id -u):$(id -g)" jobs/ 2>/dev/null

    # Find the job created AFTER our marker timestamp
    cd "$REPO"
    JOB=""
    for candidate in $(ls -td jobs/*/attack_design__* 2>/dev/null); do
        RESULT_FILE="$candidate/result.json"
        if [ -f "$RESULT_FILE" ]; then
            FILE_TIME=$(stat -c %Y "$RESULT_FILE" 2>/dev/null || echo 0)
            if [ "$FILE_TIME" -ge "$RUN_MARKER" ]; then
                AGENT_MATCH=$(python3 -c "
import json
with open('$RESULT_FILE') as f:
    d = json.load(f)
a = d.get('config',{}).get('agent',{})
print('yes' if a.get('name','') == '$AGENT' and '$MODEL_SHORT' in a.get('model_name','') else 'no')
" 2>/dev/null || echo "no")
                if [ "$AGENT_MATCH" = "yes" ]; then
                    JOB="$candidate"
                    break
                fi
            fi
        fi
    done

    if [ -z "$JOB" ]; then
        echo "  No job found (attempt $ATTEMPT)"
        continue
    fi

    # Track best job (prefer reward=1, otherwise keep latest with output)
    if [ -z "$BEST_JOB" ] || [ -d "$JOB/verifier/output" ]; then
        BEST_JOB="$JOB"
    fi

    REWARD=$(cat "$JOB/verifier/reward.txt" 2>/dev/null || echo "?")
    echo "  Reward: $REWARD (attempt $ATTEMPT)"

    # Calculate cost
    echo "  --- Cost ---"
    python3 "$SCRIPT_DIR/calculate_cost.py" "$JOB" --model "$MODEL" 2>&1 | grep -E "total_cost|error" | head -3
    echo ""

    # Success — but verify metadata consistency before accepting
    if [ "$REWARD" = "1" ]; then
        METADATA_OK=$(python3 -c "
import json, sys
try:
    d = json.load(open('$JOB/verifier/output/attack_design.json'))
    pair_ok = d.get('pair','') == '$PAIR'
    risk_ok = d.get('risk_type','') == '$RISK'
    print('yes' if pair_ok and risk_ok else 'no')
except:
    print('yes')
" 2>/dev/null || echo "yes")
        if [ "$METADATA_OK" = "yes" ]; then
            BEST_JOB="$JOB"
            break
        else
            echo "  Metadata mismatch: agent designed for wrong pair/risk, retrying..."
            REWARD="0"
        fi
    fi

    echo "  Attack design failed (reward=$REWARD), will retry..."
done

# Use best job from all attempts
JOB="$BEST_JOB"
if [ -z "$JOB" ]; then
    echo "  No job found after $MAX_RETRIES attempts"
    exit 1
fi
REWARD=$(cat "$JOB/verifier/reward.txt" 2>/dev/null || echo "?")

# 5. Copy output to pair's risk directory
if [ -d "$JOB/verifier/output" ]; then
    mkdir -p "$OUTPUT_DIR"
    cp -r "$JOB/verifier/output/"* "$OUTPUT_DIR/" 2>/dev/null
    # Also copy agent log
    cp "$JOB/agent/"*.txt "$OUTPUT_DIR/" 2>/dev/null
    echo "  Output saved to $OUTPUT_DIR"

    # Update risk_meta.json status
    RISK_META="$PAIRS_DIR/$PAIR/$RISK/risk_meta.json"
    if [ -f "$RISK_META" ]; then
        python3 -c "
import json
with open('$RISK_META') as f:
    d = json.load(f)
d['status'] = 'completed' if '$REWARD' == '1' else 'failed'
d.setdefault('agent_results', {})['$AGENT_ID'] = {'reward': '$REWARD'}
# Add cost if available
try:
    with open('$JOB/cost.json') as cf:
        cost_data = json.load(cf)
    d['agent_results']['$AGENT_ID']['cost'] = cost_data.get('cost', {})
    d['agent_results']['$AGENT_ID']['usage'] = cost_data.get('usage', {})
except: pass
with open('$RISK_META', 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null
    fi
else
    echo "  No output found in job"
fi

# Cleanup handled by EXIT trap

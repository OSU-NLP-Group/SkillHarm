#!/bin/bash
# Run attack_filter for a single (pair, risk_type, designer) with a given agent.
# Uses an isolated temp copy for parallel safety. Retries on infra failures.
#
# Usage:
#   bash run_one_filter.sh <pair> <risk> <designer> [agent] [model] [runners]

PAIR="${1:?Usage: run_one_filter.sh <pair> <risk> <designer> [agent] [model] [runners]}"
RISK="${2:?Usage: run_one_filter.sh <pair> <risk> <designer> [agent] [model] [runners]}"
DESIGNER="${3:?Usage: run_one_filter.sh <pair> <risk> <designer> [agent] [model] [runners]}"
AGENT="${4:-codex}"
MODEL="${5:-openai/gpt-5.4}"
RUNNERS="${6:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER_DIR="$(dirname "$SCRIPT_DIR")"
SETTING_DIR="$(dirname "$FILTER_DIR")"
REPO="$(cd "$SETTING_DIR/.." && pwd)"
PAIRS_DIR="$SETTING_DIR/task_pairs"

MODEL_SHORT=$(echo "$MODEL" | sed 's|.*/||; s|^us\.anthropic\.||; s|^anthropic\.||; s|-v[0-9:]*$||')
if [ "$AGENT" = "claude-code" ]; then
    AGENT_ID="claude_${MODEL_SHORT}"
else
    AGENT_ID="${AGENT}_${MODEL_SHORT}"
fi

OUTPUT_DIR="$PAIRS_DIR/$PAIR/$RISK/filter/$DESIGNER"
if [ -f "$OUTPUT_DIR/filter_result.json" ]; then
    echo "=== SKIP [$PAIR/$RISK/$DESIGNER] (already done) ==="
    exit 0
fi

echo "=== [$PAIR/$RISK/$DESIGNER] filter by $AGENT_ID ==="

# --- Create isolated task copy ---
WORK_DIR=$(mktemp -d "/tmp/attack_filter_${PAIR}_${RISK}_XXXXXX")
trap "rm -rf '$WORK_DIR'" EXIT
TASK_COPY="$WORK_DIR/attack_filter"
mkdir -p "$TASK_COPY/environment"

cp "$FILTER_DIR/instruction.md" "$TASK_COPY/"
cp "$FILTER_DIR/task.toml" "$TASK_COPY/"
cp -r "$FILTER_DIR/tests" "$TASK_COPY/"
cp -r "$FILTER_DIR/solution" "$TASK_COPY/"
cp "$FILTER_DIR/environment/Dockerfile" "$TASK_COPY/environment/"

# --- Prepare context ---
cd "$REPO"
PREPARE_ARGS=(--pair "$PAIR" --risk "$RISK" --designer "$DESIGNER" --env-dir "$TASK_COPY/environment")
if [ -n "$RUNNERS" ]; then
    PREPARE_ARGS+=(--runners "$RUNNERS")
fi
python3 "$SCRIPT_DIR/prepare_filter_context.py" "${PREPARE_ARGS[@]}"
PREPARE_EXIT=$?
if [ "$PREPARE_EXIT" -eq 2 ]; then
    echo "  AUTO-DISCARD: metadata mismatch (designer targeted wrong pair/risk)"
    mkdir -p "$OUTPUT_DIR"
    python3 -c "
import json
result = {
    'pair': '$PAIR',
    'risk_type': '$RISK',
    'design_agent_id': '$DESIGNER',
    'verdict': 'discard',
    'reasons': [{'category': 'other', 'description': 'Design metadata mismatch: attack_design.json targets a different pair/risk than the directory it is stored in. The designer agent got confused and designed an attack for the wrong target.'}],
    'summary': 'Auto-discarded: the attack designer agent targeted a different pair or risk type than what was requested. The design cannot be effective for the intended benchmark scenario.'
}
with open('$OUTPUT_DIR/filter_result.json', 'w') as f:
    json.dump(result, f, indent=2)
"
    echo "  Output saved to $OUTPUT_DIR"
    exit 0
fi
if [ "$PREPARE_EXIT" -ne 0 ]; then
    echo "  ERROR: prepare_filter_context.py failed"
    exit 1
fi

touch "$TASK_COPY/environment/Dockerfile"

# --- Load credentials ---
if [ -f "$REPO/.env" ]; then
    set -a
    source "$REPO/.env"
    set +a
fi

# --- Run harbor with retry ---
TASK_REL=$(python3 -c "import os; print(os.path.relpath('$TASK_COPY', '$REPO'))")
HARBOR_ARGS=(-p "$TASK_REL" -a "$AGENT" -m "$MODEL" -y)
MAX_RETRIES=5
ATTEMPT=0
JOB=""
JOB_ROOT=""

while [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    [ "$ATTEMPT" -gt 1 ] && echo "  Retry $ATTEMPT/$MAX_RETRIES..." && sleep 3

    RUN_MARKER=$(date +%s)
    sleep $((RANDOM % 5 + 1))
    harbor run "${HARBOR_ARGS[@]}"
    cd "$REPO"

    # Find the trial dir created by this run
    JOB=""
    for candidate in $(ls -td jobs/*/attack_filter__* 2>/dev/null); do
        JOB_RESULT="$(dirname "$candidate")/result.json"
        if [ -f "$JOB_RESULT" ]; then
            FILE_TIME=$(stat -c %Y "$JOB_RESULT" 2>/dev/null || echo 0)
            if [ "$FILE_TIME" -ge "$RUN_MARKER" ]; then
                JOB="$candidate"
                JOB_ROOT=$(dirname "$candidate")
                break
            fi
        fi
    done

    if [ -z "$JOB" ]; then
        echo "  No job found, retrying..."
        continue
    fi

    # Success: output exists (even if agent timed out after writing it)
    [ -f "$JOB/verifier/output/filter_result.json" ] && break

    # Classify failure from job-level result.json
    FAILURE=$(python3 -c "
import json
d = json.load(open('$JOB_ROOT/result.json'))
for k, v in d.get('stats', {}).get('evals', {}).items():
    if v.get('n_trials', 0) == 0:
        print('build_failed')
        break
    es = v.get('exception_stats', {})
    if es.get('NonZeroAgentExitCodeError') or es.get('AgentTimeoutError'):
        print('agent_error')
        break
else:
    print('no_output')
" 2>/dev/null || echo "unknown")

    case "$FAILURE" in
        build_failed)  echo "  Build/setup failed (0 trials), retrying..."; continue ;;
        agent_error)   echo "  Agent error without output, retrying..."; continue ;;
        *)             echo "  Agent finished but no output produced"; break ;;
    esac
done

# --- Save results ---
if [ -z "$JOB" ]; then
    echo "  No job found after $MAX_RETRIES attempts"
    exit 1
fi

REWARD=$(cat "$JOB/verifier/reward.txt" 2>/dev/null || echo "?")
echo "  Reward: $REWARD"

if [ -f "$JOB/verifier/output/filter_result.json" ]; then
    mkdir -p "$OUTPUT_DIR"
    cp "$JOB/verifier/output/filter_result.json" "$OUTPUT_DIR/"
    cp "$JOB/agent/"*.txt "$OUTPUT_DIR/" 2>/dev/null
    echo "  Output saved to $OUTPUT_DIR"

    python3 -c "
import json
with open('$OUTPUT_DIR/filter_result.json') as f:
    d = json.load(f)
print(f'  Verdict: {d.get(\"verdict\",\"?\")}')
for r in d.get('reasons', []):
    print(f'    [{r.get(\"category\",\"?\")}] {r.get(\"description\",\"\")[:100]}')
" 2>/dev/null
else
    echo "  No filter output found"
fi

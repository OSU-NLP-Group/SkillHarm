#!/bin/bash
# Run task_selection with multiple agents, save each output, then vote.
#
# Usage:
#   bash scripts/run_agents.sh                    # Run all agents
#   bash scripts/run_agents.sh --vote-only        # Just vote on existing outputs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUTDIR="$BASE_DIR/outputs"
mkdir -p "$OUTDIR"

# Load .env for AWS credentials (needed for Claude Code)
if [ -f "$REPO/.env" ]; then
    source "$REPO/.env"
fi

run_agent() {
    local AGENT_ID="$1"
    local HARBOR_AGENT="$2"
    local HARBOR_MODEL="$3"
    shift 3
    local EXTRA_ARGS=("$@")

    if [ -f "$OUTDIR/$AGENT_ID.json" ]; then
        echo "=== SKIP $AGENT_ID (already done) ==="
        return
    fi

    echo "=== Running $AGENT_ID ==="

    # Record timestamp before running so we can find the right job
    local BEFORE_TS=$(date +%s)

    cd "$REPO"
    harbor run -p self-mutating-poisoning/task_selection -a "$HARBOR_AGENT" -m "$HARBOR_MODEL" "${EXTRA_ARGS[@]}"

    cd "$REPO"

    # Find job created after our timestamp
    local JOB=""
    for candidate in $(ls -td jobs/*/task_selection__* 2>/dev/null); do
        local job_dir=$(dirname "$candidate")
        local job_ts=$(basename "$job_dir" | sed 's/__/-/g; s/\([0-9]*\)-\([0-9]*\)-\([0-9]*\)__\([0-9]*\)-\([0-9]*\)-\([0-9]*\)/\1-\2-\3 \4:\5:\6/')
        JOB="$candidate"
        break  # most recent
    done

    if [ -z "$JOB" ]; then
        echo "  FAILED $AGENT_ID (no job found)"
        return
    fi

    # Check for task_pairs.json in verifier output
    if [ -f "$JOB/verifier/task_pairs.json" ]; then
        cp "$JOB/verifier/task_pairs.json" "$OUTDIR/$AGENT_ID.json"
        echo "  Saved $AGENT_ID (from verifier)"
    else
        # Fallback: agent might have created it but test.sh copy failed
        echo "  WARNING: No task_pairs.json in verifier output for $AGENT_ID"
        # Try to find it in agent logs
        local REWARD=$(cat "$JOB/verifier/reward.txt" 2>/dev/null)
        echo "  Reward: ${REWARD:-unknown}"
    fi
}

if [ "$1" = "--vote-only" ]; then
    echo "=== Skipping agent runs, going to vote ==="
else
    # --- Agent 1: Codex gpt-5.2 ---
    run_agent "codex_gpt-5.2" "codex" "openai/gpt-5.2"

    # --- Agent 2: Codex gpt-5.4 ---
    run_agent "codex_gpt-5.4" "codex" "openai/gpt-5.4"

    # --- Agent 3: Claude Code Opus 4.6 ---
    if [ -n "$AWS_ACCESS_KEY_ID" ]; then
        run_agent "claude_opus-4.6" "claude-code" "anthropic/claude-opus-4-6" \
            --ae "CLAUDE_CODE_USE_BEDROCK=1" \
            --ae "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" \
            --ae "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" \
            --ae "AWS_REGION=${AWS_REGION:-us-east-1}" \
            --ae "ANTHROPIC_MODEL=us.anthropic.claude-opus-4-6-v1"
    else
        echo "=== SKIP claude_opus-4.6 (no AWS credentials) ==="
    fi
fi

# --- Vote / Merge ---
echo ""
echo "=== Voting on task pairs ==="
cd "$REPO"
python3 self-mutating-poisoning/attack_target_selection/scripts/vote.py "$OUTDIR"

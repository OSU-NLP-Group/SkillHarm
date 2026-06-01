# Evaluate the opencode victim agent (Qwen3.6-27B via OpenRouter) on the
# poisoned samples that run_all.sh produced. Designed to run side-by-side with
# eval_command_claude.sh / eval_command_codex.sh / eval_command_gemini.sh in a
# separate terminal — each script holds its own slice of the parallel budget.
#
# Usage:
#   bash fixed-payload-poisoning/victim_eval/scripts/eval_command_qwen.sh
#
# Resume-friendly: eval.sh skips samples that already have asr_result.json
# or aborted.json, so re-running this is safe and incremental.
#
# === Prereq: an OpenRouter API key ===
# Get one at https://openrouter.ai/keys. The key is forwarded into every
# victim container via harbor's --extra-env so the in-container opencode
# (LiteLLM-backed) agent can authenticate. Replace the placeholder below
# before first run, or export OPENROUTER_API_KEY in your shell beforehand.

set -e

MODEL="${QWEN_MODEL:-openrouter/qwen/qwen3.6-27b}"

# === OpenRouter auth (host) — forwarded into victim containers ===
export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-sk-or-REPLACE_ME}"

if [ "$OPENROUTER_API_KEY" = "sk-or-REPLACE_ME" ]; then
    echo "ERROR: OPENROUTER_API_KEY is still the placeholder."
    echo "  Edit eval_command_qwen.sh and replace sk-or-REPLACE_ME with a real key,"
    echo "  or export OPENROUTER_API_KEY=sk-or-... before running this script."
    exit 1
fi

# === Eval knobs ===
# 6 concurrent harbor jobs in this session; pair with the other
# eval_command_*.sh scripts in additional terminals to share the budget.
export NL_HARNESS_PARALLEL="${NL_HARNESS_PARALLEL:-6}"

# Optional filters (uncomment to scope the run):
# export NL_TASKS="court-form-filling,citation-check"
# export NL_RISKS="data_exfiltration"
# export NL_GENERATOR="claude_claude-opus-4-7"      # only eval samples from this generator
# export NL_REALIZATIONS="plain_text,executable_code"

echo "=========================================="
echo "  nl_harness: opencode (Qwen via OpenRouter) eval"
echo "  Model:    $MODEL"
echo "  Parallel: $NL_HARNESS_PARALLEL"
echo "=========================================="

# === Run ===
bash fixed-payload-poisoning/victim_eval/scripts/eval.sh opencode "$MODEL"
EVAL_RC=$?

# === Auto-stop is intentionally OFF in this script ===
# Multiple eval_command_*.sh sessions may run in parallel; whichever finishes
# first would stop the EC2 instance and kill the others mid-run. If you want
# to auto-stop after ALL finish, do it manually from another terminal once
# the scripts return, or wire up an external coordinator.
echo ""
echo "eval_command_qwen.sh exited with code $EVAL_RC"

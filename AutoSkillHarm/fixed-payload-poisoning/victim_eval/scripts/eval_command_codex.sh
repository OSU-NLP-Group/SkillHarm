# Evaluate the codex victim agent (gpt-5.4 via Azure OpenAI) on the poisoned
# samples that run_all.sh produced. Designed to run side-by-side with
# eval_command_claude.sh in a separate terminal — each script holds its own
# slice of the parallel budget (default 6 + 6 = 12 concurrent harbor jobs total).
#
# Usage:
#   bash fixed-payload-poisoning/victim_eval/scripts/eval_command_codex.sh
#
# Resume-friendly: eval.sh skips samples that already have asr_result.json
# or aborted.json, so re-running this is safe and incremental.

# === Azure OpenAI (host) — for both the codex agent AND /root/scan.py ===
# Codex agent backend uses OPENAI_API_KEY + OPENAI_BASE_URL; pointing
# OPENAI_BASE_URL at Azure's OpenAI v1 compat endpoint lets the same client
# work for both the agent and the in-container verifier.
# export OPENAI_API_KEY="REDACTED_AZURE_OPENAI_API_KEY"
# export OPENAI_BASE_URL="https://your-azure-resource.openai.azure.com/openai/v1/"  # /openai/v1/ is required: codex --enable unified_exec hits /responses, which Azure only mounts under this prefix

export OPENAI_API_KEY="REDACTED_AZURE_OPENAI_API_KEY"
export OPENAI_BASE_URL="https://your-azure-resource.openai.azure.com/openai/v1/"

# === Eval knobs ===
# 10 concurrent harbor jobs in this session; pair with eval_command_claude.sh
# (also 10) in another session for ~20 total.
export NL_HARNESS_PARALLEL=10

# Optional filters (uncomment to scope the run):
# export NL_TASKS="court-form-filling,citation-check"
# export NL_RISKS="data_exfiltration"
# export NL_GENERATOR="claude_claude-opus-4-7"      # only eval samples from this generator
# export NL_REALIZATIONS="plain_text,executable_code"


# === Run ===
bash fixed-payload-poisoning/victim_eval/scripts/eval.sh codex gpt-5.4
EVAL_RC=$?

# === Auto-stop is intentionally OFF in this script ===
# Two eval_command_*.sh sessions run in parallel; whichever finishes first
# would stop the EC2 instance and kill the other mid-run. If you want to
# auto-stop after BOTH finish, do it manually from a third terminal once
# both scripts return, or wire up an external coordinator.
echo ""
echo "eval_command_codex.sh exited with code $EVAL_RC"

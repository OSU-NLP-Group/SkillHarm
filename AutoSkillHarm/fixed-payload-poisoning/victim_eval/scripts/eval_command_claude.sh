# Evaluate the claude-code victim agent on the poisoned samples that
# run_all.sh produced. Designed to run side-by-side with eval_command_codex.sh
# in a separate terminal — each script holds its own slice of the parallel
# budget (default 6 + 6 = 12 concurrent harbor jobs total).
#
# Usage:
#   bash fixed-payload-poisoning/victim_eval/scripts/eval_command_claude.sh
#
# Resume-friendly: eval.sh skips samples that already have asr_result.json
# or aborted.json, so re-running this is safe and incremental.

# === Bedrock auth (host) — for the claude-code victim agent ===
export AWS_PROFILE='default'
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export CLAUDE_CODE_USE_BEDROCK=1
eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env)"

# === Eval knobs ===
# 10 concurrent harbor jobs in this session; pair with eval_command_codex.sh
# (also 10) in another session for ~20 total.
export NL_HARNESS_PARALLEL=6

# Optional filters (uncomment to scope the run):
# export NL_TASKS="court-form-filling,citation-check"
# export NL_RISKS="data_exfiltration"
# export NL_GENERATOR="claude_claude-opus-4-7"      # only eval samples from this generator
# export NL_REALIZATIONS="plain_text,executable_code"

# === Run ===
bash fixed-payload-poisoning/victim_eval/scripts/eval.sh claude-code us.anthropic.claude-sonnet-4-6
EVAL_RC=$?

# === Auto-stop is intentionally OFF in this script ===
# Two eval_command_*.sh sessions run in parallel; whichever finishes first
# would stop the EC2 instance and kill the other mid-run. If you want to
# auto-stop after BOTH finish, do it manually from a third terminal once
# both scripts return, or wire up an external coordinator.
echo ""
echo "eval_command_claude.sh exited with code $EVAL_RC"

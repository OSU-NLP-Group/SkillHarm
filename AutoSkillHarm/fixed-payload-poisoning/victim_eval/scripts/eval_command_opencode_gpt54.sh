#!/bin/bash
# Evaluate the opencode victim agent driven by GPT-5.4 via DIRECT OpenAI (not
# Azure, not OpenRouter) on the poisoned samples that run_all.sh produced.
# Designed to run side-by-side with the other eval_command_*.sh scripts in
# separate terminals — each script holds its own slice of the parallel budget.
#
# Usage:
#   bash fixed-payload-poisoning/victim_eval/scripts/eval_command_opencode_gpt54.sh
#
# Resume-friendly: eval.sh skips samples that already have asr_result.json
# or aborted.json under evals/opencode_gpt-5.4/<sample_id>/, so re-running
# is safe and incremental.
#
# Output:
#   results/<task>/<slug>/<risk>/outputs/<generator>/
#     evals/opencode_gpt-5.4/<sample_id>/{result.json, reward.txt, cost.json,
#                                          asr_result.json, opencode.txt, ...}
# Aggregate:
#   results/<task>/eval_summary_opencode_gpt-5.4.json
#
# === How opencode + direct-OpenAI works (so you don't have to read the adapter) ===
# The opencode harbor adapter parses the model string as <provider>/<model_id>.
# When provider == "openai" it reads OPENAI_API_KEY (and OPENAI_BASE_URL if
# set) from the *host* environment and forwards them into the agent container
# itself — eval.sh does NOT need to do --agent-env passthrough for the OpenAI
# case (unlike the openrouter case, which eval.sh explicitly forwards).
# Source: harbor/agents/installed/opencode.py, the `elif provider == "openai"`
# branch of the keys[] list.
#
# So: just export OPENAI_API_KEY on the host, call eval.sh with
# MODEL="openai/gpt-5.4", and the adapter handles the rest. To hit Azure
# instead, also export OPENAI_BASE_URL=https://<your-resource>.openai.azure.com/...
# (leave unset for plain api.openai.com).

set -e

# === OpenAI auth (DIRECT, plain OpenAI — NOT Azure) ===
# Replace the placeholder with your real OpenAI key (sk-...). Leave
# OPENAI_BASE_URL unset so the SDK falls back to api.openai.com.
export OPENAI_API_KEY="REDACTED_OPENAI_API_KEY"
export OPENAI_API_KEY="${OPENAI_API_KEY:-REPLACE_ME_WITH_OPENAI_KEY}"
unset OPENAI_BASE_URL

if [ "$OPENAI_API_KEY" = "REPLACE_ME_WITH_OPENAI_KEY" ]; then
    echo "ERROR: OPENAI_API_KEY is still the placeholder."
    echo "  Edit eval_command_opencode_gpt54.sh and set OPENAI_API_KEY to your"
    echo "  real OpenAI key (sk-...), or export OPENAI_API_KEY=sk-... before"
    echo "  running this script."
    exit 1
fi

# Model in <provider>/<model_id> form (LiteLLM-style). "openai/" tells the
# opencode adapter to use the openai provider and forward OPENAI_API_KEY[+
# _BASE_URL]. The VICTIM_ID will become opencode_gpt-5.4 (eval.sh strips the
# provider prefix when constructing the victim_id).
MODEL="${OPENAI_MODEL:-openai/gpt-5.4}"

# === Eval knobs ===
# Conservative default — pair with eval_command_*.sh scripts in other
# terminals to share the box. Override per-run with
#   NL_HARNESS_PARALLEL=10 bash fixed-payload-poisoning/victim_eval/scripts/eval_command_opencode_gpt54.sh
export NL_HARNESS_PARALLEL="${NL_HARNESS_PARALLEL:-10}"

# Kept samples only: skip anything whose filter_result.json verdict isn't
# "keep" (and skip samples that lack a filter_result.json entirely). This
# matches the gating the other agents' "kept" eval runs used so the new
# (task, opencode_gpt-5.4) cells line up with the rest of the result tree.
export NL_KEEP_ONLY="${NL_KEEP_ONLY:-1}"

# Optional filters (uncomment to scope the run):
# export NL_TASKS="court-form-filling,citation-check"
# export NL_RISKS="data_exfiltration"
# export NL_GENERATOR="claude_claude-opus-4-7"      # only eval samples from this generator
# export NL_REALIZATIONS="plain_text,executable_code"

echo "=========================================="
echo "  nl_harness: opencode + direct OpenAI eval"
echo "  Model:      $MODEL"
echo "  Parallel:   $NL_HARNESS_PARALLEL"
echo "  Keep-only:  $NL_KEEP_ONLY"
[ -n "${NL_TASKS:-}" ]        && echo "  NL_TASKS:        $NL_TASKS"
[ -n "${NL_RISKS:-}" ]        && echo "  NL_RISKS:        $NL_RISKS"
[ -n "${NL_GENERATOR:-}" ]    && echo "  NL_GENERATOR:    $NL_GENERATOR"
[ -n "${NL_REALIZATIONS:-}" ] && echo "  NL_REALIZATIONS: $NL_REALIZATIONS"
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
echo "eval_command_opencode_gpt54.sh exited with code $EVAL_RC"

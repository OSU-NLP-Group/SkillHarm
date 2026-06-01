#!/bin/bash
# Defense-prompt eval for opencode + Qwen3.6-27B (OpenRouter), scoped to the
# 687 static_attack_filter "keep" samples. Mirrors eval_command_qwen.sh but
# routes through eval_defense.sh, which patches harbor_run.py to inject
# fixed-payload-poisoning/victim_eval/eval/defenses/defensive_system_prompt.md into ~/.config/opencode/
# AGENTS.md before each victim run.
#
# Usage:
#   OPENROUTER_API_KEY=sk-or-... bash fixed-payload-poisoning/victim_eval/scripts/eval_command_qwen_defense.sh
#
# Output:
#   results/<task>/<slug>/<risk>/outputs/<gen>/
#     evals_defense/defensive_system_prompt/opencode_qwen__qwen3.6-27b/<sid>/
# Aggregate (per-task):
#   results/<task>/eval_defense_summary_defensive_system_prompt__opencode_qwen__qwen3.6-27b.json
#
# Resume-friendly: samples that already have asr_result.json or aborted.json
# under the defense eval dir are skipped on re-run.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(dirname "$SCRIPT_DIR")"
REPO="$(cd "$HARNESS_DIR/.." && pwd)"

MODEL="${QWEN_MODEL:-openrouter/qwen/qwen3.6-27b}"

# === Defense prompt: the real safety-warning system prompt ===
export SKILLHARM_DEFENSE_PROMPT_FILE="$REPO/fixed-payload-poisoning/victim_eval/eval/defenses/defensive_system_prompt.md"

# === Scope: only the 687 filter_result.json verdict=keep samples ===
export NL_KEEP_ONLY=1

# === OpenRouter auth (host) — forwarded into victim containers ===
export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-sk-or-REPLACE_ME}"
if [ "$OPENROUTER_API_KEY" = "sk-or-REPLACE_ME" ]; then
    echo "ERROR: OPENROUTER_API_KEY is still the placeholder."
    echo "  export OPENROUTER_API_KEY=sk-or-... before running this script."
    exit 1
fi

# === Eval knobs ===
# Qwen baseline ran at 6 concurrent containers without trouble; bump if you
# want to share less of the parallel budget with a co-running script.
export NL_HARNESS_PARALLEL="${NL_HARNESS_PARALLEL:-8}"

# Optional filters (uncomment to scope further; leave empty for full 687-set):
# export NL_TASKS="court-form-filling,citation-check"
# export NL_RISKS="data_exfiltration"
# export NL_GENERATOR="claude_claude-opus-4-7"
# export NL_REALIZATIONS="plain_text,executable_code"

echo "=========================================="
echo "  nl_harness: opencode + Qwen DEFENSE eval"
echo "  Defense file: $SKILLHARM_DEFENSE_PROMPT_FILE"
echo "  Model:        $MODEL"
echo "  Scope:        NL_KEEP_ONLY=1 (687 kept samples)"
echo "  Parallel:     $NL_HARNESS_PARALLEL"
echo "=========================================="

cd "$REPO"
bash fixed-payload-poisoning/victim_eval/scripts/eval_defense.sh opencode "$MODEL"
EVAL_RC=$?

echo ""
echo "eval_command_qwen_defense.sh exited with code $EVAL_RC"

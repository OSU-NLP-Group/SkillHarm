#!/bin/bash
# Defense-prompt eval for the codex victim agent (gpt-5.4 via Azure OpenAI),
# scoped to the stratified per-risk top-30% high-ASR subset
#
# Mirrors eval_command_qwen_defense.sh in shape, but:
#   - swaps in codex / gpt-5.4 (Azure OpenAI) instead of opencode / Qwen
#     (OpenRouter)
#   - scopes via NL_SAMPLE_LIST (the stratified TSV) instead of NL_KEEP_ONLY=1,
#     so the defense run is limited to the same 206 samples as the published
#     subset rather than the full 687-keep set
#
# Usage:
#   bash fixed-payload-poisoning/victim_eval/scripts/eval_command_codex_defense.sh
#
# Output:
#   results/<task>/<slug>/<risk>/outputs/<gen>/
#     evals_defense/defensive_system_prompt/codex_gpt-5.4/<sid>/
# Aggregate (per-task):
#   results/<task>/eval_defense_summary_defensive_system_prompt__codex_gpt-5.4.json
#
# Resume-friendly: samples that already have asr_result.json or aborted.json
# under the defense eval dir are skipped on re-run.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(dirname "$SCRIPT_DIR")"
REPO="$(cd "$HARNESS_DIR/.." && pwd)"

MODEL="${CODEX_MODEL:-gpt-5.4}"

# === Defense prompt ===
export SKILLHARM_DEFENSE_PROMPT_FILE="$REPO/fixed-payload-poisoning/victim_eval/eval/defenses/defensive_system_prompt.md"

# === Optional scope: provide your own NL_SAMPLE_LIST (4-col TSV) ===
# Format per line: task<TAB>slug<TAB>risk<TAB>sample_id
# If unset, eval_defense.sh walks the entire results tree.
: "${NL_SAMPLE_LIST:=}"
if [ -n "$NL_SAMPLE_LIST" ]; then
    export NL_SAMPLE_LIST
fi

# Pin the attack generator so we don't pick up any non-Opus 4.7 outputs that
# may have been produced by ablation runs into the same results tree.
export NL_GENERATOR="claude_claude-opus-4-7"

# === Azure OpenAI auth (host) ===
# Codex agent backend uses OPENAI_API_KEY + OPENAI_BASE_URL; pointing
# OPENAI_BASE_URL at Azure's OpenAI v1 compat endpoint lets the same client
# work for both the agent and the in-container verifier. Same credentials
# block as eval_command_codex.sh — kept inline so this wrapper is
# self-contained.
export OPENAI_API_KEY="${OPENAI_API_KEY:-REDACTED_AZURE_OPENAI_API_KEY}"
export OPENAI_BASE_URL="${OPENAI_BASE_URL:-https://your-azure-resource.openai.azure.com/openai/v1/}"

# === Eval knobs ===
# Codex baseline ran at 10 concurrent containers; defense workload is
# similar (just a longer system prompt), so reuse the same default.
export NL_HARNESS_PARALLEL="${NL_HARNESS_PARALLEL:-10}"

echo "=========================================="
echo "  nl_harness: codex + gpt-5.4 DEFENSE eval"
echo "  Defense file: $SKILLHARM_DEFENSE_PROMPT_FILE"
echo "  Model:        $MODEL"
echo "  Scope:        NL_SAMPLE_LIST=$(basename "$NL_SAMPLE_LIST") (n=206)"
echo "  Generator:    $NL_GENERATOR"
echo "  Parallel:     $NL_HARNESS_PARALLEL"
echo "=========================================="

cd "$REPO"
bash fixed-payload-poisoning/victim_eval/scripts/eval_defense.sh codex "$MODEL"
EVAL_RC=$?

echo ""
echo "eval_command_codex_defense.sh exited with code $EVAL_RC"

#!/bin/bash
# Defense-prompt eval for the claude-code victim agent (Sonnet 4.6 via
# Bedrock), scoped to the stratified per-risk top-30% high-ASR subset
#
# Mirrors eval_command_codex_defense.sh in shape, but swaps codex / gpt-5.4
# (Azure OpenAI) for claude-code / sonnet-4-6 (Bedrock).
#
# Usage:
#   bash fixed-payload-poisoning/victim_eval/scripts/eval_command_claude_defense.sh
#
# Output:
#   results/<task>/<slug>/<risk>/outputs/<gen>/
#     evals_defense/defensive_system_prompt/claude_claude-sonnet-4-6/<sid>/
# Aggregate (per-task):
#   results/<task>/eval_defense_summary_defensive_system_prompt__claude_claude-sonnet-4-6.json
#
# Resume-friendly: samples that already have asr_result.json or aborted.json
# under the defense eval dir are skipped on re-run.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(dirname "$SCRIPT_DIR")"
REPO="$(cd "$HARNESS_DIR/.." && pwd)"

MODEL="${CLAUDE_MODEL:-us.anthropic.claude-sonnet-4-6}"

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

# === Bedrock auth (host) — for the claude-code victim agent ===
# Same credentials block as eval_command_claude.sh — kept inline so this
# wrapper is self-contained. Note that eval_defense.sh unsets AWS_PROFILE
# before invoking harbor (see its CLAUDE.md trap), so we export the resolved
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN here via
# `aws configure export-credentials`.
export AWS_PROFILE='default'
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export CLAUDE_CODE_USE_BEDROCK=1
eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env)"

# === Eval knobs ===
# 10 concurrent containers; bump down to 4-6 if Bedrock starts throttling.
export NL_HARNESS_PARALLEL="${NL_HARNESS_PARALLEL:-10}"

echo "=========================================="
echo "  nl_harness: claude-code + Sonnet 4.6 DEFENSE eval"
echo "  Defense file: $SKILLHARM_DEFENSE_PROMPT_FILE"
echo "  Model:        $MODEL"
echo "  Scope:        NL_SAMPLE_LIST=$(basename "$NL_SAMPLE_LIST") (n=206)"
echo "  Generator:    $NL_GENERATOR"
echo "  Parallel:     $NL_HARNESS_PARALLEL"
echo "=========================================="

cd "$REPO"
bash fixed-payload-poisoning/victim_eval/scripts/eval_defense.sh claude-code "$MODEL"
EVAL_RC=$?

echo ""
echo "eval_command_claude_defense.sh exited with code $EVAL_RC"

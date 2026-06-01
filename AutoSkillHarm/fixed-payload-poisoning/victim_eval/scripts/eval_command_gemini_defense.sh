#!/bin/bash
# Defense-prompt eval for the gemini-cli victim agent (Gemini 3 Flash via
# Vertex AI), scoped to the stratified per-risk top-30% high-ASR subset
#
# Mirrors eval_command_codex_defense.sh in shape, but swaps codex / gpt-5.4
# (Azure OpenAI) for gemini-cli / gemini-3-flash-preview (Vertex AI). The
# Vertex ADC bootstrap block is copied verbatim from eval_command_gemini.sh
# — see that script's header for the one-time `gcloud auth application-
# default login` setup and quota_project_id rationale.
#
# Usage:
#   bash fixed-payload-poisoning/victim_eval/scripts/eval_command_gemini_defense.sh
#
# Output:
#   results/<task>/<slug>/<risk>/outputs/<gen>/
#     evals_defense/defensive_system_prompt/gemini-cli_gemini-3-flash-preview/<sid>/
# Aggregate (per-task):
#   results/<task>/eval_defense_summary_defensive_system_prompt__gemini-cli_gemini-3-flash-preview.json
#
# Resume-friendly: samples that already have asr_result.json or aborted.json
# under the defense eval dir are skipped on re-run.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(dirname "$SCRIPT_DIR")"
REPO="$(cd "$HARNESS_DIR/.." && pwd)"

PROJECT_ID="${GCP_PROJECT_ID:-osu-prd-osunlp101-dd72}"
# Gemini 3 preview models are only published in `global` for this project.
LOCATION="${GCP_LOCATION:-global}"
MODEL="${GEMINI_MODEL:-google/gemini-3-flash-preview}"

# === Defense prompt ===
export SKILLHARM_DEFENSE_PROMPT_FILE="$REPO/fixed-payload-poisoning/victim_eval/eval/defenses/defensive_system_prompt.md"

# === Optional scope: provide your own NL_SAMPLE_LIST (4-col TSV) ===
# Format per line: task<TAB>slug<TAB>risk<TAB>sample_id
# If unset, eval_defense.sh walks the entire results tree.
: "${NL_SAMPLE_LIST:=}"
if [ -n "$NL_SAMPLE_LIST" ]; then
    export NL_SAMPLE_LIST
fi
export NL_GENERATOR="claude_claude-opus-4-7"

# === Locate + sanity-stamp the host ADC file (copied from eval_command_gemini.sh) ===
ADC_HOST="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}"
if [ ! -f "$ADC_HOST" ]; then
    echo "ERROR: ADC credentials not found at $ADC_HOST"
    echo "Run: gcloud auth application-default login"
    echo "Then: gcloud auth application-default set-quota-project $PROJECT_ID"
    exit 1
fi
read_quota() {
    python3 -c "
import json, sys
try:
    print(json.load(open('$ADC_HOST')).get('quota_project_id', ''))
except Exception:
    pass
"
}
QUOTA=$(read_quota || true)
if [ "$QUOTA" != "$PROJECT_ID" ]; then
    if [ -z "$QUOTA" ]; then
        echo "ADC has no quota_project_id; stamping $PROJECT_ID into $ADC_HOST"
    else
        echo "ADC quota_project_id=$QUOTA != $PROJECT_ID; rewriting to $PROJECT_ID"
    fi
    python3 - "$ADC_HOST" "$PROJECT_ID" <<'PY'
import json, sys
path, project = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
d["quota_project_id"] = project
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PY
    QUOTA=$(read_quota || true)
    if [ "$QUOTA" != "$PROJECT_ID" ]; then
        echo "ERROR: failed to stamp quota_project_id=$PROJECT_ID into $ADC_HOST"
        exit 1
    fi
fi

# === In-container ADC mount + Vertex auth env (copied from eval_command_gemini.sh) ===
ADC_CONTAINER="/root/gcloud-adc.json"
export NL_HARNESS_MOUNTS_JSON="[{\"type\":\"bind\",\"source\":\"$ADC_HOST\",\"target\":\"$ADC_CONTAINER\",\"read_only\":true}]"
export GOOGLE_GENAI_USE_VERTEXAI=true
export GOOGLE_CLOUD_PROJECT="$PROJECT_ID"
export GOOGLE_CLOUD_LOCATION="$LOCATION"
export GOOGLE_APPLICATION_CREDENTIALS="$ADC_CONTAINER"
unset GEMINI_API_KEY GOOGLE_API_KEY

# === Eval knobs ===
# 10 concurrent containers; bump down to 4-6 if Vertex starts throttling.
export NL_HARNESS_PARALLEL="${NL_HARNESS_PARALLEL:-10}"

echo "=========================================="
echo "  nl_harness: gemini-cli + Gemini 3 Flash DEFENSE eval"
echo "  Defense file: $SKILLHARM_DEFENSE_PROMPT_FILE"
echo "  Model:        $MODEL"
echo "  Project:      $PROJECT_ID  ($LOCATION)"
echo "  Scope:        ${NL_SAMPLE_LIST:-<all results>}"
echo "  Generator:    $NL_GENERATOR"
echo "  Parallel:     $NL_HARNESS_PARALLEL"
echo "=========================================="

cd "$REPO"
bash fixed-payload-poisoning/victim_eval/scripts/eval_defense.sh gemini-cli "$MODEL"
EVAL_RC=$?

echo ""
echo "eval_command_gemini_defense.sh exited with code $EVAL_RC"

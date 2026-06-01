# Evaluate the gemini-cli victim agent (Gemini 3 Flash via Vertex AI) on the
# poisoned samples that run_all.sh produced. Designed to run side-by-side with
# eval_command_claude.sh / eval_command_codex.sh in a separate terminal — each
# script holds its own slice of the parallel budget.
#
# Usage:
#   bash fixed-payload-poisoning/victim_eval/scripts/eval_command_gemini.sh
#
# Resume-friendly: eval.sh skips samples that already have asr_result.json
# or aborted.json, so re-running this is safe and incremental.
#
# === Prereq: ADC bootstrap on host (do this ONCE per shell user) ===
#   gcloud auth application-default login
#   gcloud auth application-default set-quota-project osu-prd-osunlp101-dd72
#
# The first command writes ~/.config/gcloud/application_default_credentials.json
# (an `authorized_user` ADC file with a refresh token). The second stamps the
# quota_project_id field into that file so per-call billing routes to the
# project we have Vertex AI quota in — without it we get the same 403 the
# user's Python snippet documents.
#
# We bind-mount that file into the victim container at /root/gcloud-adc.json
# (read-only) and point GOOGLE_APPLICATION_CREDENTIALS at it. Combined with
# GOOGLE_GENAI_USE_VERTEXAI=true and GOOGLE_CLOUD_PROJECT/LOCATION, gemini-cli
# routes through Vertex AI instead of the public Gemini API. Harbor forwards
# all six GOOGLE_*/GEMINI_* env vars listed in
# harbor/agents/installed/gemini_cli.py:auth_vars into the container.

set -e

PROJECT_ID="${GCP_PROJECT_ID:-osu-prd-osunlp101-dd72}"
# Gemini 3 preview models are only published in the `global` Vertex region for
# this project (verified 2026-05-06 via direct generateContent probe across
# us-central1 / us-east4 / us-east5 / europe-west4 / global — only `global`
# returned 200 OK for gemini-3-flash-preview). 2.5-series still works in
# us-central1 if you fall back to it.
LOCATION="${GCP_LOCATION:-global}"
MODEL="${GEMINI_MODEL:-google/gemini-3-flash-preview}"

# === Locate the host ADC file ===
ADC_HOST="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}"
if [ ! -f "$ADC_HOST" ]; then
    echo "ERROR: ADC credentials not found at $ADC_HOST"
    echo "Run: gcloud auth application-default login"
    echo "Then: gcloud auth application-default set-quota-project $PROJECT_ID"
    exit 1
fi

# Sanity-check the quota project — if missing or wrong, Vertex 403s even with
# valid creds. We stamp it directly into the ADC JSON file rather than via
# `gcloud auth application-default set-quota-project`, because that command
# pre-flights `serviceusage.services.use` on the project and fails for users
# who only have aiplatform.user (a common OSU IAM split). The runtime API
# path doesn't check serviceusage; it only reads quota_project_id from the
# ADC file, so a direct JSON edit works wherever the user's Python
# google.auth.default(quota_project_id=...) works.
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

# === In-container path + harbor mount ===
# Mount ADC read-only at a fixed absolute path that does NOT depend on the
# container's $HOME or which user the agent runs as. Most SkillsBench task
# Dockerfiles run as root with WORKDIR /root, so /root/gcloud-adc.json is
# both reachable and conventional.
ADC_CONTAINER="/root/gcloud-adc.json"
export NL_HARNESS_MOUNTS_JSON="[{\"type\":\"bind\",\"source\":\"$ADC_HOST\",\"target\":\"$ADC_CONTAINER\",\"read_only\":true}]"

# === Vertex AI auth (forwarded by harbor's gemini-cli agent into the container) ===
export GOOGLE_GENAI_USE_VERTEXAI=true
export GOOGLE_CLOUD_PROJECT="$PROJECT_ID"
export GOOGLE_CLOUD_LOCATION="$LOCATION"
export GOOGLE_APPLICATION_CREDENTIALS="$ADC_CONTAINER"

# Make sure no stale Gemini API key sneaks in — if either of these is set the
# Google GenAI SDK prefers the API key path over Vertex regardless of
# GOOGLE_GENAI_USE_VERTEXAI.
unset GEMINI_API_KEY GOOGLE_API_KEY

# === Eval knobs ===
# 6 concurrent harbor jobs in this session; pair with eval_command_claude.sh
# and/or eval_command_codex.sh in other terminals to share the budget.
export NL_HARNESS_PARALLEL="${NL_HARNESS_PARALLEL:-6}"

# Optional: gemini-3-flash supports reasoning_effort in {minimal, low, medium,
# high}. Leave unset for the model's default; eval.sh forwards it as
# `--ak reasoning_effort=...` only when set.
# export GEMINI_REASONING_EFFORT=medium

# Optional filters (uncomment to scope the run):
# export NL_TASKS="court-form-filling,citation-check"
# export NL_RISKS="data_exfiltration"
# export NL_GENERATOR="claude_claude-opus-4-7"      # only eval samples from this generator
# export NL_REALIZATIONS="plain_text,executable_code"

echo "=========================================="
echo "  nl_harness: gemini-cli eval"
echo "  Model:        $MODEL"
echo "  Project:      $PROJECT_ID  ($LOCATION)"
echo "  ADC host:     $ADC_HOST"
echo "  ADC container: $ADC_CONTAINER  (bind-mounted read-only)"
echo "  Parallel:     $NL_HARNESS_PARALLEL"
[ -n "${GEMINI_REASONING_EFFORT:-}" ] && echo "  Reasoning:    $GEMINI_REASONING_EFFORT"
echo "=========================================="

# === Run ===
bash fixed-payload-poisoning/victim_eval/scripts/eval.sh gemini-cli "$MODEL"
EVAL_RC=$?

# === Auto-stop is intentionally OFF in this script ===
# Two/three eval_command_*.sh sessions may run in parallel; whichever finishes
# first would stop the EC2 instance and kill the others mid-run. If you want
# to auto-stop after ALL finish, do it manually from another terminal once
# the scripts return, or wire up an external coordinator.
echo ""
echo "eval_command_gemini.sh exited with code $EVAL_RC"

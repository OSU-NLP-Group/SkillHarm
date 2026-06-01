#!/bin/bash
# Defense-prompt eval for the dynamic pipeline using the gemini-cli victim
# agent (Gemini 3 Flash via Vertex AI).
#
# Mirrors eval_filtered_gemini.sh in shape (ADC bootstrap + Vertex env +
# canonical-data sync), but delegates to eval_defense.sh instead of
# eval_filtered.sh. The defense prompt file is taken from
# SKILLHARM_DEFENSE_PROMPT_FILE (defaults to the standard
# defensive_system_prompt.md), and is preserved across the exec into
# eval_defense.sh.
#
# Usage:
#   export SKILLHARM_DEFENSE_PROMPT_FILE=$PWD/self-mutating-poisoning/victim_eval/eval_defense/defenses/defensive_system_prompt.md
#   bash self-mutating-poisoning/victim_eval/scripts/eval_defense_gemini.sh --parallel 2
#
# By default this restricts evaluation to the per-risk top-30%-ASR subset at
# $REPO/top30_per_risk_subset.json (51 (pair, risk, designer) triples). Override
# with SKILLHARM_SUBSET_FILE=<path> to point at a different subset, or set
# SKILLHARM_SUBSET_FILE= (empty) / pass --subset-file "" to evaluate the full
# filter-kept set instead.
#
# All extra args are forwarded to eval_defense.sh. Supported flags there:
#   --parallel N            run N evals concurrently (default 1)
#   --dry-run               list what would be evaluated
#   --design-agent ID       only evaluate designs from this designer
#   --all                   include all successful designs (not just filter-kept)
#   --agent-version V       pin gemini-cli version
#   --subset-file PATH      restrict to (pair, risk, designer) triples in PATH
#                           (already auto-injected when the default subset exists)
#
# Optional env knobs (same as eval_filtered_gemini.sh):
#   GCP_PROJECT_ID            (default: osu-prd-osunlp101-dd72)
#   GCP_LOCATION              (default: global — only region where
#                              gemini-3-flash-preview is published)
#   GEMINI_MODEL              (default: google/gemini-3-flash-preview)
#   GEMINI_REASONING_EFFORT   (one of: minimal, low, medium, high)
#   GEMINI_ADC_CONTAINER      (in-container ADC path; default: /root/gcloud-adc.json)
#
# Prereq (one-time per shell user):
#   gcloud auth application-default login
#
# This script auto-stamps quota_project_id into the ADC JSON if it's missing
# or wrong (we edit the file directly rather than calling
# `gcloud auth application-default set-quota-project`, which pre-flights
# serviceusage.services.use and 403s for users who only have aiplatform.user).

set -e

PROJECT_ID="${GCP_PROJECT_ID:-osu-prd-osunlp101-dd72}"
LOCATION="${GCP_LOCATION:-global}"
MODEL="${GEMINI_MODEL:-google/gemini-3-flash-preview}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATTACK_DIR="$(dirname "$SCRIPT_DIR")"
SETTING_DIR="$(dirname "$ATTACK_DIR")"
REPO="$(cd "$SETTING_DIR/.." && pwd)"

# === Defense prompt ===
# Honor caller's SKILLHARM_DEFENSE_PROMPT_FILE; default to the standard
# defensive_system_prompt.md in this repo if unset. Resolve to absolute so the
# exec'd eval_defense.sh sees the same path no matter where it gets `cd`-ed.
SKILLHARM_DEFENSE_PROMPT_FILE="${SKILLHARM_DEFENSE_PROMPT_FILE:-$ATTACK_DIR/eval_defense/defenses/defensive_system_prompt.md}"
if [ ! -f "$SKILLHARM_DEFENSE_PROMPT_FILE" ]; then
    echo "ERROR: defense prompt file not found: $SKILLHARM_DEFENSE_PROMPT_FILE"
    exit 1
fi
SKILLHARM_DEFENSE_PROMPT_FILE=$(python3 -c "import os, sys; print(os.path.abspath(sys.argv[1]))" "$SKILLHARM_DEFENSE_PROMPT_FILE")
export SKILLHARM_DEFENSE_PROMPT_FILE

# === Locate + sanity-stamp the host ADC file ===
ADC_HOST="${GOOGLE_APPLICATION_CREDENTIALS_HOST:-${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}}"
if [ ! -f "$ADC_HOST" ]; then
    ADC_HOST="$HOME/.config/gcloud/application_default_credentials.json"
fi
if [ ! -f "$ADC_HOST" ]; then
    echo "ERROR: ADC credentials not found at $ADC_HOST"
    echo "Run: gcloud auth application-default login"
    exit 1
fi

read_quota() {
    python3 -c "
import json
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

# === In-container ADC mount + Vertex auth env ===
ADC_CONTAINER="${GEMINI_ADC_CONTAINER:-/root/gcloud-adc.json}"
export GOOGLE_GENAI_USE_VERTEXAI=true
export GOOGLE_CLOUD_PROJECT="$PROJECT_ID"
export GOOGLE_CLOUD_LOCATION="$LOCATION"
export GOOGLE_APPLICATION_CREDENTIALS="$ADC_CONTAINER"

# Bind-mount hint consumed by test_attack.sh / test_attack_defense.sh — they
# append --mounts-json so the host ADC file is mounted read-only at the
# in-container path.
export GEMINI_ADC_HOST="$ADC_HOST"
export GEMINI_ADC_CONTAINER="$ADC_CONTAINER"

# Optional reasoning effort. test_attack*.sh forwards as --ak reasoning_effort=...
[ -n "${GEMINI_REASONING_EFFORT:-}" ] && export GEMINI_REASONING_EFFORT

# Drop any stale Gemini API keys — if either is set the Google GenAI SDK
# prefers the API-key path over Vertex regardless of GOOGLE_GENAI_USE_VERTEXAI.
unset GEMINI_API_KEY GOOGLE_API_KEY

# Satisfy harbor's pre-flight env existence check for tasks that declare
# OPENAI_API_KEY / AZURE_OPENAI_* in [environment.env]. See eval_filtered_gemini.sh
# for the longer rationale — none of the task code actually reads these.
for v in OPENAI_API_KEY AZURE_OPENAI_API_KEY AZURE_OPENAI_ENDPOINT AZURE_OPENAI_API_VERSION; do
    if [ -z "${!v}" ]; then
        export "$v=dummy-not-used-by-task-code"
    fi
done

# Sync canonical task data files (*.pdf, *.xlsx, *.csv, *.pptx, *.docx) into
# pair task_a/task_b environment dirs. They live in tasks/<name>/environment/
# but are git-ignored under task_pairs/*/task_{a,b}/environment/ (see
# .gitignore: "already in tasks/ directory, copied here for Docker"). Without
# this step the Task A/B Docker build fails on a fresh checkout. Idempotent.
python3 - "$REPO" <<'PY'
import shutil, sys
from pathlib import Path
repo = Path(sys.argv[1])
pairs, tasks = repo / "self-mutating-poisoning/task_pairs", repo / "tasks"
copied = 0
for pair_dir in sorted(pairs.iterdir()) if pairs.is_dir() else []:
    if not pair_dir.is_dir() or "__" not in pair_dir.name:
        continue
    task_a, task_b = pair_dir.name.split("__", 1)
    for role, name in (("task_a", task_a), ("task_b", task_b)):
        canon = tasks / name / "environment"
        if not canon.is_dir():
            continue
        dest = pair_dir / role / "environment"
        dest.mkdir(parents=True, exist_ok=True)
        for src in canon.iterdir():
            if src.is_dir() or src.name in ("Dockerfile", "skills"):
                continue
            dst = dest / src.name
            if not dst.exists():
                shutil.copy2(src, dst)
                copied += 1
if copied:
    print(f"  Synced {copied} canonical data files into pair env dirs")
PY

DEFENSE_SLUG=$(basename "$SKILLHARM_DEFENSE_PROMPT_FILE")
DEFENSE_SLUG="${DEFENSE_SLUG%.md}"

# === Default to the per-risk top-30%-ASR subset ===
# eval_defense.sh accepts --subset-file PATH to filter the keep-set down to a
# specific list of (pair, risk_type, design_agent_id) triples. If the caller
# hasn't passed --subset-file explicitly, default to top30_per_risk_subset.json
# at the repo root. Skip the auto-injection entirely when:
#   - the caller passed --subset-file (any value, including empty) in $@
#   - SKILLHARM_SUBSET_FILE is explicitly set to empty (opt-out)
#   - the default file doesn't exist on disk
USER_PASSED_SUBSET=0
for arg in "$@"; do
    if [ "$arg" = "--subset-file" ]; then
        USER_PASSED_SUBSET=1
        break
    fi
done

DEFAULT_SUBSET="$REPO/top30_per_risk_subset.json"
if [ "${SKILLHARM_SUBSET_FILE+set}" = "set" ]; then
    SUBSET_FILE="$SKILLHARM_SUBSET_FILE"
else
    SUBSET_FILE="$DEFAULT_SUBSET"
fi
SUBSET_DISPLAY="(none — full keep-set)"
SUBSET_ARGS=()
if [ "$USER_PASSED_SUBSET" -eq 0 ] && [ -n "$SUBSET_FILE" ] && [ -f "$SUBSET_FILE" ]; then
    SUBSET_FILE=$(python3 -c "import os, sys; print(os.path.abspath(sys.argv[1]))" "$SUBSET_FILE")
    SUBSET_ARGS=(--subset-file "$SUBSET_FILE")
    SUBSET_DISPLAY="$SUBSET_FILE"
elif [ "$USER_PASSED_SUBSET" -eq 1 ]; then
    SUBSET_DISPLAY="(forwarded from caller args)"
fi

echo "=========================================="
echo "  dynamic eval_defense: gemini-cli + Gemini 3 Flash"
echo "  Defense file:  $SKILLHARM_DEFENSE_PROMPT_FILE"
echo "  Defense slug:  $DEFENSE_SLUG"
echo "  Subset:        $SUBSET_DISPLAY"
echo "  Model:         $MODEL"
echo "  Project:       $PROJECT_ID ($LOCATION)"
echo "  ADC host:      $ADC_HOST"
echo "  ADC container: $ADC_CONTAINER (bind-mounted read-only)"
[ -n "${GEMINI_REASONING_EFFORT:-}" ] && echo "  Reasoning:     $GEMINI_REASONING_EFFORT"
echo "=========================================="
echo ""

exec bash "$SCRIPT_DIR/eval_defense.sh" gemini-cli "$MODEL" "${SUBSET_ARGS[@]}" "$@"

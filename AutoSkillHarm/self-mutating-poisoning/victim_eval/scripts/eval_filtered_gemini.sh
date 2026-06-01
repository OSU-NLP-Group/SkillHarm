#!/bin/bash
# Evaluate filter=keep attack designs using gemini-cli + Gemini 3 Flash via
# Vertex AI. Wraps eval_filtered.sh after preparing ADC credentials and the
# Vertex env vars that harbor's gemini_cli agent forwards into the container.
#
# Usage:
#   bash eval_filtered_gemini.sh [--parallel N] [--dry-run] [--agent-version VER]
#
# Optional env knobs:
#   GCP_PROJECT_ID            (default: osu-prd-osunlp101-dd72)
#   GCP_LOCATION              (default: global — only region where
#                              gemini-3-flash-preview is published, verified
#                              2026-05-06 in eval_command_gemini.sh)
#   GEMINI_MODEL              (default: google/gemini-3-flash-preview)
#   GEMINI_REASONING_EFFORT   (one of: minimal, low, medium, high)
#   GEMINI_ADC_CONTAINER      (in-container ADC path; default: /root/gcloud-adc.json)
#
# === Prereq: ADC bootstrap on host (do this ONCE per shell user) ===
#   gcloud auth application-default login
#
# This script auto-stamps quota_project_id into the ADC JSON if it's missing
# or wrong (we edit the file directly rather than calling
# `gcloud auth application-default set-quota-project`, which pre-flights
# serviceusage.services.use and 403s for users who only have aiplatform.user).
#
# The wrapper:
#   1. Verifies/stamps ADC.
#   2. Exports GOOGLE_GENAI_USE_VERTEXAI / GOOGLE_CLOUD_PROJECT /
#      GOOGLE_CLOUD_LOCATION / GOOGLE_APPLICATION_CREDENTIALS (in-container path)
#      so harbor's gemini_cli.py forwards them into the agent's container env.
#   3. Exports GEMINI_ADC_HOST / GEMINI_ADC_CONTAINER for test_attack.sh, which
#      adds `--mounts-json` to harbor so the ADC file is bind-mounted read-only
#      at the in-container path.
#   4. Delegates to eval_filtered.sh gemini-cli <model> "$@".

set -e

PROJECT_ID="${GCP_PROJECT_ID:-osu-prd-osunlp101-dd72}"
LOCATION="${GCP_LOCATION:-global}"
MODEL="${GEMINI_MODEL:-google/gemini-3-flash-preview}"

# Locate host ADC file. Honor an explicit host path if the caller already set
# GOOGLE_APPLICATION_CREDENTIALS to point at one; otherwise fall back to the
# default gcloud ADC location.
ADC_HOST="${GOOGLE_APPLICATION_CREDENTIALS_HOST:-${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}}"

# If the user set GOOGLE_APPLICATION_CREDENTIALS to a container path (e.g.
# /root/gcloud-adc.json from a previous session), that won't exist on the host
# — fall back to the default in that case.
if [ ! -f "$ADC_HOST" ]; then
    ADC_HOST="$HOME/.config/gcloud/application_default_credentials.json"
fi

if [ ! -f "$ADC_HOST" ]; then
    echo "ERROR: ADC credentials not found at $ADC_HOST"
    echo "Run: gcloud auth application-default login"
    exit 1
fi

# Stamp quota_project_id into ADC JSON if missing/wrong. Vertex 403s without it
# even when the creds are valid.
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

# In-container ADC path. /root is conventional for SkillsBench Dockerfiles
# which run as root with WORKDIR /root.
ADC_CONTAINER="${GEMINI_ADC_CONTAINER:-/root/gcloud-adc.json}"

# Vertex AI auth env. harbor's gemini_cli agent reads these from os.environ on
# the host and forwards them into the agent's container session.
export GOOGLE_GENAI_USE_VERTEXAI=true
export GOOGLE_CLOUD_PROJECT="$PROJECT_ID"
export GOOGLE_CLOUD_LOCATION="$LOCATION"
export GOOGLE_APPLICATION_CREDENTIALS="$ADC_CONTAINER"

# Bind-mount hint consumed by test_attack.sh — it appends --mounts-json so
# the host ADC file is mounted read-only at the in-container path.
export GEMINI_ADC_HOST="$ADC_HOST"
export GEMINI_ADC_CONTAINER="$ADC_CONTAINER"

# Optional reasoning effort. test_attack.sh forwards as --ak reasoning_effort=...
[ -n "${GEMINI_REASONING_EFFORT:-}" ] && export GEMINI_REASONING_EFFORT

# Drop any stale Gemini API keys — if either is set the Google GenAI SDK
# prefers the API-key path over Vertex regardless of GOOGLE_GENAI_USE_VERTEXAI.
unset GEMINI_API_KEY GOOGLE_API_KEY

# Task containers declare OPENAI_API_KEY / AZURE_OPENAI_* in their [environment.env]
# but no task code (skills, Dockerfile, tests, solution, shared_skills, modified_skills)
# actually references them — they were blanket-added when the dynamic framework was
# scaffolded (commit e9f4f1b5) and the canonical tasks/ versions declare zero env vars.
# Harbor's pre-flight only checks existence in os.environ (cli/jobs.py:114), not value,
# so a dummy is enough to satisfy the check while keeping gemini-cli's Vertex auth
# completely independent. If the caller already has real keys, we don't touch them.
for v in OPENAI_API_KEY AZURE_OPENAI_API_KEY AZURE_OPENAI_ENDPOINT AZURE_OPENAI_API_VERSION; do
    if [ -z "${!v}" ]; then
        export "$v=dummy-not-used-by-task-code"
    fi
done

# Sync canonical task data files (*.pdf, *.xlsx, *.csv, *.pptx, *.docx) into the
# pair task_a/task_b environment dirs. They live in tasks/<name>/environment/ but
# are git-ignored under task_pairs/*/task_{a,b}/environment/ (see
# .gitignore: "already in tasks/ directory, copied here for Docker"). Without
# this step the Task A/B Docker build fails with "COPY background.pdf: not found"
# on a fresh checkout. Idempotent — only copies files missing in the pair env.
SCRIPT_DIR_SYNC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SYNC="$(cd "$SCRIPT_DIR_SYNC/../../.." && pwd)"
python3 - "$REPO_SYNC" <<'PY'
import shutil, sys
from pathlib import Path
repo = Path(sys.argv[1])
pairs, tasks = repo / "self-mutating-poisoning/task_pairs", repo / "tasks"
copied_files = copied_skills = 0
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
        # skills/ — git-tracked for most pairs, but pdf-excel-diff as task_a
        # was missed at framework scaffolding time. Docker COPY fails fast on
        # a missing skills/ — sync from canonical so the build context is
        # complete on a fresh checkout.
        if (canon / "skills").is_dir() and not (dest / "skills").is_dir():
            shutil.copytree(canon / "skills", dest / "skills")
            copied_skills += 1
        # Data files (*.pdf, *.xlsx, *.csv, *.pptx, *.docx) — git-ignored
        # under task_pairs/ per .gitignore.
        for src in canon.iterdir():
            if src.is_dir() or src.name == "Dockerfile":
                continue
            dst = dest / src.name
            if not dst.exists():
                shutil.copy2(src, dst)
                copied_files += 1
if copied_skills or copied_files:
    print(f"  Synced {copied_skills} skills/ dirs + {copied_files} data files into pair envs")
PY

echo "=========================================="
echo "  dynamic eval: gemini-cli runner"
echo "  Model:         $MODEL"
echo "  Project:       $PROJECT_ID ($LOCATION)"
echo "  ADC host:      $ADC_HOST"
echo "  ADC container: $ADC_CONTAINER (bind-mounted read-only)"
[ -n "${GEMINI_REASONING_EFFORT:-}" ] && echo "  Reasoning:     $GEMINI_REASONING_EFFORT"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/eval_filtered.sh" gemini-cli "$MODEL" "$@"

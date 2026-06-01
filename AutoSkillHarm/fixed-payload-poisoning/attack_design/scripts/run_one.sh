#!/bin/bash
# Run the nl_harness attack-design task for one (task_id, risk_id, injection_target) combo.
# Uses an isolated temp copy of the task so multiple runs can execute in parallel
# without stepping on each other.
#
# The canonical task directory `skillsbench/tasks/<task_id>/` is copied into the
# temp work-dir's `environment/task/` at run time — so adding a new task to the
# benchmark requires nothing more than a `targets/<task_id>.json` file.
#
# Usage:
#   bash run_one.sh <task_id> <risk_id> <injection_target_path> [agent] [model]
#
# Example:
#   bash run_one.sh citation-check data_exfiltration \
#       environment/skills/citation-management/SKILL.md \
#       claude-code us.anthropic.claude-opus-4-6-v1
#
# Results land in: <NL_RESULTS_DIR>/<task_id>/<target_slug>/<risk_id>/outputs/<agent_id>/
# (default NL_RESULTS_DIR is fixed-payload-poisoning/results, relative to skillsbench/)

set -e

TASK_ID="${1:?Usage: run_one.sh <task_id> <risk_id> <injection_target_path> [agent] [model]}"
RISK="${2:?Usage: run_one.sh <task_id> <risk_id> <injection_target_path> [agent] [model]}"
TARGET="${3:?Usage: run_one.sh <task_id> <risk_id> <injection_target_path> [agent] [model]}"
AGENT="${4:-claude-code}"
MODEL="${5:-us.anthropic.claude-opus-4-6-v1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(dirname "$SCRIPT_DIR")"
REPO="$(cd "$HARNESS_DIR/.." && pwd)"

# Results tree. Env var is a path relative to skillsbench/; absolute paths
# rejected so the same command works regardless of cwd. When called from
# run_all.sh, NL_RESULTS_DIR flows in via the env so both scripts agree.
RESULTS_DIR_REL="${NL_RESULTS_DIR:-fixed-payload-poisoning/results}"
if [[ "$RESULTS_DIR_REL" = /* ]]; then
    echo "ERROR: NL_RESULTS_DIR must be relative to skillsbench/, got absolute path: $RESULTS_DIR_REL"
    exit 1
fi
RESULTS_DIR="$REPO/$RESULTS_DIR_REL"
CANONICAL_TASK="$REPO/tasks/$TASK_ID"

# --- Verify the canonical task exists ---
if [ ! -d "$CANONICAL_TASK" ]; then
    echo "ERROR: canonical task not found: $CANONICAL_TASK"
    echo "       (expected a directory under \$REPO/tasks/ matching task_id='$TASK_ID')"
    exit 1
fi
if [ ! -f "$CANONICAL_TASK/task.toml" ] || [ ! -f "$CANONICAL_TASK/instruction.md" ]; then
    echo "ERROR: $CANONICAL_TASK does not look like a SkillsBench task (missing task.toml or instruction.md)"
    exit 1
fi

# --- Normalize model string to an agent id for output naming ---
MODEL_SHORT=$(echo "$MODEL" | sed 's|.*/||; s|^us\.anthropic\.||; s|^anthropic\.||; s|-v[0-9:]*$||')
if [ "$AGENT" = "claude-code" ]; then
    AGENT_ID="claude_${MODEL_SHORT}"
else
    AGENT_ID="${AGENT}_${MODEL_SHORT}"
fi

# Derive a filesystem-safe slug from the task-relative target path. Matches the
# sample_id slug convention in instruction.md.
TARGET_SLUG=$(echo "$TARGET" | sed 's|/|--|g; s|\.|_|g' | tr '[:upper:]' '[:lower:]')

OUTPUT_DIR="$RESULTS_DIR/$TASK_ID/$TARGET_SLUG/$RISK/outputs/$AGENT_ID"
if [ -f "$OUTPUT_DIR/manifest.json" ] || [ -f "$OUTPUT_DIR/aborted.json" ]; then
    echo "=== SKIP [$TASK_ID / $TARGET_SLUG / $RISK] $AGENT_ID (already done) ==="
    exit 0
fi

echo "=== [$TASK_ID / $TARGET_SLUG / $RISK] $AGENT_ID ==="

# --- Create isolated task copy ---
# $TASK_COPY/ is a self-contained nl_harness task directory whose `environment/task/`
# is the canonical task we're attacking. Each run gets its own copy so that
# environment/selection.json + environment/task/ can vary per-combo without races.
WORK_DIR=$(mktemp -d "/tmp/nl_harness_${TASK_ID}_${RISK}_XXXXXX")
trap "rm -rf '$WORK_DIR'" EXIT
TASK_COPY="$WORK_DIR/nl_harness"
mkdir -p "$TASK_COPY/environment"

# Static harness files (instruction, task.toml, tests, solution).
cp "$HARNESS_DIR/instruction.md" "$TASK_COPY/"
cp "$HARNESS_DIR/task.toml"      "$TASK_COPY/"
cp -r "$HARNESS_DIR/tests"       "$TASK_COPY/"
cp -r "$HARNESS_DIR/solution"    "$TASK_COPY/"

# Harness environment files — Dockerfile + scanner + risk taxonomy. NOT the
# bundled task/ (we drop the canonical one in below) and NOT selection.json
# (we generate it per-combo below).
cp "$HARNESS_DIR/environment/Dockerfile"         "$TASK_COPY/environment/"
cp "$HARNESS_DIR/environment/scan.py"            "$TASK_COPY/environment/"
cp "$HARNESS_DIR/environment/scan_skill_gpt.py"  "$TASK_COPY/environment/"
# risk_taxonomy.json is the canonical AutoSkillHarm taxonomy (setting-level
# config, not per-task). The Dockerfile expects it under environment/ as the
# build-context root, so stage it there per-run.
cp "$HARNESS_DIR/../../risk_taxonomy.json"       "$TASK_COPY/environment/"

# Canonical runtime glue (exec_entrypoint.py / skillharm-entrypoint.sh /
# mock_http_sink.py / parse_entrypoint.py). Same rationale as risk_taxonomy.json
# — lives at harness root, must reach the build context for `COPY runtime`.
cp -r "$HARNESS_DIR/runtime"                     "$TASK_COPY/environment/"

# The canonical task we're attacking. Lives at environment/task/ so the
# Dockerfile's `COPY task /root/task` lands it inside the container.
cp -r "$CANONICAL_TASK" "$TASK_COPY/environment/task"

# Pre-computed scanner baseline for the ONE skill this combo's injection target
# lives in. Staged at environment/baselines/ (peer to scan.py, NOT inside task/)
# so it reaches the container as /root/baselines/<skill>.json — the agent reads
# it during Step 5.7's attribution, but it never enters the agent's
# `cp -r task/ samples/<id>/` and therefore does not pollute generated samples.
#
# Only the owning skill's baseline is staged: other skills' baselines are
# irrelevant to this combo and would just be dead data in the container.
# Derive <skill_name> from injection_target_path = environment/skills/<skill>/<...>.
case "$TARGET" in
    environment/skills/*) ;;
    *) echo "ERROR: injection_target_path must live under environment/skills/, got: $TARGET" >&2
       exit 1 ;;
esac
TARGET_REMAINDER="${TARGET#environment/skills/}"
SKILL_NAME="${TARGET_REMAINDER%%/*}"

mkdir -p "$TASK_COPY/environment/baselines"
BASELINE_SRC="$HARNESS_DIR/baselines/$TASK_ID/$SKILL_NAME.json"
if [ -f "$BASELINE_SRC" ]; then
    cp "$BASELINE_SRC" "$TASK_COPY/environment/baselines/$SKILL_NAME.json"
fi
# If absent, the empty baselines/ dir still gets COPYed by the Dockerfile;
# Step 5.7 instructs the agent to fall back to scanning the clean skill once
# in-container if /root/baselines/<skill>.json is missing.

# Per-combo selection.json — Python json.dump keeps quoting sane if the target
# path ever contains unusual chars.
python3 -c "
import json
with open('$TASK_COPY/environment/selection.json', 'w') as f:
    json.dump({
        'task_id': '$TASK_ID',
        'risk_id': '$RISK',
        'injection_target_path': '$TARGET',
    }, f, indent=2)
    f.write('\n')
"

# Touch Dockerfile so Docker's layer cache sees a new build context.
touch "$TASK_COPY/environment/Dockerfile"

# Match self-mutating-poisoning/attack_design defaults — caps extended-thinking from eating the whole timeout.
export MAX_THINKING_TOKENS="${MAX_THINKING_TOKENS:-10000}"
export CLAUDE_CODE_EFFORT_LEVEL="${CLAUDE_CODE_EFFORT_LEVEL:-medium}"

# AWS_PROFILE trap: when CLAUDE_CODE_USE_BEDROCK=1, harbor forwards every AWS_*
# variable set on the host (including AWS_PROFILE) to the container. But the
# container has no ~/.aws/ directory, so AWS SDK v3 — which prefers AWS_PROFILE
# over explicit env credentials when both are set — fails profile lookup and
# does not fall back to AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY. Result:
# "Could not load credentials from any providers". Drop AWS_PROFILE from this
# script's env so it is not forwarded. Host shell is unaffected.
unset AWS_PROFILE

# Harbor wants a path relative to where it's invoked. Run from repo root.
cd "$REPO"
TASK_REL=$(python3 -c "import os; print(os.path.relpath('$TASK_COPY', '$REPO'))")

# Per-combo harbor jobs dir. Required for parallel execution from run_all.sh:
# without it, two combos starting near the same second land timestamped subdirs
# in the SAME parent and the latest-job lookup picks each other's job. With a
# per-combo -o, the lookup is unambiguous and no RUN_MARKER comparison needed.
OUT_JOBS="$HARNESS_DIR/jobs/$TASK_ID/$TARGET_SLUG/$RISK"
mkdir -p "$OUT_JOBS"

# Per-combo harbor pty transcript (so parallel run_one.sh's don't fight one log).
HARBOR_LOG_DIR="$HARNESS_DIR/logs"
mkdir -p "$HARBOR_LOG_DIR"
HARBOR_LOG="$HARBOR_LOG_DIR/run_one_${TASK_ID}_${TARGET_SLUG}_${RISK}_$(date +%s).log"

# Optional retries — 1 by default since each run is expensive.
MAX_RETRIES="${NL_HARNESS_MAX_RETRIES:-1}"
ATTEMPT=0
JOB=""

while [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    [ "$ATTEMPT" -gt 1 ] && echo "  Retry $ATTEMPT/$MAX_RETRIES..." && sleep 2

    # script(1) gives harbor a pty so its rich/click progress output stays
    # visible (without it, harbor sees stdout as a pipe and goes silent). When
    # called from run_all.sh in parallel mode, NL_HARNESS_QUIET=1 suppresses
    # terminal output so multiple workers don't garble the screen — the harbor
    # transcript still lands in $HARBOR_LOG. </dev/null prevents script's pty
    # master from consuming bytes off the parent's stdin (e.g. a here-string
    # in a backgrounded run_all.sh worker pool).
    # -y auto-confirms harbor's env-forward prompt; -o is per-combo above.
    #
    # script(1) syntax differs between BSD (macOS) and util-linux (Linux):
    #   - BSD:        script [-q] file command args...
    #   - util-linux: script [-q] -c "command args..." file
    # The BSD form fails on Linux because GNU getopt permutes args and parses
    # harbor's flags (e.g. -p) as script's own options. Pick the form per OS.
    if [ "$(uname -s)" = "Darwin" ]; then
        SCRIPT_RUN=(script -q "$HARBOR_LOG" harbor run -p "$TASK_REL" -a "$AGENT" -m "$MODEL" -y -o "$OUT_JOBS")
    else
        HARBOR_CMD=$(printf '%q ' harbor run -p "$TASK_REL" -a "$AGENT" -m "$MODEL" -y -o "$OUT_JOBS")
        SCRIPT_RUN=(script -q -c "$HARBOR_CMD" "$HARBOR_LOG")
    fi
    if [ "${NL_HARNESS_QUIET:-0}" = "1" ]; then
        "${SCRIPT_RUN[@]}" </dev/null >/dev/null 2>&1 || true
    else
        "${SCRIPT_RUN[@]}" </dev/null || true
    fi

    # Latest-job lookup is race-free now: we only see jobs from THIS combo.
    JOB=""
    for candidate in $(ls -td "$OUT_JOBS"/*/nl_harness__* 2>/dev/null); do
        [ -f "$candidate/result.json" ] || continue
        JOB="$candidate"
        break
    done

    if [ -n "$JOB" ] && [ -d "$JOB/verifier/output" ]; then
        break
    fi

    [ "$ATTEMPT" -ge "$MAX_RETRIES" ] && break
done

if [ -z "$JOB" ]; then
    echo "  ERROR: no matching job found after $MAX_RETRIES attempt(s)"
    exit 1
fi

# --- Archive outputs into the persistent results tree ---
mkdir -p "$OUTPUT_DIR"

# Full /root/output/ snapshot.
if [ -d "$JOB/verifier/output" ]; then
    cp -r "$JOB/verifier/output/"* "$OUTPUT_DIR/" 2>/dev/null || true
fi

# Agent transcript — matches dynamic's layout so CLAUDE.md's debug table applies.
[ -f "$JOB/agent/claude-code.txt" ] && cp "$JOB/agent/claude-code.txt" "$OUTPUT_DIR/claude-code.txt"
[ -f "$JOB/agent/codex.txt" ]       && cp "$JOB/agent/codex.txt"       "$OUTPUT_DIR/codex.txt"
[ -f "$JOB/result.json" ]           && cp "$JOB/result.json"           "$OUTPUT_DIR/result.json"
[ -f "$JOB/verifier/reward.txt" ]   && cp "$JOB/verifier/reward.txt"   "$OUTPUT_DIR/reward.txt"

# Backlink to harbor's full job archive so you can jump straight from results/ into
# jobs/ for trajectory.json / verifier stdout / harbor's logs without manually
# matching timestamps. Relative path so the link survives if the repo moves.
JOB_REL=$(python3 -c "import os; print(os.path.relpath('$JOB', '$OUTPUT_DIR'))")
ln -sfn "$JOB_REL" "$OUTPUT_DIR/job"

# Cost — uses the nl_harness-local calculate_cost.py so pricing changes here
# don't ripple into the dynamic setting. Writes cost.json into the archive for
# later aggregation.
COST_SCRIPT="$SCRIPT_DIR/calculate_cost.py"
TOTAL_COST="?"
if [ -f "$COST_SCRIPT" ] && [ -n "$JOB" ]; then
    python3 "$COST_SCRIPT" "$JOB" --model "$MODEL" > "$OUTPUT_DIR/cost.json" 2> /dev/null || true
    TOTAL_COST=$(python3 -c "
import json
try:
    with open('$OUTPUT_DIR/cost.json') as f:
        d = json.load(f)
    if 'error' in d:
        print('?')
    else:
        print(d.get('cost', {}).get('total_cost', 0))
except Exception:
    print('?')
" 2>/dev/null)
fi

REWARD=$(cat "$OUTPUT_DIR/reward.txt" 2>/dev/null || echo "?")
if [ -f "$OUTPUT_DIR/aborted.json" ]; then
    STATUS="aborted"
elif [ -f "$OUTPUT_DIR/manifest.json" ]; then
    SAMPLE_COUNT=$(find "$OUTPUT_DIR/samples" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    STATUS="ok ($SAMPLE_COUNT samples)"
else
    STATUS="incomplete"
fi

echo "  Status: $STATUS | Reward: $REWARD | Cost: \$$TOTAL_COST"
echo "  Archived: $OUTPUT_DIR"

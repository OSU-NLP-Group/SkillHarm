#!/bin/bash
# Evaluate a victim agent on the same poisoned samples eval.sh covers, but with
# a defense system prompt injected into the agent CLI. This script is a sibling
# of eval.sh — it does not touch baseline outputs and lives in a separate
# results subtree (evals_defense/<defense_slug>/<victim_id>/) so multiple
# defense variants can be compared against the same baseline.
#
# Mechanism:
#   - Replaces `harbor run` with `fixed-payload-poisoning/victim_eval/eval/harbor_run.py`, a launcher
#     that monkey-patches harbor's BaseInstalledAgent.exec_as_agent so the
#     defense text is spliced into the actual command bash will run, just
#     before harbor forwards it to the container.
#   - Claude Code: appends `--append-system-prompt <shlex.quote(text)>` after
#                  `claude --verbose` (does not replace the default prompt).
#   - Codex:       prepends `cat >"$CODEX_HOME/AGENTS.md" <<EOF ... EOF` to
#                  the same shell command as `codex exec` (per-trial AGENTS.md).
#
# Required runtime: harbor 0.6+ at /home/ubuntu/.local/share/uv/tools/harbor
# (the same binary baseline `harbor run` uses; pyproject pins .venv to v0.6.3
# too so both interpreters share the codex Azure plumbing). harbor_run.py is
# invoked via the tool python explicitly to keep launcher behavior identical
# regardless of cwd / .venv state.
#
# Required:
#   SKILLHARM_DEFENSE_PROMPT_FILE — absolute path to a defense prompt .md
#                                     file. Its basename (sans .md) becomes
#                                     <defense_slug>.
#
# Usage:
#   SKILLHARM_DEFENSE_PROMPT_FILE=$REPO/fixed-payload-poisoning/victim_eval/eval/defenses/warning_v1.md \
#       bash eval_defense.sh [victim_agent] [victim_model]
#
# All other env vars (NL_TASKS / NL_RISKS / NL_TARGETS / NL_GENERATOR /
# NL_REALIZATIONS / NL_KEEP_ONLY / NL_HARNESS_PARALLEL / NL_HARNESS_MAX_RETRIES
# / NL_RESULTS_DIR / NL_SAMPLE_LIST / NL_VICTIM_SUFFIX / CLAUDE_CODE_VERSION)
# behave identically to eval.sh — see eval.sh's header for documentation.
#
# Output layout (one record per sample):
#   <RESULTS_DIR>/<task>/<slug>/<risk>/outputs/<generator>/
#     evals_defense/<defense_slug>/<victim_agent_id>/<sample_id>/
#       asr_result.json
#       result.json
#       reward.txt
#       claude-code.txt | codex.txt
#       cost.json
#       job -> ../../...
#
# Aggregate summary (rebuilt every run):
#   <RESULTS_DIR>/<task>/eval_defense_summary_<defense_slug>__<victim_agent_id>.json

set -e

AGENT="${1:-claude-code}"
MODEL="${2:-us.anthropic.claude-sonnet-4-6}"
PARALLEL="${NL_HARNESS_PARALLEL:-2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(dirname "$SCRIPT_DIR")"
REPO="$(cd "$HARNESS_DIR/.." && pwd)"

# --- Validate defense prompt ---
if [ -z "${SKILLHARM_DEFENSE_PROMPT_FILE:-}" ]; then
    echo "ERROR: SKILLHARM_DEFENSE_PROMPT_FILE must be set"
    echo "       Example:"
    echo "         export SKILLHARM_DEFENSE_PROMPT_FILE=$REPO/fixed-payload-poisoning/victim_eval/eval/defenses/warning_v1.md"
    exit 1
fi
if [ ! -f "$SKILLHARM_DEFENSE_PROMPT_FILE" ]; then
    echo "ERROR: defense prompt file not found: $SKILLHARM_DEFENSE_PROMPT_FILE"
    exit 1
fi
# Resolve to absolute path so the launcher (which runs from $REPO) can find it.
SKILLHARM_DEFENSE_PROMPT_FILE=$(python3 -c "import os, sys; print(os.path.abspath(sys.argv[1]))" "$SKILLHARM_DEFENSE_PROMPT_FILE")
export SKILLHARM_DEFENSE_PROMPT_FILE

DEFENSE_SLUG=$(basename "$SKILLHARM_DEFENSE_PROMPT_FILE")
DEFENSE_SLUG="${DEFENSE_SLUG%.md}"
if [ -z "$DEFENSE_SLUG" ]; then
    echo "ERROR: could not derive defense slug from $SKILLHARM_DEFENSE_PROMPT_FILE"
    exit 1
fi

HARBOR_LAUNCHER="$REPO/fixed-payload-poisoning/victim_eval/eval/harbor_run.py"
if [ ! -f "$HARBOR_LAUNCHER" ]; then
    echo "ERROR: harbor launcher not found: $HARBOR_LAUNCHER"
    exit 1
fi

# Tool-installed harbor (0.6.x) — same binary baseline `harbor run` uses.
# We invoke its python directly so harbor_run.py's monkey-patches land on
# the SAME harbor module that baseline runs against (no .venv 0.1.34 fork).
HARBOR_TOOL_PYTHON="${HARBOR_TOOL_PYTHON:-$HOME/.local/share/uv/tools/harbor/bin/python}"
if [ ! -x "$HARBOR_TOOL_PYTHON" ]; then
    echo "ERROR: harbor tool python not found at $HARBOR_TOOL_PYTHON"
    echo "       Install with: uv tool install harbor"
    exit 1
fi

# Results tree. Same convention as eval.sh.
RESULTS_DIR_REL="${NL_RESULTS_DIR:-fixed-payload-poisoning/results}"
if [[ "$RESULTS_DIR_REL" = /* ]]; then
    echo "ERROR: NL_RESULTS_DIR must be relative to skillsbench/, got absolute path: $RESULTS_DIR_REL"
    exit 1
fi
RESULTS_DIR="$REPO/$RESULTS_DIR_REL"
JOBS_BASE="$HARNESS_DIR/jobs"
COST_SCRIPT="$SCRIPT_DIR/calculate_cost.py"

# Match eval.sh's victim id derivation.
MODEL_SHORT=$(echo "$MODEL" | sed 's|.*/||; s|^us\.anthropic\.||; s|^anthropic\.||; s|-v[0-9:]*$||')
# OpenRouter models look like "openrouter/qwen/qwen3.6-27b"; the default sed
# above collapses that to just "qwen3.6-27b" and loses the org segment.
# Mirror eval.sh: keep the org/model path (minus "openrouter/") and replace
# remaining slashes with "__" so baseline + defense evals share one VICTIM_ID.
if [[ "$MODEL" == openrouter/* ]]; then
    MODEL_SHORT=$(echo "${MODEL#openrouter/}" | sed 's|/|__|g')
fi
if [ "$AGENT" = "claude-code" ]; then
    VICTIM_ID="claude_${MODEL_SHORT}"
else
    VICTIM_ID="${AGENT}_${MODEL_SHORT}"
fi
if [ -n "${NL_VICTIM_SUFFIX:-}" ]; then
    VICTIM_ID="${VICTIM_ID}${NL_VICTIM_SUFFIX}"
fi

# --- Validate optional sample-list filter ---
if [ -n "${NL_SAMPLE_LIST:-}" ] && [ ! -f "$NL_SAMPLE_LIST" ]; then
    echo "ERROR: NL_SAMPLE_LIST=$NL_SAMPLE_LIST does not exist"
    exit 1
fi

# --- Build the sample list by walking the results tree ---
COMBOS_TSV=""
shopt -s nullglob
for task_dir in "$RESULTS_DIR"/*/; do
    task=$(basename "$task_dir")
    [ -n "${NL_TASKS:-}" ] && ! echo "$NL_TASKS" | tr ',' '\n' | grep -Fxq "$task" && continue
    for slug_dir in "$task_dir"*/; do
        slug=$(basename "$slug_dir")
        for risk_dir in "$slug_dir"*/; do
            risk=$(basename "$risk_dir")
            [ -n "${NL_RISKS:-}" ] && ! echo "$NL_RISKS" | tr ',' '\n' | grep -Fxq "$risk" && continue
            for gen_dir in "$risk_dir"outputs/*/; do
                generator=$(basename "$gen_dir")
                [ -n "${NL_GENERATOR:-}" ] && ! echo "$NL_GENERATOR" | tr ',' '\n' | grep -Fxq "$generator" && continue
                manifest="$gen_dir/manifest.json"
                [ -f "$manifest" ] || continue
                filter_result="$risk_dir/filter/$generator/filter_result.json"
                for sample_dir in "$gen_dir"samples/*/; do
                    sample_id=$(basename "$sample_dir")
                    if [ -n "${NL_SAMPLE_LIST:-}" ]; then
                        keep=$(awk -F'\t' -v t="$task" -v s="$slug" -v r="$risk" -v sid="$sample_id" \
                            'BEGIN{f=0} /^[[:space:]]*(#|$)/ {next} \
                             $1==t && $2==s && $3==r && $4==sid {f=1; exit} \
                             END{print f}' "$NL_SAMPLE_LIST")
                        [ "$keep" = "1" ] || continue
                    fi
                    if [ "${NL_KEEP_ONLY:-}" = "1" ]; then
                        if [ ! -f "$filter_result" ]; then
                            continue
                        fi
                        keep=$(python3 - "$filter_result" "$sample_id" <<'PY'
import json, sys
fr_path, sid = sys.argv[1], sys.argv[2]
with open(fr_path) as f:
    fr = json.load(f)
sv = next((s for s in fr.get("sample_verdicts", []) if s.get("sample_id") == sid), None)
print("1" if sv and sv.get("verdict") == "keep" else "0")
PY
                        )
                        [ "$keep" = "1" ] || continue
                    fi
                    if [ -n "${NL_REALIZATIONS:-}" ] || [ -n "${NL_TARGETS:-}" ]; then
                        keep=$(python3 - "$manifest" "$sample_id" "${NL_REALIZATIONS:-}" "${NL_TARGETS:-}" <<'PY'
import json, sys
manifest, sample_id, real_filter, target_filter = sys.argv[1:5]
with open(manifest) as f:
    entries = json.load(f)
entry = next((e for e in entries if e["sample_id"] == sample_id), None)
if entry is None:
    print("0"); sys.exit(0)
if real_filter and entry.get("realization") not in real_filter.split(","):
    print("0"); sys.exit(0)
if target_filter and entry.get("target_task_relative_path") not in target_filter.split(","):
    print("0"); sys.exit(0)
print("1")
PY
                        )
                        [ "$keep" = "1" ] || continue
                    fi
                    COMBOS_TSV+="$task	$slug	$risk	$generator	$sample_id	$sample_dir"$'\n'
                done
            done
        done
    done
done
shopt -u nullglob

TOTAL=$(echo -n "$COMBOS_TSV" | grep -c '^' || echo 0)
if [ "$TOTAL" -eq 0 ]; then
    echo "ERROR: no samples matched the filters"
    echo "  NL_TASKS=${NL_TASKS:-(any)}  NL_RISKS=${NL_RISKS:-(any)}  NL_TARGETS=${NL_TARGETS:-(any)}"
    echo "  NL_GENERATOR=${NL_GENERATOR:-(any)}  NL_REALIZATIONS=${NL_REALIZATIONS:-(any)}"
    exit 1
fi

# --- Count already-evaluated for progress / cost accounting ---
SKIP=0; TODO=0
BACKFILLED=0
while IFS=$'\t' read -r task slug risk generator sample_id sample_dir; do
    [ -z "$task" ] && continue
    eval_dir="$RESULTS_DIR/$task/$slug/$risk/outputs/$generator/evals_defense/$DEFENSE_SLUG/$VICTIM_ID/$sample_id"
    if [ ! -f "$eval_dir/asr_result.json" ] && [ -f "$eval_dir/result.json" ] && [ -L "$eval_dir/job" ]; then
        cp "$eval_dir/job/verifier/asr_result.json"        "$eval_dir/asr_result.json" 2>/dev/null \
            || cp "$eval_dir/job/verifier/output/asr_result.json" "$eval_dir/asr_result.json" 2>/dev/null \
            || true
        [ -f "$eval_dir/asr_result.json" ] && BACKFILLED=$((BACKFILLED + 1))
    fi
    if [ -f "$eval_dir/asr_result.json" ] || [ -f "$eval_dir/aborted.json" ]; then
        SKIP=$((SKIP + 1))
    else
        TODO=$((TODO + 1))
    fi
done <<< "$COMBOS_TSV"
[ "$BACKFILLED" -gt 0 ] && echo "  (backfilled asr_result.json for $BACKFILLED previously-run samples)"

echo "=========================================="
echo "  nl_harness: Defense Evaluation Run"
echo "  Defense:      $DEFENSE_SLUG"
echo "  Defense file: $SKILLHARM_DEFENSE_PROMPT_FILE"
echo "  Victim agent: $AGENT ($MODEL_SHORT)  →  victim_id=$VICTIM_ID"
echo "  Parallel:     $PARALLEL concurrent samples"
[ "${NL_KEEP_ONLY:-}" = "1" ] && echo "  Filter:       NL_KEEP_ONLY=1 (only filter_result.json verdict=keep)"
[ -n "${NL_SAMPLE_LIST:-}" ] && echo "  Sample list:  $NL_SAMPLE_LIST"
[ -n "${CLAUDE_CODE_VERSION:-}" ] && [ "$AGENT" = "claude-code" ] && echo "  Pinned claude-code version: $CLAUDE_CODE_VERSION"
echo "  Samples: $TOTAL  |  Done: $SKIP  |  To run: $TODO"
echo "  Started: $(date)"
echo "=========================================="
echo ""

# Match eval.sh defaults so victim runs behave the same as baseline (only
# the system-prompt channel differs).
if [ -z "${CLAUDE_CODE_VERSION:-}" ]; then
    export MAX_THINKING_TOKENS="${MAX_THINKING_TOKENS:-10000}"
    export CLAUDE_CODE_EFFORT_LEVEL="${CLAUDE_CODE_EFFORT_LEVEL:-medium}"
fi

# AWS_PROFILE trap (see CLAUDE.md): drop AWS_PROFILE so harbor doesn't forward
# it into the container, where AWS SDK v3 would prefer it over explicit creds
# and fail profile lookup.
unset AWS_PROFILE

cd "$REPO"
MAX_RETRIES="${NL_HARNESS_MAX_RETRIES:-1}"
RUN_START=$(date +%s)

# ---------------------------------------------------------------------------
# Per-sample worker. Same shape as eval.sh's process_sample, but writes into
# evals_defense/<defense_slug>/<victim_id>/ and invokes harbor through the
# defense launcher.
# ---------------------------------------------------------------------------
process_sample() {
    local task="$1" slug="$2" risk="$3" generator="$4" sample_id="$5" sample_dir="$6" parallel_mode="$7"

    local eval_dir="$RESULTS_DIR/$task/$slug/$risk/outputs/$generator/evals_defense/$DEFENSE_SLUG/$VICTIM_ID/$sample_id"
    mkdir -p "$eval_dir"

    # Per-sample harbor jobs dir, namespaced by defense slug so concurrent
    # baseline + defense runs (or two defense variants) cannot collide.
    local sample_jobs_dir="$JOBS_BASE/${VICTIM_ID}__defense__${DEFENSE_SLUG}/$sample_id"
    mkdir -p "$sample_jobs_dir"

    local sample_rel
    sample_rel=$(python3 -c "import os; print(os.path.relpath('${sample_dir%/}', '$REPO'))")

    local start=$(date +%s)
    local job=""
    local attempt=0

    while [ "$attempt" -lt "$MAX_RETRIES" ]; do
        attempt=$((attempt + 1))
        [ "$attempt" -gt 1 ] && echo "  [$sample_id] retry $attempt/$MAX_RETRIES" && sleep 2

        cd "$REPO"

        local extra_ak=()
        if [ "$AGENT" = "claude-code" ] && [ -n "${CLAUDE_CODE_VERSION:-}" ]; then
            extra_ak+=(--ak "version=$CLAUDE_CODE_VERSION")
        fi
        # Optional bind mounts forwarded to harbor as --mounts-json. Mirror
        # eval.sh's plumbing: eval_command_gemini_defense.sh sets
        # NL_HARNESS_MOUNTS_JSON to bind /root/gcloud-adc.json into the
        # container — without forwarding it here the gemini-cli agent fails
        # ENOENT on every sample (manifest's auth env points at a path the
        # container can't see).
        local mounts_json="${NL_HARNESS_MOUNTS_JSON:-}"
        # gemini-cli session capture workaround — same as eval.sh: harbor's
        # post-run hook expects session-*.json but gemini-cli writes
        # session-*.jsonl one dir deeper, so without bind-mounting
        # /root/.gemini/tmp the trajectory never makes it out.
        local gemini_tmp_host=""
        if [ "$AGENT" = "gemini-cli" ]; then
            gemini_tmp_host="$sample_jobs_dir/gemini-tmp"
            mkdir -p "$gemini_tmp_host"
            mounts_json=$(BASE="$mounts_json" GTMP="$gemini_tmp_host" python3 -c '
import json, os
base = json.loads(os.environ["BASE"] or "[]")
base.append({
    "type": "bind",
    "source": os.environ["GTMP"],
    "target": "/root/.gemini/tmp",
})
print(json.dumps(base))
')
        fi
        local extra_mounts=()
        if [ -n "$mounts_json" ]; then
            extra_mounts+=(--mounts-json "$mounts_json")
        fi
        local script_run
        # `-y` auto-confirms harbor's env-forward prompt; baseline eval.sh
        # passes it too. Required for parallel-friendly non-interactive runs.
        # script(1) gives harbor a pty; the typescript is sent to /dev/null
        # (used to be a per-sample harbor.log of ANSI escape spam nobody read —
        # real transcript is under jobs/).
        if [ "$(uname -s)" = "Darwin" ]; then
            script_run=(script -q /dev/null "$HARBOR_TOOL_PYTHON" "$HARBOR_LAUNCHER" run -p "$sample_rel" -a "$AGENT" -m "$MODEL" "${extra_ak[@]}" "${extra_mounts[@]}" -y -o "$sample_jobs_dir")
        else
            local harbor_cmd
            harbor_cmd=$(printf '%q ' "$HARBOR_TOOL_PYTHON" "$HARBOR_LAUNCHER" run -p "$sample_rel" -a "$AGENT" -m "$MODEL" "${extra_ak[@]}" "${extra_mounts[@]}" -y -o "$sample_jobs_dir")
            script_run=(script -q -c "$harbor_cmd" /dev/null)
        fi
        if [ "$parallel_mode" = "1" ]; then
            "${script_run[@]}" </dev/null || true
        else
            "${script_run[@]}" </dev/null >/dev/null 2>&1 || true
        fi

        job=""
        for candidate in $(ls -td "$sample_jobs_dir"/*/*__* 2>/dev/null); do
            [ -f "$candidate/result.json" ] || continue
            job="$candidate"
            break
        done
        if [ -n "$job" ]; then
            break
        fi
        [ "$attempt" -ge "$MAX_RETRIES" ] && break
    done

    local end=$(date +%s)
    local duration=$((end - start))

    if [ -z "$job" ]; then
        echo "{\"reason\": \"no harbor job\", \"sample_id\": \"$sample_id\"}" > "$eval_dir/aborted.json"
        echo "  [done $sample_id] ABORTED (no harbor job, ${duration}s)"
        return 1
    fi

    cp "$job/verifier/asr_result.json"        "$eval_dir/asr_result.json" 2>/dev/null \
        || cp "$job/verifier/output/asr_result.json" "$eval_dir/asr_result.json" 2>/dev/null \
        || true
    [ -f "$job/verifier/reward.txt" ]              && cp "$job/verifier/reward.txt"           "$eval_dir/reward.txt"
    [ -f "$job/result.json" ]                      && cp "$job/result.json"                   "$eval_dir/result.json"
    [ -f "$job/agent/claude-code.txt" ]            && cp "$job/agent/claude-code.txt"         "$eval_dir/claude-code.txt"
    [ -f "$job/agent/codex.txt" ]                  && cp "$job/agent/codex.txt"               "$eval_dir/codex.txt"
    [ -f "$job/agent/gemini-cli.txt" ]             && cp "$job/agent/gemini-cli.txt"          "$eval_dir/gemini-cli.txt"

    # gemini-cli trajectory: harbor's post-run hook is broken for --prompt
    # mode (greps session-*.json, gemini writes session-*.jsonl). The bind
    # mount above surfaces the JSONL on the host; convert it here in-repo
    # and drop a copy into the harbor job dir so calculate_cost.py (which
    # keys off $job/agent/gemini-cli.trajectory.json) can read tokens from
    # it. Without this, cost.json ends up with "No token usage data found".
    if [ "$AGENT" = "gemini-cli" ] && [ -n "$gemini_tmp_host" ]; then
        python3 "$SCRIPT_DIR/_convert_gemini_session.py" \
            "$gemini_tmp_host" "$eval_dir/gemini-cli.trajectory.json" \
            2>/dev/null || true
        if [ -f "$eval_dir/gemini-cli.trajectory.json" ]; then
            mkdir -p "$job/agent"
            cp "$eval_dir/gemini-cli.trajectory.json" \
               "$job/agent/gemini-cli.trajectory.json" 2>/dev/null || true
        fi
    fi

    local job_rel
    job_rel=$(python3 -c "import os; print(os.path.relpath('$job', '$eval_dir'))")
    ln -sfn "$job_rel" "$eval_dir/job"

    local step_cost="0"
    if [ -f "$COST_SCRIPT" ]; then
        python3 "$COST_SCRIPT" "$job" --model "$MODEL" > "$eval_dir/cost.json" 2>/dev/null || true
        step_cost=$(python3 -c "
import json
try:
    with open('$eval_dir/cost.json') as f: d = json.load(f)
    print(0 if 'error' in d else d.get('cost',{}).get('total_cost', 0))
except Exception:
    print(0)
" 2>/dev/null)
    fi

    if [ ! -f "$eval_dir/asr_result.json" ]; then
        local reason="missing asr_result.json (harbor likely failed pre-test)"
        if [ -f "$job"/*__*/exception.txt ] 2>/dev/null; then
            reason="harbor exception (see job/exception.txt)"
        fi
        printf '{"reason": "%s", "sample_id": "%s"}\n' "$reason" "$sample_id" > "$eval_dir/aborted.json"
        echo "  [done $sample_id] ABORTED: $reason  ${duration}s  \$$step_cost"
        return 0
    fi

    local asr
    asr=$(python3 -c "import json; print(json.load(open('$eval_dir/asr_result.json')).get('asr_success'))" 2>/dev/null || echo "?")
    echo "  [done $sample_id] asr=$asr  ${duration}s  \$$step_cost"
}

# ---------------------------------------------------------------------------
# Worker pool. Same shape as eval.sh.
# ---------------------------------------------------------------------------
PIDS=()
prune_done() {
    local new=()
    for p in "${PIDS[@]}"; do
        if kill -0 "$p" 2>/dev/null; then new+=("$p"); fi
    done
    PIDS=("${new[@]}")
}

LAUNCHED=0
while IFS=$'\t' read -r task slug risk generator sample_id sample_dir <&3; do
    [ -z "$task" ] && continue
    eval_dir="$RESULTS_DIR/$task/$slug/$risk/outputs/$generator/evals_defense/$DEFENSE_SLUG/$VICTIM_ID/$sample_id"
    if [ -f "$eval_dir/asr_result.json" ] || [ -f "$eval_dir/aborted.json" ]; then
        continue
    fi

    while prune_done; [ "${#PIDS[@]}" -ge "$PARALLEL" ]; do
        sleep 1
        prune_done
    done

    LAUNCHED=$((LAUNCHED + 1))
    echo "[launch $LAUNCHED/$TODO] $task / $risk / $sample_id"
    if [ "$PARALLEL" = "1" ]; then
        process_sample "$task" "$slug" "$risk" "$generator" "$sample_id" "$sample_dir" 1
    else
        process_sample "$task" "$slug" "$risk" "$generator" "$sample_id" "$sample_dir" 0 &
        PIDS+=($!)
    fi
done 3<<< "$COMBOS_TSV"

wait

# --- Rebuild per-task aggregate summary across every completed defense eval ---
python3 - "$RESULTS_DIR" "$VICTIM_ID" "$DEFENSE_SLUG" <<'PY'
import json, sys
from collections import defaultdict
from pathlib import Path

results_dir  = Path(sys.argv[1])
victim_id    = sys.argv[2]
defense_slug = sys.argv[3]

per_task = defaultdict(lambda: {
    "victim_agent_id": victim_id,
    "defense_slug":    defense_slug,
    "samples":         [],
    "by_realization":  defaultdict(lambda: [0, 0]),
    "by_risk":         defaultdict(lambda: [0, 0]),
    "by_generator":    defaultdict(lambda: [0, 0]),
})

# Defense eval dir layout adds one extra path segment (defense_slug):
#   <task>/<slug>/<risk>/outputs/<generator>/evals_defense/<defense_slug>/<victim_id>/<sample_id>/asr_result.json
for asr_path in results_dir.rglob(f"evals_defense/{defense_slug}/{victim_id}/*/asr_result.json"):
    eval_dir = asr_path.parent
    sample_id = eval_dir.name
    parts = asr_path.parts
    try:
        outputs_idx = parts.index("outputs")
    except ValueError:
        continue
    task      = parts[outputs_idx - 3]
    slug      = parts[outputs_idx - 2]
    risk      = parts[outputs_idx - 1]
    generator = parts[outputs_idx + 1]

    try:
        with open(asr_path) as f:
            asr = json.load(f)
    except Exception:
        continue

    # asr_path.parents[0..]:
    #   0: <sample_id>
    #   1: <victim_id>
    #   2: <defense_slug>
    #   3: evals_defense
    #   4: <generator>     ← manifest lives here
    manifest_path = asr_path.parents[4] / "manifest.json"
    realization = None
    target = None
    if manifest_path.is_file():
        try:
            with open(manifest_path) as f:
                for entry in json.load(f):
                    if entry.get("sample_id") == sample_id:
                        realization = entry.get("realization")
                        target = entry.get("target_task_relative_path")
                        break
        except Exception:
            pass

    success = bool(asr.get("asr_success"))
    bucket = per_task[task]
    bucket["samples"].append({
        "sample_id":   sample_id,
        "risk_id":     risk,
        "target_slug": slug,
        "target_path": target,
        "realization": realization,
        "generator":   generator,
        "asr_success": success,
        "evidence":    asr.get("asr_evidence"),
    })
    if realization:
        bucket["by_realization"][realization][0] += int(success)
        bucket["by_realization"][realization][1] += 1
    bucket["by_risk"][risk][0]               += int(success)
    bucket["by_risk"][risk][1]               += 1
    bucket["by_generator"][generator][0]     += int(success)
    bucket["by_generator"][generator][1]     += 1

for task, bucket in per_task.items():
    bucket["by_realization"] = {k: {"success": v[0], "total": v[1], "asr": (v[0] / v[1] if v[1] else 0)} for k, v in bucket["by_realization"].items()}
    bucket["by_risk"]        = {k: {"success": v[0], "total": v[1], "asr": (v[0] / v[1] if v[1] else 0)} for k, v in bucket["by_risk"].items()}
    bucket["by_generator"]   = {k: {"success": v[0], "total": v[1], "asr": (v[0] / v[1] if v[1] else 0)} for k, v in bucket["by_generator"].items()}
    n = len(bucket["samples"])
    s = sum(1 for x in bucket["samples"] if x["asr_success"])
    bucket["overall"] = {"success": s, "total": n, "asr": (s / n if n else 0)}
    out = results_dir / task / f"eval_defense_summary_{defense_slug}__{victim_id}.json"
    out.write_text(json.dumps(bucket, indent=2, default=list))
    print(f"  Wrote {out}: {s}/{n} ASR={bucket['overall']['asr']:.3f}")
PY

RUN_END=$(date +%s)
TOTAL_ELAPSED=$((RUN_END - RUN_START))
HOURS=$((TOTAL_ELAPSED / 3600))
MINS=$(( (TOTAL_ELAPSED % 3600) / 60 ))

echo ""
echo "=========================================="
echo "  nl_harness DEFENSE EVAL COMPLETE"
echo "=========================================="
echo "  Defense:   $DEFENSE_SLUG"
echo "  Victim:    $AGENT ($MODEL_SHORT)"
echo "  Parallel:  $PARALLEL"
echo "  Time:      ${HOURS}h ${MINS}m"
echo "  Finished:  $(date)"
echo "=========================================="

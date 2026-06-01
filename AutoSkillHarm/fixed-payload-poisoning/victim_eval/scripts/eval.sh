#!/bin/bash
# Evaluate a victim agent on the poisoned samples that run_all.sh produced.
#
# Each generated sample directory (samples/<sample_id>/) is itself a drop-in
# SkillsBench task: harbor.run can take it as -p, the agent runs against
# instruction.md, and tests/test.sh tail-invokes run_asr_evaluator.py which
# writes /logs/verifier/asr_result.json. This script iterates every sample of
# a chosen generator, runs the victim agent on each, and archives the ASR
# verdict next to the generator's outputs.
#
# Usage:
#   bash eval.sh [victim_agent] [victim_model]
#
# Examples:
#   # Sonnet 4.6, 2-way parallel (default), all generated samples:
#   bash eval.sh claude-code us.anthropic.claude-sonnet-4-6
#
#   # Qwen3.6-27B via OpenRouter using the opencode harness:
#   OPENROUTER_API_KEY=sk-or-... \
#       bash eval.sh opencode openrouter/qwen/qwen3.6-27b
#
#   # Filter to one task / one risk / one realization, serial:
#   NL_HARNESS_PARALLEL=1 \
#   NL_TASKS="court-form-filling" \
#   NL_RISKS="data_exfiltration" \
#   NL_REALIZATIONS="plain_text,executable_code" \
#       bash eval.sh claude-code us.anthropic.claude-sonnet-4-6
#
#   # Crank parallelism to 4:
#   NL_HARNESS_PARALLEL=4 bash eval.sh codex gpt-5.4
#
# Filtering (env vars, comma-separated):
#   NL_TASKS         — task ids (default: every task with samples)
#   NL_RISKS         — risk ids
#   NL_TARGETS       — injection target paths
#   NL_GENERATOR     — generator output dir name (e.g. "claude_claude-opus-4-7";
#                      default: every dir under outputs/ with samples)
#   NL_REALIZATIONS  — realizations to keep (e.g. plain_text,executable_code)
#   NL_KEEP_ONLY     — if "1", only include samples whose
#                      <risk>/filter/<generator>/filter_result.json verdict is
#                      "keep" (samples lacking a filter_result.json are skipped).
#                      Use this when extending eval to additional victim agents
#                      after static_attack_filter has triaged the design tree.
#   NL_HARNESS_PARALLEL — concurrent samples to run (default 2; set 1 for serial)
#   NL_HARNESS_MAX_RETRIES — per-sample retries on harbor failure (default 1)
#   NL_RESULTS_DIR   — results tree to walk, relative to skillsbench/ (default
#                      fixed-payload-poisoning/results). Mirror of the same env var used by
#                      run_all.sh / run_one.sh — point it at e.g.
#                      ablations/designer-gpt-5.4 to evaluate an
#                      ablation tree instead of the main results/.
#   NL_SAMPLE_LIST   — path to a 4-column TSV (task<TAB>slug<TAB>risk<TAB>sample_id;
#                      '#'-prefixed and blank lines ignored). When set, only
#                      samples whose tuple appears in the file are evaluated.
#                      Use this to re-run the exact same selection a previous
#                      analysis produced.
#   NL_VICTIM_SUFFIX — appended to VICTIM_ID, so a re-eval under different
#                      settings (e.g. a pinned claude-code version) lands in
#                      its own evals/<victim_id>/ subtree without overwriting.
#                      Example: "-old-claude-version".
#   CLAUDE_CODE_VERSION — when set AND the victim agent is claude-code, the
#                      version is forwarded to harbor as `--ak version=<v>`,
#                      pinning the claude-code CLI installed inside the
#                      container. Default (unset) installs the latest.
#   OPENROUTER_API_KEY — required when victim_model begins with "openrouter/".
#                      Forwarded into the agent container via harbor's
#                      --agent-env so opencode (or any other LiteLLM-backed
#                      agent) can authenticate with OpenRouter.
#
# Output layout (one record per sample):
#   results/<task>/<slug>/<risk>/outputs/<generator>/
#     evals/<victim_agent_id>/<sample_id>/
#       asr_result.json     — verdict from run_asr_evaluator.py
#       result.json         — harbor's per-trial result
#       reward.txt          — utility-test reward (untrusted; ASR is the signal)
#       claude-code.txt     — agent transcript (or codex.txt / gemini-cli.txt /
#                             opencode.txt depending on victim agent)
#       cost.json           — token + dollar cost
#       job -> ../../...    — symlink back into harbor's full job archive
#
# Aggregate summary (rebuilt every run, includes all completed evals):
#   results/<task>/eval_summary_<victim_agent_id>.json
#
# Live progress:
#   In serial mode (PARALLEL=1) harbor's progress streams directly to your
#   terminal via the script(1) pty wrapper. In parallel mode harbor's pty
#   output is discarded (the typescript would just be ANSI spinner gunk
#   nobody reads); inspect jobs/<victim>/<sample_id>/ for the
#   real per-trial transcript.

set -e

AGENT="${1:-claude-code}"
MODEL="${2:-us.anthropic.claude-sonnet-4-6}"
PARALLEL="${NL_HARNESS_PARALLEL:-2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(dirname "$SCRIPT_DIR")"
REPO="$(cd "$HARNESS_DIR/.." && pwd)"

# When the model string begins with "openrouter/", OPENROUTER_API_KEY must be
# set. Check up front so we fail fast with a clear error instead of producing
# a cryptic auth failure inside every container we spawn.
if [[ "$MODEL" == openrouter/* ]]; then
    if [ -z "${OPENROUTER_API_KEY:-}" ]; then
        echo "ERROR: MODEL=$MODEL uses OpenRouter but OPENROUTER_API_KEY is not set."
        echo "  Export it: export OPENROUTER_API_KEY=sk-or-..."
        exit 1
    fi
fi

# Results tree. Mirror of run_all.sh / run_one.sh: NL_RESULTS_DIR is a path
# relative to skillsbench/, so the same env var works regardless of cwd and
# the eval side reads from the same tree the generator side wrote to.
RESULTS_DIR_REL="${NL_RESULTS_DIR:-fixed-payload-poisoning/results}"
if [[ "$RESULTS_DIR_REL" = /* ]]; then
    echo "ERROR: NL_RESULTS_DIR must be relative to skillsbench/, got absolute path: $RESULTS_DIR_REL"
    exit 1
fi
RESULTS_DIR="$REPO/$RESULTS_DIR_REL"
JOBS_BASE="$HARNESS_DIR/jobs"
COST_SCRIPT="$SCRIPT_DIR/calculate_cost.py"

# Match run_all.sh's normalization so the victim agent dir name follows the
# same convention as the generator output dirs.
MODEL_SHORT=$(echo "$MODEL" | sed 's|.*/||; s|^us\.anthropic\.||; s|^anthropic\.||; s|-v[0-9:]*$||')
# OpenRouter models look like "openrouter/qwen/qwen3.6-27b"; the default sed
# above would collapse that to just "qwen3.6-27b" and lose the org segment.
# Preserve the org/model path (minus the "openrouter/" prefix) and replace
# remaining slashes with "__" so the result is a valid directory component.
if [[ "$MODEL" == openrouter/* ]]; then
    MODEL_SHORT=$(echo "${MODEL#openrouter/}" | sed 's|/|__|g')
fi
if [ "$AGENT" = "claude-code" ]; then
    VICTIM_ID="claude_${MODEL_SHORT}"
else
    VICTIM_ID="${AGENT}_${MODEL_SHORT}"
fi
# Optional suffix so a re-eval under different settings (e.g. a pinned
# claude-code version) lands in its own evals/<victim_id>/ subtree without
# overwriting the previous run.
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
                        # 4-column TSV (task<TAB>slug<TAB>risk<TAB>sample_id);
                        # blank lines and lines starting with '#' are ignored.
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
# Also opportunistically backfill asr_result.json when a previous run finished
# harbor (result.json + job symlink present) but failed to copy the verdict —
# either an older eval.sh bug, or a Ctrl-C right before the cp.
SKIP=0; TODO=0
BACKFILLED=0
while IFS=$'\t' read -r task slug risk generator sample_id sample_dir; do
    [ -z "$task" ] && continue
    eval_dir="$RESULTS_DIR/$task/$slug/$risk/outputs/$generator/evals/$VICTIM_ID/$sample_id"
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
echo "  nl_harness: Evaluation Run"
echo "  Victim agent: $AGENT ($MODEL_SHORT)  →  victim_id=$VICTIM_ID"
echo "  Parallel:     $PARALLEL concurrent samples"
[ "${NL_KEEP_ONLY:-}" = "1" ] && echo "  Filter:       NL_KEEP_ONLY=1 (only filter_result.json verdict=keep)"
[ -n "${NL_SAMPLE_LIST:-}" ] && echo "  Sample list:  $NL_SAMPLE_LIST"
[ -n "${CLAUDE_CODE_VERSION:-}" ] && [ "$AGENT" = "claude-code" ] && echo "  Pinned claude-code version: $CLAUDE_CODE_VERSION"
echo "  Samples: $TOTAL  |  Done: $SKIP  |  To run: $TODO"
echo "  Started: $(date)"
echo "=========================================="
echo ""

# Match run_one.sh defaults so victim runs behave like the generator runs.
# These translate (via harbor's CliFlag env_fallback) to `--max-thinking-tokens`
# and `--effort` flags on the claude-code CLI; older claude-code builds may
# not recognize them. When CLAUDE_CODE_VERSION is pinned we skip the defaults
# so the old binary doesn't crash on argv parse — callers can still opt in by
# exporting either var explicitly before calling eval.sh.
if [ -z "${CLAUDE_CODE_VERSION:-}" ]; then
    export MAX_THINKING_TOKENS="${MAX_THINKING_TOKENS:-10000}"
    export CLAUDE_CODE_EFFORT_LEVEL="${CLAUDE_CODE_EFFORT_LEVEL:-medium}"
fi

# AWS_PROFILE trap (see CLAUDE.md): harbor forwards every AWS_* var into the
# container, but the container has no ~/.aws/, so AWS SDK v3 fails profile
# lookup instead of falling back to the explicit credential vars. Drop
# AWS_PROFILE here so it is not forwarded; host shell is unaffected.
unset AWS_PROFILE

cd "$REPO"
MAX_RETRIES="${NL_HARNESS_MAX_RETRIES:-1}"
RUN_START=$(date +%s)

# ---------------------------------------------------------------------------
# Per-sample worker. Runs in a subshell when backgrounded with `&`, so
# `cd` and other state is isolated. All paths it needs are passed in.
# ---------------------------------------------------------------------------
process_sample() {
    local task="$1" slug="$2" risk="$3" generator="$4" sample_id="$5" sample_dir="$6" parallel_mode="$7"

    local eval_dir="$RESULTS_DIR/$task/$slug/$risk/outputs/$generator/evals/$VICTIM_ID/$sample_id"
    mkdir -p "$eval_dir"

    # Per-sample harbor jobs dir — isolates parallel runs so two samples can't
    # collide on the latest-job heuristic. Harbor's -o anchors the timestamped
    # job tree under this path.
    local sample_jobs_dir="$JOBS_BASE/$VICTIM_ID/$sample_id"
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
        # script(1) gives harbor a pty so it keeps its native progress output.
        # In serial mode (parallel_mode=1) the pty's tty side echoes to OUR
        # terminal, so the user sees it live. In parallel mode the worker is
        # backgrounded, multiple workers' output would interleave nonsensically,
        # so we redirect script's stdout/stderr to the per-sample log only.
        #
        # script(1) syntax differs between BSD (macOS) and util-linux (Linux):
        #   - BSD:        script [-q] file command args...
        #   - util-linux: script [-q] -c "command args..." file
        # The BSD form fails on Linux because GNU getopt parses harbor's flags
        # (e.g. -p) as script's own options. Pick the form per OS.
        # Optional agent kwargs forwarded to harbor's claude-code agent. Only
        # applied when the victim is claude-code; harbor's other agents don't
        # take a `version` kwarg.
        local extra_ak=()
        if [ "$AGENT" = "claude-code" ] && [ -n "${CLAUDE_CODE_VERSION:-}" ]; then
            extra_ak+=(--ak "version=$CLAUDE_CODE_VERSION")
        fi
        # gemini-cli accepts a `reasoning_effort` kwarg (minimal/low/medium/high
        # for Gemini 3 Flash; low/high only for Pro). Forward it when set so
        # eval_command_gemini.sh can sweep effort levels without touching this
        # script.
        if [ "$AGENT" = "gemini-cli" ] && [ -n "${GEMINI_REASONING_EFFORT:-}" ]; then
            extra_ak+=(--ak "reasoning_effort=$GEMINI_REASONING_EFFORT")
        fi
        # Optional bind mounts forwarded to harbor as --mounts-json. Used by
        # eval_command_gemini.sh to plumb the host's gcloud ADC file into the
        # victim container so the gemini-cli agent can hit Vertex AI.
        local mounts_json="${NL_HARNESS_MOUNTS_JSON:-}"
        # gemini-cli session capture workaround: harbor's post-run hook greps
        # for `session-*.json` but gemini-cli writes `session-*.jsonl` one dir
        # deeper, so the trajectory never makes it out of the container. Bind
        # mount /root/.gemini/tmp to a per-sample host dir so the JSONL
        # surfaces on the host, then _convert_gemini_session.py (post-run,
        # below) wraps it into the {sessionId, messages: [...]} shape harbor's
        # downstream converter expects. Pure in-repo workaround — no harbor
        # patch needed.
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
        # Extra environment variables forwarded into the agent container via
        # harbor's --agent-env (short: --ae). Used by OpenRouter-backed agents
        # (opencode + any other LiteLLM-style agent) so OPENROUTER_API_KEY
        # reaches the in-container runtime.
        local extra_env_args=()
        if [[ "$MODEL" == openrouter/* ]] && [ -n "${OPENROUTER_API_KEY:-}" ]; then
            extra_env_args+=(--agent-env "OPENROUTER_API_KEY=${OPENROUTER_API_KEY}")
        fi
        # Optional harbor timeout knobs. The default env-build timeout (200s)
        # is too short for sample Dockerfiles that install heavy pip deps
        # (sentence-transformers, scipy, etc.); set NL_ENV_BUILD_TIMEOUT_MULT
        # to e.g. 5 for those. NL_TIMEOUT_MULT bumps all per-trial timeouts
        # uniformly.
        local extra_timeout_args=()
        if [ -n "${NL_TIMEOUT_MULT:-}" ]; then
            extra_timeout_args+=(--timeout-multiplier "$NL_TIMEOUT_MULT")
        fi
        if [ -n "${NL_ENV_BUILD_TIMEOUT_MULT:-}" ]; then
            extra_timeout_args+=(--environment-build-timeout-multiplier "$NL_ENV_BUILD_TIMEOUT_MULT")
        fi
        # script(1) is still needed for the pty (harbor uses rich/spinner output
        # that breaks without a tty), but the typescript file is discarded
        # via /dev/null — the per-sample harbor.log we used to write here was
        # multi-MB of ANSI escape spam nobody ever reads, and we already have
        # the structured per-trial transcript under jobs/.
        local script_run
        if [ "$(uname -s)" = "Darwin" ]; then
            script_run=(script -q /dev/null harbor run -p "$sample_rel" -a "$AGENT" -m "$MODEL" "${extra_ak[@]}" "${extra_mounts[@]}" "${extra_env_args[@]}" "${extra_timeout_args[@]}" -y -o "$sample_jobs_dir")
        else
            local harbor_cmd
            harbor_cmd=$(printf '%q ' harbor run -p "$sample_rel" -a "$AGENT" -m "$MODEL" "${extra_ak[@]}" "${extra_mounts[@]}" "${extra_env_args[@]}" "${extra_timeout_args[@]}" -y -o "$sample_jobs_dir")
            script_run=(script -q -c "$harbor_cmd" /dev/null)
        fi
        if [ "$parallel_mode" = "1" ]; then
            "${script_run[@]}" </dev/null || true
        else
            "${script_run[@]}" </dev/null >/dev/null 2>&1 || true
        fi

        # Latest-job lookup is now race-free: each sample owns its own jobs dir.
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

    # asr_result.json lives at verifier/asr_result.json for eval runs (where
    # run_asr_evaluator.py writes /logs/verifier/asr_result.json directly), but
    # at verifier/output/asr_result.json for generator runs (where the agent
    # writes to /root/output/). Try both so this script works in either case.
    # OR-chain instead of a for-loop to dodge any subtle set -e + if + break
    # edge case that previously caused this cp to silently get skipped.
    cp "$job/verifier/asr_result.json"        "$eval_dir/asr_result.json" 2>/dev/null \
        || cp "$job/verifier/output/asr_result.json" "$eval_dir/asr_result.json" 2>/dev/null \
        || true
    [ -f "$job/verifier/reward.txt" ]              && cp "$job/verifier/reward.txt"           "$eval_dir/reward.txt"
    [ -f "$job/result.json" ]                      && cp "$job/result.json"                   "$eval_dir/result.json"
    [ -f "$job/agent/claude-code.txt" ]            && cp "$job/agent/claude-code.txt"         "$eval_dir/claude-code.txt"
    [ -f "$job/agent/codex.txt" ]                  && cp "$job/agent/codex.txt"               "$eval_dir/codex.txt"
    [ -f "$job/agent/gemini-cli.txt" ]             && cp "$job/agent/gemini-cli.txt"          "$eval_dir/gemini-cli.txt"
    [ -f "$job/agent/opencode.txt" ]               && cp "$job/agent/opencode.txt"            "$eval_dir/opencode.txt"
    # gemini-cli trajectory: harbor's post-run hook is broken for --prompt
    # mode (greps session-*.json, gemini writes session-*.jsonl). We surface
    # the JSONL via a bind mount above, then convert it here in-repo. Also
    # drop a copy into the harbor job dir so calculate_cost.py (which keys
    # off $job/agent/gemini-cli.trajectory.json) can read tokens from it.
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

    # If harbor finished but no asr_result.json materialized (e.g. environment
    # setup crashed before tests/test.sh ran — common with the 19 networked
    # samples whose generator-baked ENTRYPOINT wrapping breaks docker-compose
    # detach mode), mark as aborted so resume doesn't retry forever.
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
# Worker pool: cap concurrent samples at $PARALLEL.
# Polls a tracked PID list every 1s — works on bash 3.2 (macOS default).
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
# Read the combos list off file descriptor 3 instead of stdin (fd 0). When the
# loop body backgrounds process_sample (which wraps harbor in script(1), and
# script's pty master reads from its stdin), we must not let those subprocesses
# inherit fd 0 from the loop — otherwise script consumes lines from the
# here-string and the loop terminates after only a few iterations. fd 3 keeps
# the loop's input isolated; subprocesses inherit fd 0 (terminal / /dev/null)
# without affecting the read.
while IFS=$'\t' read -r task slug risk generator sample_id sample_dir <&3; do
    [ -z "$task" ] && continue
    eval_dir="$RESULTS_DIR/$task/$slug/$risk/outputs/$generator/evals/$VICTIM_ID/$sample_id"
    if [ -f "$eval_dir/asr_result.json" ] || [ -f "$eval_dir/aborted.json" ]; then
        continue
    fi

    # Throttle.
    while prune_done; [ "${#PIDS[@]}" -ge "$PARALLEL" ]; do
        sleep 1
        prune_done
    done

    LAUNCHED=$((LAUNCHED + 1))
    echo "[launch $LAUNCHED/$TODO] $task / $risk / $sample_id"
    if [ "$PARALLEL" = "1" ]; then
        # Run inline so the user sees harbor's live pty stream on the terminal.
        process_sample "$task" "$slug" "$risk" "$generator" "$sample_id" "$sample_dir" 1
    else
        process_sample "$task" "$slug" "$risk" "$generator" "$sample_id" "$sample_dir" 0 &
        PIDS+=($!)
    fi
done 3<<< "$COMBOS_TSV"

# Wait for any backgrounded workers.
wait

# --- Rebuild the per-task aggregate summary across every completed eval ---
python3 - "$RESULTS_DIR" "$VICTIM_ID" <<'PY'
import json, os, sys
from collections import defaultdict
from pathlib import Path

results_dir = Path(sys.argv[1])
victim_id   = sys.argv[2]

per_task = defaultdict(lambda: {
    "victim_agent_id": victim_id,
    "samples": [],
    "by_realization": defaultdict(lambda: [0, 0]),
    "by_risk":        defaultdict(lambda: [0, 0]),
    "by_generator":   defaultdict(lambda: [0, 0]),
})

for asr_path in results_dir.rglob(f"evals/{victim_id}/*/asr_result.json"):
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

    manifest_path = asr_path.parents[3] / "manifest.json"
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
    out = results_dir / task / f"eval_summary_{victim_id}.json"
    out.write_text(json.dumps(bucket, indent=2, default=list))
    print(f"  Wrote {out}: {s}/{n} ASR={bucket['overall']['asr']:.3f}")
PY

RUN_END=$(date +%s)
TOTAL_ELAPSED=$((RUN_END - RUN_START))
HOURS=$((TOTAL_ELAPSED / 3600))
MINS=$(( (TOTAL_ELAPSED % 3600) / 60 ))

echo ""
echo "=========================================="
echo "  nl_harness EVAL COMPLETE"
echo "=========================================="
echo "  Victim:    $AGENT ($MODEL_SHORT)"
echo "  Parallel:  $PARALLEL"
echo "  Time:      ${HOURS}h ${MINS}m"
echo "  Finished:  $(date)"
echo "=========================================="

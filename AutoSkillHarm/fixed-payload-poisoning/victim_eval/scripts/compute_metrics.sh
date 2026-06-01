#!/bin/bash
# Compute per-sample post-hoc metrics (conditional ASR, injection identify,
# injection refuse) for a victim agent's already-completed eval runs. Walks
# the same results tree eval.sh writes to and emits one
# `metrics_result.json` per sample plus a per-task aggregate.
#
# Usage:
#   bash compute_metrics.sh <victim_agent_id> [--judge-model MODEL] [--no-judge]
#
# <victim_agent_id> follows eval.sh's naming convention, e.g.:
#   claude_claude-sonnet-4-6
#   codex_gpt-5.4
#   gemini-cli_gemini-3-flash-preview
#
# The same NL_* filtering env vars eval.sh reads work here:
#   NL_TASKS         — comma-separated task ids
#   NL_RISKS         — comma-separated risk ids
#   NL_TARGETS       — injection target paths
#   NL_GENERATOR     — generator output dir (e.g. claude_claude-opus-4-7)
#   NL_REALIZATIONS  — realizations
#   NL_KEEP_ONLY     — "1" → only score samples whose
#                      <risk>/filter/<generator>/filter_result.json verdict is
#                      "keep" (samples lacking a filter_result.json are skipped).
#                      Mirrors eval.sh; use to scope post-hoc metrics to the
#                      static_attack_filter's kept set.
#   NL_SAMPLE_LIST   — path to a 4-col TSV (task<TAB>slug<TAB>risk<TAB>sample_id;
#                      '#'-prefixed and blank lines ignored). When set, only
#                      samples whose tuple appears in the file are scored.
#                      Pair with `jq` over the previous run's
#                      eval_summary_metrics_<victim>.json:judge_failures to
#                      retry just the failed rows under a different judge.
#   NL_HARNESS_PARALLEL — concurrent samples (default 8; bump for more throughput)
#   NL_RESULTS_DIR   — relative to repo root (default fixed-payload-poisoning/results)
#   NL_FORCE         — "1" to overwrite existing metrics_result.json
#   NL_NO_JUDGE      — "1" to skip the LLM judge (deterministic flags only)
#   NL_JUDGE_MODEL   — judge model id (default gpt-5.5)
#
# Auth: requires OPENAI_API_KEY and OPENAI_BASE_URL to be exported by the
# caller. Sourcing eval_command_codex.sh / scanner_detection's auth helper
# beforehand is the usual path. We don't ship default values to keep keys
# out of the repo.

set -e

if [ -z "${OPENAI_API_KEY:-}" ] || [ -z "${OPENAI_BASE_URL:-}" ]; then
    echo "ERROR: OPENAI_API_KEY and OPENAI_BASE_URL must be exported before running this script." >&2
    echo "       (e.g. source fixed-payload-poisoning/victim_eval/scripts/eval_command_codex.sh first)" >&2
    exit 1
fi

VICTIM_ID="${1:-}"
if [ -z "$VICTIM_ID" ]; then
    echo "Usage: bash compute_metrics.sh <victim_agent_id>"
    echo "Example: bash compute_metrics.sh claude_claude-sonnet-4-6"
    exit 1
fi
shift

JUDGE_MODEL="${NL_JUDGE_MODEL:-gpt-5.5}"
NO_JUDGE_FLAG=""
FORCE_FLAG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --judge-model) JUDGE_MODEL="$2"; shift 2;;
        --no-judge)    NO_JUDGE_FLAG="--no-judge"; shift;;
        --force)       FORCE_FLAG="--force"; shift;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

[ "${NL_NO_JUDGE:-}" = "1" ] && NO_JUDGE_FLAG="--no-judge"
[ "${NL_FORCE:-}" = "1" ] && FORCE_FLAG="--force"

PARALLEL="${NL_HARNESS_PARALLEL:-8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(dirname "$SCRIPT_DIR")"
REPO="$(cd "$HARNESS_DIR/.." && pwd)"

RESULTS_DIR_REL="${NL_RESULTS_DIR:-fixed-payload-poisoning/results}"
if [[ "$RESULTS_DIR_REL" = /* ]]; then
    echo "ERROR: NL_RESULTS_DIR must be relative to skillsbench/, got: $RESULTS_DIR_REL" >&2
    exit 1
fi
RESULTS_DIR="$REPO/$RESULTS_DIR_REL"

# --- Validate optional sample-list filter (mirror eval.sh) ---
if [ -n "${NL_SAMPLE_LIST:-}" ] && [ ! -f "$NL_SAMPLE_LIST" ]; then
    echo "ERROR: NL_SAMPLE_LIST=$NL_SAMPLE_LIST does not exist" >&2
    exit 1
fi

# --- Build sample list ---
COMBOS=""
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
                evals_dir="$gen_dir/evals/$VICTIM_ID"
                [ -d "$evals_dir" ] || continue
                for sample_dir in "$evals_dir"/*/; do
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
                    COMBOS+="$sample_dir"$'\n'
                done
            done
        done
    done
done
shopt -u nullglob

TOTAL=$(echo -n "$COMBOS" | grep -c '^' || echo 0)
if [ "$TOTAL" -eq 0 ]; then
    echo "ERROR: no eval samples matched the filters for victim=$VICTIM_ID"
    echo "  NL_TASKS=${NL_TASKS:-(any)}  NL_RISKS=${NL_RISKS:-(any)}  NL_GENERATOR=${NL_GENERATOR:-(any)}"
    exit 1
fi

echo "=========================================="
echo "  nl_harness: post-hoc metrics computation"
echo "  Victim: $VICTIM_ID"
echo "  Judge:  ${NO_JUDGE_FLAG:-$JUDGE_MODEL}"
echo "  Force:  ${FORCE_FLAG:-no}"
[ "${NL_KEEP_ONLY:-}" = "1" ] && echo "  Filter: NL_KEEP_ONLY=1 (only filter_result.json verdict=keep)"
[ -n "${NL_SAMPLE_LIST:-}" ] && echo "  Sample list: $NL_SAMPLE_LIST"
echo "  Parallel: $PARALLEL  |  Samples: $TOTAL"
echo "=========================================="

cd "$REPO"

run_one() {
    local sample_dir="$1"
    local idx="$2"
    local total="$3"
    python3 -m nl_harness.eval.metrics.compute_sample \
        --eval-dir "$sample_dir" \
        --judge-model "$JUDGE_MODEL" \
        $NO_JUDGE_FLAG $FORCE_FLAG 2>&1 | sed "s|^|  [$idx/$total ${sample_dir##*/evals/$VICTIM_ID/}] |"
}

PIDS=()
prune_done() {
    local new=()
    for p in "${PIDS[@]}"; do
        if kill -0 "$p" 2>/dev/null; then new+=("$p"); fi
    done
    PIDS=("${new[@]}")
}

LAUNCHED=0
while IFS= read -r sample_dir <&3; do
    [ -z "$sample_dir" ] && continue
    while prune_done; [ "${#PIDS[@]}" -ge "$PARALLEL" ]; do
        sleep 0.5
        prune_done
    done
    LAUNCHED=$((LAUNCHED + 1))
    if [ "$PARALLEL" = "1" ]; then
        run_one "$sample_dir" "$LAUNCHED" "$TOTAL"
    else
        run_one "$sample_dir" "$LAUNCHED" "$TOTAL" &
        PIDS+=($!)
    fi
done 3<<< "$COMBOS"

wait

echo ""
echo "=========================================="
echo "  Aggregating per-task summaries..."
echo "=========================================="
python3 -m nl_harness.eval.metrics.aggregate "$VICTIM_ID" \
    --results-dir "$RESULTS_DIR"

echo ""
echo "Done."

#!/usr/bin/env python3
"""Compute extra metrics (conditional ASR, identify, refuse) for one
already-evaluated sample. Writes `metrics_result.json` next to the existing
`asr_result.json` under the sample's eval dir.

Inputs (paths inferred from the eval dir):

    <eval_dir>/                              ← e.g. .../evals/<victim>/<sample_id>/
      asr_result.json                        ← read; ASR pulled from here
      job/agent/{trajectory.json, gemini-cli.trajectory.json}
                                              ← read; victim's trajectory
    <generator_outputs>/manifest.json        ← read; locate manifest entry by sample_id
    <generator_outputs>/attacker_goal.json   ← read; attacker goal text
    <sample_dir>/instruction.md              ← read; benign instruction

The script writes:

    <eval_dir>/metrics_result.json           ← the new artifact

It exits 0 on every well-defined outcome (including "no trajectory file";
that case still writes a metrics_result.json with `error_kind` set so the
aggregator can distinguish "not yet computed" from "could not compute").
Exits non-zero only on unexpected bugs.

Usage:
    python -m nl_harness.eval.metrics.compute_sample \
        --eval-dir <path>                    # absolute or repo-relative
        [--judge-model gpt-5.5]
        [--no-judge]                         # deterministic flags only
        [--force]                            # ignore existing metrics_result.json

Resume policy: an existing metrics_result.json normally short-circuits the
run, but a stored result whose error_kind starts with "judge_" (a judge call
that errored out — cyber_policy refusal, HTTP failure, etc.) is retried
automatically so transient failures don't get baked in. Use --no-judge to
suppress retries, or hand-delete the file for a per-sample force.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import traceback
from pathlib import Path

from .judge_client import JudgeClient
from .judge_prompts import JUDGE_OUTPUT_SCHEMA, build_judge_prompt
from .traj_normalize import load_trajectory, trajectory_to_text


REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_JUDGE_MODEL = "gpt-5.5"


def main() -> int:
    args = _parse_args()
    eval_dir = _resolve_path(args.eval_dir)
    if not eval_dir.is_dir():
        print(f"ERROR: eval dir does not exist: {eval_dir}", file=sys.stderr)
        return 2

    out_path = eval_dir / "metrics_result.json"
    if out_path.is_file() and not args.force:
        # Resume by default — but a stored metrics_result with a judge error
        # (e.g. cyber_policy refusal, transient HTTP failure) carries no
        # judge verdict, so honoring that as a "done" sample would lock in
        # the failure forever. Re-run those automatically. Pass --no-judge
        # to skip them, or hand-delete the file to opt out per-sample.
        try:
            prior = json.loads(out_path.read_text())
        except Exception:
            prior = {}
        prior_err = prior.get("error_kind") or ""
        if not prior_err.startswith("judge_") or args.no_judge:
            # Silent skip — the bash wrapper prefixes every line with
            # [idx/total sample_id], so 600+ "SKIP" lines bury the
            # actually-interesting RETRY / OK / ERR output. Counted in the
            # post-run summary instead (see compute_metrics.sh tail).
            return 0
        # Fall through to recompute; print a hint so the run log is honest
        # about what happened.
        print(f"RETRY (prior error_kind={prior_err})")

    try:
        result = _compute(eval_dir, args)
    except Exception as e:
        result = {
            "sample_id": eval_dir.name,
            "error_kind": "exception",
            "error": f"{type(e).__name__}: {e}",
            "traceback": traceback.format_exc(),
        }

    # Atomic write: write the new metrics_result.json to a temp sibling
    # then `os.replace` it onto the final path. Avoids leaving a corrupted
    # partial file behind if the process is interrupted mid-write — which
    # would otherwise force a `--force` re-run to recover.
    tmp_path = out_path.with_suffix(".json.tmp")
    tmp_path.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    os.replace(tmp_path, out_path)
    print(_summary_line(result))
    return 0


def _summary_line(result: dict) -> str:
    """One-line per-sample summary for the run log. Compact so the bash
    wrapper's [<sample_id>/] sed prefix doesn't get drowned out."""
    err = result.get("error_kind")
    if err:
        kind = "WARN" if err.startswith("judge_") else "ERR"
        return f"{kind} err={err}"

    def yn(v): return "T" if v is True else ("F" if v is False else "?")
    asr   = yn(result.get("asr_success"))
    cond  = yn(result.get("condition_met"))
    ident = yn(result.get("identified"))
    refuse = yn(result.get("refusal"))
    return f"OK asr={asr} cond={cond} id={ident} ref={refuse}"


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--eval-dir", required=True, help="Path to .../evals/<victim>/<sample_id>/")
    p.add_argument("--judge-model", default=DEFAULT_JUDGE_MODEL)
    p.add_argument("--no-judge", action="store_true",
                   help="Skip the LLM judge; emit only deterministic flags")
    p.add_argument("--force", action="store_true",
                   help="Overwrite existing metrics_result.json")
    return p.parse_args()


def _resolve_path(p: str) -> Path:
    path = Path(p)
    if path.is_absolute():
        return path
    return (REPO_ROOT / path).resolve()


def _compute(eval_dir: Path, args: argparse.Namespace) -> dict:
    sample_id = eval_dir.name

    # Walk up the eval tree to find the generator outputs dir. Layout:
    #   .../<task>/<slug>/<risk>/outputs/<generator>/evals/<victim>/<sample_id>/
    generator_dir = eval_dir.parent.parent.parent
    generator = generator_dir.name
    victim = eval_dir.parent.name

    # The risk / slug / task are the next three ancestors above outputs/.
    outputs_parent = generator_dir.parent  # /<risk>/outputs
    risk_dir = outputs_parent.parent
    risk = risk_dir.name
    slug = risk_dir.parent.name
    task = risk_dir.parent.parent.name

    manifest_path = generator_dir / "manifest.json"
    attacker_goal_path = generator_dir / "attacker_goal.json"
    sample_dir = generator_dir / "samples" / sample_id

    # ASR carry-over
    asr_path = eval_dir / "asr_result.json"
    asr_success = None
    if asr_path.is_file():
        try:
            with asr_path.open() as f:
                asr_success = bool(json.load(f).get("asr_success"))
        except Exception:
            asr_success = None

    # If the sample aborted (no harbor job produced anything), there's no
    # trajectory to score. Emit a structured no-op record.
    aborted_path = eval_dir / "aborted.json"
    if aborted_path.is_file() and not (eval_dir / "job").exists():
        return {
            "sample_id": sample_id,
            "task_id": task, "slug": slug, "risk_id": risk,
            "generator": generator, "victim_agent_id": victim,
            "asr_success": asr_success,
            "error_kind": "aborted_no_trajectory",
        }

    # Manifest entry
    manifest_entry = _find_manifest_entry(manifest_path, sample_id)
    if manifest_entry is None:
        return {
            "sample_id": sample_id,
            "task_id": task, "slug": slug, "risk_id": risk,
            "generator": generator, "victim_agent_id": victim,
            "asr_success": asr_success,
            "error_kind": "manifest_entry_missing",
        }

    # Attacker goal
    if not attacker_goal_path.is_file():
        return {
            "sample_id": sample_id,
            "task_id": task, "slug": slug, "risk_id": risk,
            "generator": generator, "victim_agent_id": victim,
            "asr_success": asr_success,
            "error_kind": "attacker_goal_missing",
        }
    with attacker_goal_path.open() as f:
        attacker_goal = json.load(f)

    # Trajectory. load_trajectory dispatches by which file is present in
    # eval_dir: claude-code.txt → claude, codex.txt → codex,
    # opencode.txt → opencode, gemini-cli.trajectory.json → gemini.
    # Falls back to job/agent/trajectory.json for old eval dirs that
    # predate eval.sh's cp-into-eval-dir logic.
    traj = load_trajectory(eval_dir)
    if traj is None or not traj.steps:
        return {
            "sample_id": sample_id,
            "task_id": task, "slug": slug, "risk_id": risk,
            "generator": generator, "victim_agent_id": victim,
            "asr_success": asr_success,
            "error_kind": "trajectory_missing_or_empty",
        }

    spec = _spec_from_manifest(manifest_entry)

    # Instruction (for judge context)
    instruction_text = ""
    instr_path = sample_dir / "instruction.md"
    if instr_path.is_file():
        try:
            instruction_text = instr_path.read_text(encoding="utf-8")
        except Exception:
            instruction_text = ""

    # Build the metrics record. All access/identify/refusal flags come from
    # the LLM judge — the old rule-based detector was removed because the
    # judge already supersedes its signals (see judge_prompts.py).
    out: dict = {
        "sample_id": sample_id,
        "task_id": task, "slug": slug, "risk_id": risk,
        "generator": generator, "victim_agent_id": victim,
        "agent_family": traj.agent_family,
        "victim_model": traj.model_name,
        "realization": spec["realization"],
        "carrier_path": spec["carrier_path"],
        "payload_path": spec["payload_path"],
        "payload_kind": spec["payload_kind"],
        "asr_success": asr_success,

        # Judge fields — None when --no-judge or the judge call failed;
        # consumers must treat None as "unjudged", not False. condition_met
        # is just an alias for use_target_file (kept for back-compat).
        "enter_entry_point": None,
        "use_target_file": None,
        "condition_met": None,
        "identified": None,
        "refusal": None,
        "judge": None,
        "error_kind": None,
    }

    if args.no_judge:
        return out

    # LLM judge
    try:
        client = JudgeClient(model=args.judge_model)
    except Exception as e:
        out["error_kind"] = "judge_unavailable"
        out["judge"] = {"error": str(e)}
        return out

    traj_text = trajectory_to_text(traj)
    system_prompt, user_prompt = build_judge_prompt(
        instruction=instruction_text,
        attacker_goal=attacker_goal.get("goal", "") or "",
        trajectory_text=traj_text,
        carrier_path=spec["carrier_path"],
        payload_path=spec["payload_path"],
    )

    t0 = time.time()
    try:
        # schema_hint just nudges the cache key when prompts evolve; the
        # actual schema is enforced via Structured Outputs (json_schema)
        # so the model can't return malformed JSON or wrong-typed fields.
        resp = client.judge(
            system_prompt,
            user_prompt,
            schema_hint="enter+use+identified+refusal v4 structured",
            json_schema=JUDGE_OUTPUT_SCHEMA,
        )
    except Exception as e:
        out["error_kind"] = "judge_call_failed"
        out["judge"] = {"error": f"{type(e).__name__}: {e}"}
        return out
    judge_seconds = time.time() - t0

    # Strict json_schema guarantees every key is present with the right
    # type — read fields directly off resp.parsed without coercion.
    judged = resp.parsed
    out["enter_entry_point"] = judged["enter_entry_point"]
    out["use_target_file"] = judged["use_target_file"]
    out["condition_met"] = judged["use_target_file"]
    out["identified"] = judged["identified"]
    out["refusal"] = judged["refusal"]
    out["judge"] = {
        "model": resp.model,
        "cached": resp.cached,
        "prompt_tokens": resp.prompt_tokens,
        "completion_tokens": resp.completion_tokens,
        "latency_sec": round(judge_seconds, 2),
        "enter_entry_point_reason": judged["enter_entry_point_reason"],
        "use_target_file_reason": judged["use_target_file_reason"],
        "identified_reason": judged["identified_reason"],
        "refusal_reason": judged["refusal_reason"],
    }
    return out


def _spec_from_manifest(manifest_entry: dict) -> dict:
    """Pull just the carrier/payload metadata the judge prompt needs.
    Replaces the old target_access.derive_target_spec() — we no longer need
    skill-relative path tracking now that the rule-based detector is gone.
    """
    realization = manifest_entry["realization"]
    carrier = manifest_entry["target_task_relative_path"]
    added = manifest_entry.get("added_artifacts") or []

    payload_rel: str | None = None
    payload_kind = "carrier_self"
    if added:
        payload_rel = added[0]["task_relative_path"]
        ext = os.path.splitext(payload_rel)[1].lower()
        if realization == "redirect_to_new_pdf" or ext == ".pdf":
            payload_kind = "pdf"
        elif realization == "redirect_to_new_script":
            payload_kind = "script"
        elif realization == "import_new_helper":
            payload_kind = "helper"
        elif realization == "redirect_to_new_doc":
            payload_kind = "doc"
        elif ext in (".py", ".sh", ".bash", ".js", ".mjs", ".ts", ".rb", ".pl"):
            payload_kind = "script"
        else:
            payload_kind = "doc"

    return {
        "realization": realization,
        "carrier_path": carrier,
        "payload_path": payload_rel,
        "payload_kind": payload_kind,
    }


def _find_manifest_entry(manifest_path: Path, sample_id: str) -> dict | None:
    if not manifest_path.is_file():
        return None
    try:
        with manifest_path.open() as f:
            data = json.load(f)
    except Exception:
        return None
    for e in data:
        if e.get("sample_id") == sample_id:
            return e
    return None


if __name__ == "__main__":
    sys.exit(main())

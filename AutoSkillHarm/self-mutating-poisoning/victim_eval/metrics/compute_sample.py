#!/usr/bin/env python3
"""Compute metrics (conditional ASR, identify, refuse) for one eval sample.

Adapted from fixed-payload-poisoning/victim_eval/eval/metrics/compute_sample.py for the dynamic
cross-task attack setting.

Usage:
    python -m dynamic.attack_design.metrics.compute_sample \
        --eval-dir task_pairs/<pair>/<risk>/eval/designer_<d>/runner_<r> \
        [--judge-model gpt-5.5] [--no-judge] [--force]

Writes metrics_result.json into the eval dir.
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
DEFAULT_JUDGE_MODEL = "gpt-5.4"


def main() -> int:
    args = _parse_args()
    eval_dir = _resolve_path(args.eval_dir)
    if not eval_dir.is_dir():
        print(f"ERROR: eval dir does not exist: {eval_dir}", file=sys.stderr)
        return 2

    out_path = eval_dir / "metrics_result.json"
    if out_path.is_file() and not args.force:
        try:
            prior = json.loads(out_path.read_text())
        except Exception:
            prior = {}
        prior_err = prior.get("error_kind") or ""
        if not prior_err.startswith("judge_") or args.no_judge:
            return 0
        print(f"RETRY (prior error_kind={prior_err})")

    try:
        result = _compute(eval_dir, args)
    except Exception as e:
        result = {
            "eval_dir": str(eval_dir),
            "error_kind": "exception",
            "error": f"{type(e).__name__}: {e}",
            "traceback": traceback.format_exc(),
        }

    tmp_path = out_path.with_suffix(".json.tmp")
    tmp_path.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    os.replace(tmp_path, out_path)
    print(_summary_line(result))
    return 0


def _summary_line(result: dict) -> str:
    err = result.get("error_kind")
    if err:
        kind = "WARN" if err.startswith("judge_") else "ERR"
        return f"{kind} err={err}"

    def yn(v):
        return "T" if v is True else ("F" if v is False else "?")
    asr = yn(result.get("asr_success"))
    cond = yn(result.get("condition_met"))
    ident = yn(result.get("identified"))
    refuse = yn(result.get("refusal"))
    return f"OK asr={asr} cond={cond} id={ident} ref={refuse}"


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--eval-dir", required=True)
    p.add_argument("--judge-model", default=DEFAULT_JUDGE_MODEL)
    p.add_argument("--no-judge", action="store_true")
    p.add_argument("--force", action="store_true")
    return p.parse_args()


def _resolve_path(p: str) -> Path:
    path = Path(p)
    if path.is_absolute():
        return path
    return (REPO_ROOT / path).resolve()


def _compute(eval_dir: Path, args: argparse.Namespace) -> dict:
    # Parse path structure:
    # .../task_pairs/<pair>/<risk>/eval/designer_<designer>/runner_<runner>/
    runner_name = eval_dir.name.removeprefix("runner_")
    designer_name = eval_dir.parent.name.removeprefix("designer_")
    # eval_dir.parent = designer_X, .parent = eval/, .parent = <risk>, .parent = <pair>
    risk = eval_dir.parent.parent.parent.name
    pair = eval_dir.parent.parent.parent.parent.name

    # Load eval_result.json for ASR
    eval_result_path = eval_dir / "eval_result.json"
    asr_success = None
    if eval_result_path.is_file():
        try:
            er = json.load(eval_result_path.open())
            asr_success = er.get("attack_successful", False)
        except Exception:
            pass

    # Load attack design for attacker goal and modified files
    design_dir = eval_dir.parent.parent.parent / "outputs" / designer_name
    design_path = design_dir / "attack_design.json"
    if not design_path.is_file():
        return {
            "pair": pair, "risk_type": risk,
            "design_agent_id": designer_name, "runner_agent_id": runner_name,
            "asr_success": asr_success,
            "error_kind": "attack_design_missing",
        }

    with design_path.open() as f:
        design = json.load(f)

    attacker_goal = design.get("risk_behavior", "")
    modified_files = design.get("modified_files", [])

    # Determine carrier (entry point) and payload paths
    carrier_path, payload_path = _derive_carrier_payload(modified_files)

    # Load Task B instruction
    pair_dir = REPO_ROOT / "dynamic" / "task_pairs" / pair
    instruction_path = pair_dir / "task_b" / "instruction.md"
    instruction = ""
    if instruction_path.is_file():
        instruction = instruction_path.read_text(errors="ignore")

    # Load trajectory
    traj = load_trajectory(eval_dir)
    if traj is None or not traj.steps:
        return {
            "pair": pair, "risk_type": risk,
            "design_agent_id": designer_name, "runner_agent_id": runner_name,
            "asr_success": asr_success,
            "error_kind": "trajectory_missing_or_empty",
        }

    traj_text = trajectory_to_text(traj)

    # Build result
    out: dict = {
        "pair": pair,
        "risk_type": risk,
        "design_agent_id": designer_name,
        "runner_agent_id": runner_name,
        "agent_family": traj.agent_family,
        "victim_model": traj.model_name,
        "asr_success": asr_success,
        "carrier_path": carrier_path,
        "payload_path": payload_path,
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

    system_prompt, user_prompt = build_judge_prompt(
        instruction=instruction,
        attacker_goal=attacker_goal,
        trajectory_text=traj_text,
        carrier_path=carrier_path,
        payload_path=payload_path,
    )

    t0 = time.time()
    try:
        resp = client.judge(
            system_prompt, user_prompt,
            schema_hint="enter+use+identified+refusal v4 structured",
            json_schema=JUDGE_OUTPUT_SCHEMA,
        )
    except Exception as e:
        out["error_kind"] = "judge_call_failed"
        out["judge"] = {"error": f"{type(e).__name__}: {e}"}
        return out
    judge_seconds = time.time() - t0

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


def _derive_carrier_payload(modified_files: list[str]) -> tuple[str, str]:
    """Determine carrier (entry point) and payload from modified_files list.

    Heuristic matching the dynamic attack design convention:
    - Entry point: SKILL.md if present, otherwise first file
    - Payload: first script (.py/.sh) if different from carrier, else same as carrier
    """
    if not modified_files:
        return "", ""

    # Find SKILL.md as carrier (entry point) — attack designs put instructions there
    skill_mds = [f for f in modified_files if f.endswith("SKILL.md")]
    carrier = skill_mds[0] if skill_mds else modified_files[0]

    # Find payload script (the file that actually executes the malicious behavior)
    scripts = [f for f in modified_files if f != carrier and (
        "/scripts/" in f or f.endswith((".py", ".sh", ".js"))
    )]
    payload = scripts[0] if scripts else carrier

    return carrier, payload


if __name__ == "__main__":
    sys.exit(main())

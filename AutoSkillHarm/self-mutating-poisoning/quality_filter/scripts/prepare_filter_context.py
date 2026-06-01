#!/usr/bin/env python3
"""
Assemble the attack_filter environment for a specific (pair, risk_type, design_agent_id).

Usage:
    python prepare_filter_context.py --pair X --risk Y --designer Z [--env-dir DIR]
"""

import argparse
import json
import shutil
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Prepare attack_filter environment")
    parser.add_argument("--pair", required=True)
    parser.add_argument("--risk", required=True)
    parser.add_argument("--designer", required=True, help="Design agent ID (e.g., codex_gpt-5.4)")
    parser.add_argument("--env-dir", default=None, help="Override environment directory")
    parser.add_argument("--runners", default=None,
                        help="Comma-separated runner IDs to include (e.g., codex_gpt-5.4,claude_claude-sonnet-4-6). Default: all available.")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    filter_dir = script_dir.parent
    dynamic_dir = filter_dir.parent
    pairs_dir = dynamic_dir / "task_pairs"
    env_dir = Path(args.env_dir) if args.env_dir else filter_dir / "environment"

    pair_dir = pairs_dir / args.pair
    risk_dir = pair_dir / args.risk
    design_dir = risk_dir / "outputs" / args.designer

    # Validate
    if not design_dir.is_dir():
        print(f"ERROR: Design directory not found: {design_dir}")
        return 1

    # Check metadata consistency (designer agent may have targeted wrong pair/risk)
    ad_src = design_dir / "attack_design.json"
    if ad_src.is_file():
        with open(ad_src) as f:
            ad_check = json.load(f)
        design_pair = ad_check.get("pair", "")
        design_risk = ad_check.get("risk_type", "")
        if design_pair != args.pair or design_risk != args.risk:
            print(f"MISMATCH: design targets {design_pair}/{design_risk} but stored at {args.pair}/{args.risk}")
            # Exit code 2 = metadata mismatch, caller should auto-discard
            return 2

    # 1. Copy attack design artifacts (critical — Docker COPY will fail without these)
    for f in ["attack_design.json", "test_detection.py"]:
        src = design_dir / f
        if src.is_file():
            shutil.copy2(src, env_dir / f)
        else:
            print(f"ERROR: Missing critical file {f} in {design_dir}")
            return 1

    # Inject design_agent_id into attack_design.json (not present in original)
    ad_path = env_dir / "attack_design.json"
    with open(ad_path) as f:
        ad = json.load(f)
    ad["design_agent_id"] = args.designer
    with open(ad_path, "w") as f:
        json.dump(ad, f, indent=2)

    # 1b. Copy attack designer's agent trajectory (reasoning + tool calls + outputs)
    design_traj_dst = env_dir / "design_trajectory"
    design_traj_dst.mkdir(exist_ok=True)
    for f in design_dir.iterdir():
        if f.is_file() and f.suffix in (".txt", ".json"):
            shutil.copy2(f, design_traj_dst / f.name)

    # 2. Copy modified_skills/
    mod_dst = env_dir / "modified_skills"
    if mod_dst.exists():
        shutil.rmtree(mod_dst)
    mod_src = design_dir / "modified_skills"
    if mod_src.is_dir():
        shutil.copytree(mod_src, mod_dst)
    else:
        mod_dst.mkdir(parents=True, exist_ok=True)
        print("WARNING: No modified_skills/ in design")

    # 3. Copy original shared_skills/ for diffing
    orig_dst = env_dir / "original_skills"
    if orig_dst.exists():
        shutil.rmtree(orig_dst)
    orig_src = pair_dir / "shared_skills"
    if orig_src.is_dir():
        shutil.copytree(orig_src, orig_dst)
    else:
        orig_dst.mkdir(parents=True, exist_ok=True)

    # 4. Copy pair_meta.json
    pair_meta = pair_dir / "pair_meta.json"
    if pair_meta.is_file():
        shutil.copy2(pair_meta, env_dir / "pair_meta.json")

    # 5. Copy risk_type.json
    risk_meta = risk_dir / "risk_meta.json"
    if risk_meta.is_file():
        shutil.copy2(risk_meta, env_dir / "risk_type.json")

    # 6. Copy task instructions and oracle solutions
    for role in ["task_a", "task_b"]:
        instr_src = pair_dir / role / "instruction.md"
        if instr_src.is_file():
            shutil.copy2(instr_src, env_dir / f"{role}_instruction.md")
        else:
            (env_dir / f"{role}_instruction.md").write_text(f"No instruction for {role}")

        solve_src = pair_dir / role / "solution" / "solve.sh"
        if solve_src.is_file():
            shutil.copy2(solve_src, env_dir / f"{role}_oracle_solve.sh")
        else:
            (env_dir / f"{role}_oracle_solve.sh").write_text(f"# No oracle for {role}")

    # 7. Copy Task B Dockerfile (authoritative source for available libraries)
    task_b_dockerfile = pair_dir / "task_b" / "environment" / "Dockerfile"
    if task_b_dockerfile.is_file():
        shutil.copy2(task_b_dockerfile, env_dir / "task_b_dockerfile")
    else:
        (env_dir / "task_b_dockerfile").write_text("# Task B Dockerfile not found")

    # 8. Copy baseline summary
    baseline = pair_dir / "baseline" / "summary.json"
    if baseline.is_file():
        shutil.copy2(baseline, env_dir / "baseline_summary.json")
    else:
        (env_dir / "baseline_summary.json").write_text("{}")

    # 9. Copy eval results (if any exist)
    eval_dst = env_dir / "eval_results"
    if eval_dst.exists():
        shutil.rmtree(eval_dst)
    eval_dst.mkdir()

    # Parse runner filter (comma-separated list or None for all)
    runner_filter = None
    if args.runners:
        runner_filter = set(r.strip() for r in args.runners.split(",") if r.strip())

    eval_base = risk_dir / "eval" / f"designer_{args.designer}"
    if eval_base.is_dir():
        for runner_dir in eval_base.iterdir():
            if not runner_dir.is_dir():
                continue
            # runner_dir.name is like "runner_codex_gpt-5.4"
            runner_id = runner_dir.name.replace("runner_", "", 1)
            if runner_filter and runner_id not in runner_filter:
                continue
            runner_dst = eval_dst / runner_dir.name
            runner_dst.mkdir()
            for f in runner_dir.iterdir():
                if f.is_file() and f.suffix in (".json", ".log"):
                    shutil.copy2(f, runner_dst / f.name)
            for traj_dir_name in ("task_a_trajectory", "task_b_trajectory"):
                traj_src = runner_dir / traj_dir_name
                if traj_src.is_dir():
                    traj_dst = runner_dst / traj_dir_name
                    traj_dst.mkdir(exist_ok=True)
                    for tf in traj_src.iterdir():
                        if tf.is_file() and tf.suffix in (".txt", ".json"):
                            shutil.copy2(tf, traj_dst / tf.name)

    print(f"Filter context prepared: pair={args.pair} risk={args.risk} designer={args.designer}")
    print(f"  Environment dir: {env_dir}")
    return 0


if __name__ == "__main__":
    exit(main())

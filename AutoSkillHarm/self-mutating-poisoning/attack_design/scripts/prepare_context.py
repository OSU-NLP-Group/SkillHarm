#!/usr/bin/env python3
"""
Assemble the attack_design environment for a specific (pair, risk_type) combo.

Usage:
    python prepare_context.py --pair court-form-filling__invoice-fraud-detection --risk data_exfiltration
"""

import argparse
import json
import os
import random
import shutil
from pathlib import Path

# Models to include as baseline trajectories for the attack designer
BASELINE_MODELS = ["codex-gpt-5.2", "claude-opus-4.6", "gemini-3-pro"]


def main():
    parser = argparse.ArgumentParser(description="Prepare attack_design environment")
    parser.add_argument("--pair", required=True, help="Pair directory name (e.g., court-form-filling__invoice-fraud-detection)")
    parser.add_argument("--risk", required=True, help="Risk type ID (e.g., data_exfiltration)")
    parser.add_argument("--env-dir", default=None, help="Override environment directory (for parallel isolation)")
    args = parser.parse_args()

    # Paths
    script_dir = Path(__file__).resolve().parent
    attack_design_dir = script_dir.parent
    dynamic_dir = attack_design_dir.parent
    repo_dir = dynamic_dir.parent
    pairs_dir = dynamic_dir / "task_pairs"
    baselines_dir = repo_dir / "skillsbench-trajectories" / "baselines"
    env_dir = Path(args.env_dir) if args.env_dir else attack_design_dir / "environment"

    pair_dir = pairs_dir / args.pair
    if not pair_dir.is_dir():
        print(f"ERROR: Pair directory not found: {pair_dir}")
        return 1

    risk_dir = pair_dir / args.risk
    if not risk_dir.is_dir():
        print(f"ERROR: Risk directory not found: {risk_dir}")
        return 1

    # Parse task names from pair
    parts = args.pair.split("__")
    task_a_name = parts[0]
    task_b_name = parts[1] if len(parts) > 1 else parts[0]

    # 1. Copy pair_meta.json -> pair_context.json
    pair_meta = pair_dir / "pair_meta.json"
    if pair_meta.is_file():
        shutil.copy2(pair_meta, env_dir / "pair_context.json")
    else:
        print(f"WARNING: No pair_meta.json in {pair_dir}")

    # 2. Copy risk_meta.json -> risk_type.json
    risk_meta = risk_dir / "risk_meta.json"
    if risk_meta.is_file():
        shutil.copy2(risk_meta, env_dir / "risk_type.json")
    else:
        print(f"WARNING: No risk_meta.json in {risk_dir}")

    # 3. Copy shared_skills/
    shared_src = pair_dir / "shared_skills"
    shared_dst = env_dir / "shared_skills"
    if shared_dst.exists():
        shutil.rmtree(shared_dst)
    if shared_src.is_dir():
        shutil.copytree(shared_src, shared_dst)
    else:
        shared_dst.mkdir(parents=True, exist_ok=True)
        print(f"WARNING: No shared_skills in {pair_dir}")

    # 4. Copy task instructions
    for role in ["task_a", "task_b"]:
        instr_src = pair_dir / role / "instruction.md"
        instr_dst = env_dir / f"{role}_instruction.md"
        if instr_src.is_file():
            shutil.copy2(instr_src, instr_dst)
        else:
            instr_dst.write_text(f"No instruction found for {role}")

    # 5. Generate baseline summary from official trajectories
    baseline_summary = _build_baseline_summary(baselines_dir, task_a_name, task_b_name)
    (env_dir / "baseline_summary.json").write_text(
        json.dumps(baseline_summary, indent=2), encoding="utf-8"
    )

    # 6. Copy oracle solutions
    for role in ["task_a", "task_b"]:
        solve_src = pair_dir / role / "solution" / "solve.sh"
        solve_dst = env_dir / f"{role}_oracle_solve.sh"
        if solve_src.is_file():
            shutil.copy2(solve_src, solve_dst)
        else:
            solve_dst.write_text(f"# No oracle solution found for {role}")

    # 7. Copy baseline trajectories from official skillsbench-trajectories
    traj_dir = env_dir / "baseline_trajectories"
    if traj_dir.exists():
        shutil.rmtree(traj_dir)
    traj_dir.mkdir()

    rng = random.Random(hash(args.pair + args.risk))
    traj_count = 0

    for model in BASELINE_MODELS:
        for role, task_name in [("task_a", task_a_name), ("task_b", task_b_name)]:
            task_dir = baselines_dir / model / task_name
            if not task_dir.is_dir():
                print(f"  WARNING: No baseline for {model}/{task_name}")
                continue

            # Collect available trials
            trials = sorted([
                t for t in task_dir.iterdir()
                if t.is_dir() and (t / "trajectory.txt").is_file()
            ])
            if not trials:
                print(f"  WARNING: No trials with trajectory for {model}/{task_name}")
                continue

            # Sample 1 trial
            trial = rng.choice(trials)
            reward_file = trial / "reward.txt"
            reward = reward_file.read_text().strip() if reward_file.is_file() else "?"

            dest_name = f"{role}__{model}"
            dest = traj_dir / dest_name
            dest.mkdir(exist_ok=True)

            # Copy summary.txt (preferred — concise, structured)
            summary_src = trial / "summary.txt"
            if summary_src.is_file():
                shutil.copy2(summary_src, dest / "summary.txt")

            # Copy trajectory.txt (full agent log)
            traj_src = trial / "trajectory.txt"
            shutil.copy2(traj_src, dest / "trajectory.txt")

            # Write reward
            (dest / "reward.txt").write_text(reward, encoding="utf-8")

            traj_count += 1

    print(f"Context prepared for: pair={args.pair} risk={args.risk}")
    print(f"  Environment dir: {env_dir}")
    print(f"  Baseline trajectories: {traj_count} ({len(BASELINE_MODELS)} models × 2 tasks)")
    return 0


def _build_baseline_summary(baselines_dir, task_a_name, task_b_name):
    """Build baseline_summary.json from official trajectories."""
    summary = {}
    for role, task_name in [("task_a", task_a_name), ("task_b", task_b_name)]:
        results = {}
        for model in BASELINE_MODELS:
            task_dir = baselines_dir / model / task_name
            if not task_dir.is_dir():
                continue
            rewards = []
            for trial in task_dir.iterdir():
                if not trial.is_dir():
                    continue
                rf = trial / "reward.txt"
                if rf.is_file():
                    try:
                        rewards.append(float(rf.read_text().strip()))
                    except ValueError:
                        pass
            if rewards:
                results[model] = sum(rewards) / len(rewards)
        summary[role] = {"task": task_name, "results": results}
    return summary


if __name__ == "__main__":
    exit(main())

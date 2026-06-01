#!/usr/bin/env python3
"""
Assemble the static_attack_filter environment for one (task, target_slug, risk, designer).

Reads from:
  - skillsbench/results/<task>/<target_slug>/<risk>/outputs/<designer>/   (designer artifacts + per-runner evals)
  - skillsbench/risk_taxonomy.json                                          (taxonomy entry)
  - skillsbench/tasks/<task>/                                                          (clean task: instruction, Dockerfile, owning skill)

Writes the staged environment under <env-dir> in the shape the Dockerfile COPYs into /root/.

Usage:
    python prepare_filter_context.py --task <task> --target-slug <slug> --risk <risk> --designer <id> --env-dir <dir>
"""

import argparse
import json
import shutil
from pathlib import Path


# Per-eval-sample files we copy through to the filter environment.
# - Explicit list: specific JSON metadata files we always want.
# - All `*.txt` files are also copied: each agent harness writes its transcript
#   as <agent>.txt (claude-code.txt / codex.txt / gemini.txt / etc.), and
#   verifier reward lives in reward.txt — globbing covers both, and any new
#   agent harness is picked up automatically without editing this list.
# Excludes: harbor.log (ANSI progress noise without signal), the harbor `job`
#   symlink, and any other transient file not enumerated below.
EVAL_SAMPLE_FILES_EXPLICIT = (
    "asr_result.json",
    "aborted.json",
    "result.json",
    "cost.json",
)


def _copy_if_exists(src: Path, dst: Path) -> bool:
    if src.is_file():
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        return True
    return False


def _copy_tree(src: Path, dst: Path) -> bool:
    if not src.is_dir():
        return False
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    return True


def _stage_sample(sample_src: Path, sample_dst: Path, owning_skill_root: str) -> None:
    """Copy the slice of a sample directory the filter actually needs.

    We avoid staging the entire sample (it duplicates the canonical task tree
    and the runtime glue), and instead pull:
      - metadata.json
      - the poisoned owning-skill tree (drives the diff against task_clean/)
      - environment/Dockerfile (so the filter can see grounding)
      - environment/evaluator_runtime/sink_config.json if networked
      - tests/run_asr_evaluator.py (for the byte-identity check vs evaluator.py)
    """
    sample_dst.mkdir(parents=True, exist_ok=True)

    _copy_if_exists(sample_src / "metadata.json", sample_dst / "metadata.json")

    poisoned_skill = sample_src / owning_skill_root
    if poisoned_skill.is_dir():
        _copy_tree(poisoned_skill, sample_dst / owning_skill_root)

    _copy_if_exists(
        sample_src / "environment" / "Dockerfile",
        sample_dst / "environment" / "Dockerfile",
    )
    _copy_if_exists(
        sample_src / "environment" / "evaluator_runtime" / "sink_config.json",
        sample_dst / "environment" / "evaluator_runtime" / "sink_config.json",
    )
    _copy_if_exists(
        sample_src / "tests" / "run_asr_evaluator.py",
        sample_dst / "tests" / "run_asr_evaluator.py",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare static_attack_filter environment")
    parser.add_argument("--task", required=True)
    parser.add_argument("--target-slug", required=True)
    parser.add_argument("--risk", required=True)
    parser.add_argument("--designer", required=True, help="Designer agent ID, e.g. claude_claude-opus-4-7")
    parser.add_argument("--env-dir", required=True, help="Filter task's environment/ directory")
    parser.add_argument(
        "--exclude-realizations",
        default="",
        help="Comma-separated realization names to skip (e.g. 'hidden_unicode'). "
             "Removes matching entries from the staged manifest, samples/, and "
             "eval_results/. Original on-disk artifacts are not touched.",
    )
    args = parser.parse_args()
    excluded_realizations = {r.strip() for r in args.exclude_realizations.split(",") if r.strip()}

    script_dir = Path(__file__).resolve().parent
    filter_dir = script_dir.parent
    skillsbench = filter_dir.parent
    harness_dir = skillsbench / "nl_harness"
    tasks_dir = skillsbench / "tasks"
    env_dir = Path(args.env_dir)

    design_dir = harness_dir / "results" / args.task / args.target_slug / args.risk / "outputs" / args.designer
    if not design_dir.is_dir():
        print(f"ERROR: design directory not found: {design_dir}")
        return 1

    # 1. Top-level designer artifacts (must exist — fail fast if any are missing).
    required = ("attacker_goal.json", "evaluator.py", "manifest.json")
    for name in required:
        src = design_dir / name
        if not src.is_file():
            print(f"ERROR: missing {name} in {design_dir}")
            return 1
        shutil.copy2(src, env_dir / name)

    with open(env_dir / "manifest.json") as f:
        manifest = json.load(f)
    if not manifest:
        print(f"ERROR: manifest.json is empty in {design_dir}")
        return 1

    # Filter excluded realizations out of the manifest before staging anything
    # downstream (samples/, eval_results/) so the LLM filter only sees the
    # realizations we want it to verdict.
    if excluded_realizations:
        original_count = len(manifest)
        manifest = [e for e in manifest if e.get("realization") not in excluded_realizations]
        dropped = original_count - len(manifest)
        if dropped > 0:
            print(f"  Excluded {dropped} sample(s) by realization filter: {sorted(excluded_realizations)}")
        if not manifest:
            print(
                f"ERROR: all samples excluded by --exclude-realizations="
                f"{args.exclude_realizations}; nothing left to filter"
            )
            return 1
        # Rewrite the staged manifest to reflect the exclusion.
        with open(env_dir / "manifest.json", "w") as f:
            json.dump(manifest, f, indent=2)

    kept_sample_ids = {e["sample_id"] for e in manifest}

    target_path = manifest[0]["target_task_relative_path"]
    owning_skill_root = manifest[0]["owning_skill_root"]

    # Identity file — single source of truth for the output's identity fields,
    # so the filter agent doesn't have to read env vars (which LLMs sometimes
    # forget to do, falling back to "unknown" silently).
    identity = {
        "task_id": manifest[0]["task_id"],
        "risk_id": manifest[0]["risk_id"],
        "target_path": target_path,
        "target_slug": args.target_slug,
        "design_agent_id": args.designer,
    }
    with open(env_dir / "identity.json", "w") as f:
        json.dump(identity, f, indent=2)

    # 2. Risk taxonomy entry (just this risk_id's row). Fail loudly if missing —
    #    a silent fallback to {} would propagate a data problem into ambiguous
    #    filter output.
    taxonomy_path = harness_dir / "risk_taxonomy.json"
    if not taxonomy_path.is_file():
        print(f"ERROR: risk taxonomy not found at {taxonomy_path}")
        return 1
    with open(taxonomy_path) as f:
        taxonomy = json.load(f)
    entry = next(
        (r for r in taxonomy.get("risk_types", []) if r.get("risk_id") == args.risk),
        None,
    )
    if entry is None:
        print(
            f"ERROR: risk_id '{args.risk}' not found in {taxonomy_path}. "
            "Check that the design's risk_id matches a current taxonomy entry."
        )
        return 1
    with open(env_dir / "risk_taxonomy_entry.json", "w") as f:
        json.dump(entry, f, indent=2)

    # 3. Per-sample artifacts (poisoned skill + Dockerfile + sink_config + test glue).
    samples_dst = env_dir / "samples"
    if samples_dst.exists():
        shutil.rmtree(samples_dst)
    samples_dst.mkdir()
    for entry in manifest:
        sid = entry["sample_id"]
        sample_src = design_dir / "samples" / sid
        if not sample_src.is_dir():
            print(f"WARNING: sample {sid} listed in manifest but missing from samples/")
            continue
        _stage_sample(sample_src, samples_dst / sid, entry["owning_skill_root"])

    # 4. Clean task slice: instruction, Dockerfile, the unmodified owning skill.
    clean_dst = env_dir / "task_clean"
    if clean_dst.exists():
        shutil.rmtree(clean_dst)
    clean_dst.mkdir()
    canonical_task = tasks_dir / args.task
    if not canonical_task.is_dir():
        print(f"WARNING: canonical task missing: {canonical_task}")
    else:
        _copy_if_exists(canonical_task / "instruction.md", clean_dst / "instruction.md")
        _copy_if_exists(
            canonical_task / "environment" / "Dockerfile",
            clean_dst / "environment" / "Dockerfile",
        )
        _copy_tree(canonical_task / owning_skill_root, clean_dst / owning_skill_root)

    # 5. Per-runner per-sample eval results.
    eval_dst = env_dir / "eval_results"
    if eval_dst.exists():
        shutil.rmtree(eval_dst)
    eval_dst.mkdir()
    eval_root = design_dir / "evals"
    if eval_root.is_dir():
        for runner_dir in sorted(eval_root.iterdir()):
            if not runner_dir.is_dir():
                continue
            runner_dst = eval_dst / runner_dir.name
            runner_dst.mkdir()
            for sample_dir in sorted(runner_dir.iterdir()):
                if not sample_dir.is_dir():
                    continue
                if sample_dir.name not in kept_sample_ids:
                    continue  # excluded realization — also skip its eval records
                sample_dst = runner_dst / sample_dir.name
                sample_dst.mkdir()
                for fname in EVAL_SAMPLE_FILES_EXPLICIT:
                    _copy_if_exists(sample_dir / fname, sample_dst / fname)
                for txt_file in sorted(sample_dir.glob("*.txt")):
                    _copy_if_exists(txt_file, sample_dst / txt_file.name)

    print(
        f"Filter context prepared: task={args.task} target={args.target_slug} "
        f"risk={args.risk} designer={args.designer}"
    )
    print(f"  Owning skill: {owning_skill_root}")
    print(f"  Samples staged: {len(manifest)}")
    print(f"  Eval runners staged: {len(list(eval_dst.iterdir()))}")
    print(f"  Environment dir: {env_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

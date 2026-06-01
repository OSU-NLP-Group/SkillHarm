#!/usr/bin/env python3
"""Scan every clean skill in tasks/ and write a baseline JSON per skill into baselines/.

The baseline is the scanner's verdict on the unmodified skill, computed by
running the scanner N times (default 3) and unioning the (code, file) pairs
across runs. The GPT-based scanner is noisy — same skill scanned twice can
yield different E-codes — so a single-shot baseline biases the agent's later
attribution check (Step 5.7) toward false positives.

During sample generation the attack-design agent subtracts baseline issues
from its final poisoned-skill scan to compute attributable_e_codes —
separating pre-existing scanner flags from injection-introduced ones.

Usage:
    # OpenAI
    OPENAI_API_KEY=sk-... python3 compute_baselines.py

    # Azure OpenAI
    AZURE_OPENAI_API_KEY=... AZURE_OPENAI_ENDPOINT=https://... \\
        python3 compute_baselines.py

    # Specific model / provider
    python3 compute_baselines.py --model gpt-4o --provider azure

    # Only scan skills for specific tasks
    python3 compute_baselines.py --tasks citation-check court-form-filling

    # Overwrite existing baselines
    python3 compute_baselines.py --force

    # Dry run (show what would be scanned without calling the scanner)
    python3 compute_baselines.py --dry-run

Writes:  baselines/<task_id>/<skill_name>.json

Baselines live under fixed-payload-poisoning/ (not tasks/) because they are nl_harness-private
metadata: putting them inside the canonical task tree would (a) leak nl_harness
internals into other harnesses that consume tasks/, and (b) get copied into every
sample via Step 5.1's `cp -r task/ samples/<id>/`, breaking the "sample is a
drop-in replacement for task/" property.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def _find_skills(tasks_dir: Path, task_filter: list[str] | None) -> list[tuple[str, Path]]:
    """Return sorted list of (task_id, skill_dir) tuples — each skill must have SKILL.md."""
    skills: list[tuple[str, Path]] = []
    for task_dir in sorted(tasks_dir.iterdir()):
        if not task_dir.is_dir():
            continue
        if task_filter and task_dir.name not in task_filter:
            continue
        skills_root = task_dir / "environment" / "skills"
        if not skills_root.is_dir():
            continue
        for skill_dir in sorted(skills_root.iterdir()):
            if skill_dir.is_dir() and (skill_dir / "SKILL.md").exists():
                skills.append((task_dir.name, skill_dir))
    return skills


def _check_credentials() -> bool:
    has_openai = bool(os.environ.get("OPENAI_API_KEY"))
    has_azure = bool(
        (os.environ.get("AZURE_OPENAI_API_KEY") or os.environ.get("AZURE_OPENAI_KEY"))
        and os.environ.get("AZURE_OPENAI_ENDPOINT")
    )
    return has_openai or has_azure


def _file_of(loc: str) -> str:
    """Robust file extraction from scanner's `location` string.

    'scripts/foo.py:42'           -> 'scripts/foo.py'
    'scripts/foo.py lines 40-50'  -> 'scripts/foo.py'
    'scripts/foo.py'              -> 'scripts/foo.py'
    Empty / None                  -> ''
    """
    return (loc or "").split(":", 1)[0].split(None, 1)[0]


def _scan_n_times(skill_dir: Path, model: str, provider: str | None, runs: int):
    """Scan a skill `runs` times in parallel and return a merged baseline.

    Runs are executed concurrently via a ThreadPoolExecutor (scan_skill is
    I/O-bound — it spends almost all its time waiting on the OpenAI / Azure API
    response, so threads work fine despite the GIL). With runs=3, wall time is
    roughly equal to a single scan rather than 3x.

    Merge policy: union of (code, file) tuples across all raw.issues. Same
    (code, file) seen in any run → kept once. Top-level `issues` and `safe` are
    recomputed from the merged set. The merged baseline is conservative — wider
    than any single scan — so the agent's attribution check filters out any
    baseline noise pattern that ever fires.

    Returns merged result dict in the same shape as `scan_skill`, or a dict with
    safe=None + error if any of the N runs failed (fail-any policy).
    """
    from scan import scan_skill  # noqa: E402

    if runs == 1:
        # Avoid threadpool overhead for the single-run case.
        results = [scan_skill(str(skill_dir), model=model, provider=provider)]
    else:
        with ThreadPoolExecutor(max_workers=runs) as executor:
            futures = [
                executor.submit(scan_skill, str(skill_dir), model=model, provider=provider)
                for _ in range(runs)
            ]
            results = [f.result() for f in futures]

    # Fail-any: if any run errored (safe=None), surface that error and skip
    # the skill rather than producing a partial-N baseline.
    for r in results:
        if r.get("safe") is None:
            return r

    seen_pairs: set[tuple[str, str]] = set()
    merged_raw_issues: list[dict] = []
    for r in results:
        raw = r.get("raw", {}) or {}
        for issue in raw.get("issues", []):
            pair = (issue.get("code", ""), _file_of(issue.get("location", "")))
            if pair not in seen_pairs:
                seen_pairs.add(pair)
                merged_raw_issues.append(issue)

    merged_codes = sorted({issue["code"] for issue in merged_raw_issues})
    merged_safe = not any(c.startswith("E") for c in merged_codes)

    last_raw = (results[-1].get("raw", {}) or {})
    merged_raw = dict(last_raw)
    merged_raw["issues"] = merged_raw_issues
    merged_raw["_metadata"] = {
        **(last_raw.get("_metadata", {}) or {}),
        "runs": runs,
        "merge_method": "union_by_code_file",
    }
    merged_raw["safe"] = merged_safe

    return {
        "safe": merged_safe,
        "issues": merged_codes,
        "raw": merged_raw,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default="gpt-5.4", help="Scanner model (default: gpt-5.4)")
    parser.add_argument("--provider", default=None, help="Provider override: openai | azure")
    parser.add_argument("--tasks", nargs="+", metavar="TASK_ID", help="Only scan skills for these task IDs")
    parser.add_argument("--force", action="store_true", help="Overwrite existing baseline files")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be scanned without running the scanner")
    parser.add_argument(
        "--runs",
        type=int,
        default=3,
        help="Scan each skill N times and union the (code, file) pairs (default: 3). "
             "GPT-based scanners are noisy at the level of individual flags — same skill "
             "scanned twice can yield different E-codes. N>=2 makes the baseline robust "
             "to that noise.",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).parent.resolve()
    harness_dir = script_dir.parent
    repo_dir = harness_dir.parent
    tasks_dir = repo_dir / "tasks"

    if not tasks_dir.is_dir():
        sys.exit(f"ERROR: tasks directory not found: {tasks_dir}")

    # Make scan.py importable (it lives in fixed-payload-poisoning/environment/).
    sys.path.insert(0, str(harness_dir / "environment"))

    if args.runs < 1:
        sys.exit(f"ERROR: --runs must be >= 1, got {args.runs}")

    if not args.dry_run and not _check_credentials():
        sys.exit(
            "ERROR: No scanner credentials found.\n"
            "Set OPENAI_API_KEY, or AZURE_OPENAI_API_KEY + AZURE_OPENAI_ENDPOINT."
        )

    skills = _find_skills(tasks_dir, args.tasks)
    if not skills:
        sys.exit("No skill folders found. Check --tasks filter or tasks/ directory.")

    baselines_root = harness_dir / "baselines"

    skipped = 0
    scanned = 0
    errors = 0

    print(f"Found {len(skills)} skill folder(s) to process.  (runs per skill: {args.runs})")
    if args.dry_run:
        print("(dry-run — scanner will not be called)\n")

    for task_id, skill_dir in skills:
        rel = skill_dir.relative_to(repo_dir)
        baseline_path = baselines_root / task_id / f"{skill_dir.name}.json"

        if baseline_path.exists() and not args.force:
            try:
                existing = json.loads(baseline_path.read_text())
                print(f"  SKIP  {rel}  (baseline exists: safe={existing.get('safe')}, issues={existing.get('issues', [])})")
                skipped += 1
                continue
            except json.JSONDecodeError:
                # Corrupt baseline — fall through to re-scan.
                print(f"  REDO  {rel}  (existing baseline file is corrupt, re-scanning)")

        if args.dry_run:
            print(f"  WOULD SCAN  {rel}  ->  {baseline_path.relative_to(repo_dir)}  (x{args.runs})")
            continue

        print(f"  SCAN  {rel}  (x{args.runs}) ...", end="", flush=True)
        t0 = time.monotonic()
        result = _scan_n_times(skill_dir, model=args.model, provider=args.provider, runs=args.runs)
        elapsed = time.monotonic() - t0

        if result.get("safe") is None:
            error_msg = result.get("error", "unknown error")
            print(f"  ERROR ({elapsed:.1f}s): {error_msg}")
            errors += 1
            continue

        # Persist the merged scanner response (raw.issues = union of all runs by
        # (code, file)). The agent in Step 5.7 reads this to filter out E-codes
        # that were already triggered by the clean skill, distinguishing them
        # from injection-introduced ones.
        raw = dict(result.get("raw", {}) or {})
        # The scanner writes an absolute host path into raw._metadata.skill_path;
        # since baselines are checked into a public-bound repo, strip it.
        meta = raw.get("_metadata")
        if isinstance(meta, dict) and "skill_path" in meta:
            meta = {k: v for k, v in meta.items() if k != "skill_path"}
            raw["_metadata"] = meta
        baseline = {
            "safe": result["safe"],
            "issues": result.get("issues", []),
            "raw": raw,
        }
        baseline_path.parent.mkdir(parents=True, exist_ok=True)
        baseline_path.write_text(json.dumps(baseline, indent=2) + "\n")
        scanned += 1
        print(f"  done ({elapsed:.1f}s)  safe={baseline['safe']}, issues={baseline['issues']}")

    print(f"\nDone. scanned={scanned}  skipped={skipped}  errors={errors}")
    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()

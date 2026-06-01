"""Pre-sample which risks each injection target is paired with.

For every injection target listed in ``fixed-payload-poisoning/attack_target_selection/targets/*.json``, draw
``N_RISKS_PER_TARGET`` distinct risks from the 12-entry taxonomy in
``risk_taxonomy.json``. Sampling is **stratified by target kind** (doc
vs. script): we run the balanced-assignment routine separately on the
doc-target subset and the script-target subset, so each ``(risk × kind)``
cell carries an approximately equal sample size. A globally-balanced but
kind-agnostic shuffle would let some risks land disproportionately on
docs vs. scripts (we measured spread = 7 in both kinds under the
non-stratified version), which would skew kind-conditional ASR
comparisons.

Within each kind the assignment is balanced — each risk type covers
``floor(slots / 12)`` or ``ceil(slots / 12)`` targets, where
``slots = N_RISKS_PER_TARGET * (number of targets of that kind)``.

Output: ``risk_assignments.json``. The harness driver
(``scripts/run_all.sh``) reads this file to enumerate the exact set of
``(task, target, risk)`` combos to run, instead of computing a Cartesian
product over all 12 risks at runtime.

Run from the repo root (``skillsbench/``)::

    uv run python fixed-payload-poisoning/attack_target_selection/scripts/sample_risks.py

Re-run after any change to ``fixed-payload-poisoning/attack_target_selection/targets/*.json`` (typically after
``baselines/task_selection.py``) — the assignment is recomputed from
scratch and is fully determined by ``SEED``.
"""

from __future__ import annotations

import json
import random
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
HARNESS_DIR = REPO_ROOT / "nl_harness"
TARGETS_DIR = HARNESS_DIR / "targets"
TAXONOMY_PATH = HARNESS_DIR / "risk_taxonomy.json"
OUTPUT_PATH = HARNESS_DIR / "risk_assignments.json"
INJECTION_POINTS_PATH = REPO_ROOT / "baselines" / "injection_points.json"

# Number of distinct risks each injection target is paired with.
N_RISKS_PER_TARGET = 2

# Fixed for reproducibility. Bump only when intentionally re-randomizing
# the benchmark (e.g., to estimate sampling-noise variance in ASR).
SEED = 42

# Seed offset used for the script-kind stratum, kept disjoint from the
# doc stratum's seed sequence (doc uses [SEED, SEED+99], script uses
# [SEED+SCRIPT_SEED_OFFSET, SEED+SCRIPT_SEED_OFFSET+99]) so the two
# shuffles cannot share a state by accident.
SCRIPT_SEED_OFFSET = 1000

# Cap on retry count when the greedy assignment hits an unresolvable
# collision. Each retry uses a fresh seed offset, so the cap matters only
# in pathological corner cases — for the current 142×2 / 12 problem the
# first attempt almost always succeeds.
MAX_ATTEMPTS = 100


def load_target_triples() -> list[tuple[str, str, str]]:
    """Return ``[(task_id, target_path, kind), ...]`` in deterministic order.

    ``kind`` ("doc" or "script") is read from ``injection_points.json`` —
    the canonical source of truth for target classification. The
    ``targets/*.json`` files only carry paths, so we cross-reference.
    """
    with open(INJECTION_POINTS_PATH) as f:
        sel = json.load(f)["tasks"]
    kind_lookup: dict[tuple[str, str], str] = {}
    for task, info in sel.items():
        for entry in info["targets"]:
            full_path = f"environment/skills/{entry['path']}"
            kind_lookup[(task, full_path)] = entry["kind"]

    triples: list[tuple[str, str, str]] = []
    for path in sorted(TARGETS_DIR.glob("*.json")):
        task_id = path.stem
        with open(path) as f:
            entries = json.load(f)["injection_targets"]
        for target in entries:
            kind = kind_lookup.get((task_id, target))
            if kind is None:
                raise SystemExit(
                    f"target missing from injection_points.json: "
                    f"({task_id}, {target}) — regenerate via "
                    f"baselines/task_selection.py"
                )
            triples.append((task_id, target, kind))
    return triples


def load_risk_ids() -> list[str]:
    with open(TAXONOMY_PATH) as f:
        return [r["risk_id"] for r in json.load(f)["risk_types"]]


def _try_assign(
    n_items: int, n_choices: int, k: int, rng: random.Random
) -> list[list[int]]:
    """One attempt at a balanced assignment. Returns choice indices.

    Raises ``RuntimeError`` if the greedy walk gets stuck — the caller
    is expected to retry with a fresh seed.
    """
    total = n_items * k
    base, rem = divmod(total, n_choices)
    boosted = set(rng.sample(range(n_choices), rem))
    counts = [base + (1 if i in boosted else 0) for i in range(n_choices)]

    pool: list[int] = []
    for choice_idx, count in enumerate(counts):
        pool.extend([choice_idx] * count)
    rng.shuffle(pool)

    assignments: list[list[int]] = [[] for _ in range(n_items)]
    pool_iter = iter(pool)
    deferred: list[int] = []

    for item_idx in range(n_items):
        for _ in range(k):
            # Drain the deferred queue first so collisions parked earlier
            # find a home as soon as a non-conflicting item appears.
            placed = False
            for d_idx in range(len(deferred)):
                if deferred[d_idx] not in assignments[item_idx]:
                    assignments[item_idx].append(deferred.pop(d_idx))
                    placed = True
                    break
            if placed:
                continue

            # Then pull from the main pool, parking collisions to the
            # deferred queue for a later item to absorb.
            while True:
                try:
                    cand = next(pool_iter)
                except StopIteration:
                    raise RuntimeError("pool exhausted before all items filled")
                if cand not in assignments[item_idx]:
                    assignments[item_idx].append(cand)
                    break
                deferred.append(cand)

    if deferred:
        raise RuntimeError(f"{len(deferred)} entries left undeferred-but-unplaced")
    return assignments


def balanced_assignment(
    n_items: int, choices: list[str], k: int, seed: int
) -> tuple[list[list[str]], int]:
    """Return per-item assignments and the seed offset that succeeded."""
    if n_items == 0:
        return [], seed
    if k > len(choices):
        raise ValueError(f"k={k} cannot exceed |choices|={len(choices)}")
    last_err: Exception | None = None
    for attempt in range(MAX_ATTEMPTS):
        rng = random.Random(seed + attempt)
        try:
            idx_assignments = _try_assign(n_items, len(choices), k, rng)
        except RuntimeError as err:
            last_err = err
            continue
        return (
            [[choices[i] for i in slot] for slot in idx_assignments],
            seed + attempt,
        )
    raise RuntimeError(
        f"Could not find a balanced assignment within {MAX_ATTEMPTS} attempts "
        f"(seed={seed}); last error: {last_err}"
    )


def main() -> None:
    triples = load_target_triples()
    risks = load_risk_ids()

    if not triples:
        raise SystemExit(f"No targets found in {TARGETS_DIR}")
    if not risks:
        raise SystemExit(f"No risks found in {TAXONOMY_PATH}")

    doc_pairs = [(t, p) for t, p, k in triples if k == "doc"]
    script_pairs = [(t, p) for t, p, k in triples if k == "script"]

    doc_assignments, doc_seed = balanced_assignment(
        n_items=len(doc_pairs),
        choices=risks,
        k=N_RISKS_PER_TARGET,
        seed=SEED,
    )
    script_assignments, script_seed = balanced_assignment(
        n_items=len(script_pairs),
        choices=risks,
        k=N_RISKS_PER_TARGET,
        seed=SEED + SCRIPT_SEED_OFFSET,
    )

    # Map (task, target) → risk pair for both kinds, then walk the
    # original triples order so per-task target order matches the
    # targets/*.json files.
    pair_to_risks: dict[tuple[str, str], list[str]] = {}
    for (task, target), pair in zip(doc_pairs, doc_assignments):
        pair_to_risks[(task, target)] = pair
    for (task, target), pair in zip(script_pairs, script_assignments):
        pair_to_risks[(task, target)] = pair

    per_task: dict[str, dict[str, list[str]]] = {}
    doc_counts: Counter[str] = Counter()
    script_counts: Counter[str] = Counter()
    for task, target, kind in triples:
        pair = pair_to_risks[(task, target)]
        per_task.setdefault(task, {})[target] = pair
        bucket = doc_counts if kind == "doc" else script_counts
        for r in pair:
            bucket[r] += 1

    per_risk_counts = {
        r: {
            "doc": doc_counts[r],
            "script": script_counts[r],
            "total": doc_counts[r] + script_counts[r],
        }
        for r in risks
    }

    output = {
        "_meta": {
            "n_risks_per_target": N_RISKS_PER_TARGET,
            "seed": SEED,
            "doc_seed_used": doc_seed,
            "script_seed_used": script_seed,
            "n_doc_targets": len(doc_pairs),
            "n_script_targets": len(script_pairs),
            "n_targets": len(triples),
            "n_risks": len(risks),
            "n_combos": len(triples) * N_RISKS_PER_TARGET,
            "stratified_by_kind": True,
            "per_risk_counts": per_risk_counts,
        },
        "assignments": per_task,
    }
    OUTPUT_PATH.write_text(json.dumps(output, indent=2) + "\n")

    print(
        f"Wrote {OUTPUT_PATH.relative_to(REPO_ROOT)} "
        f"({len(triples)} targets × {N_RISKS_PER_TARGET} risks "
        f"= {len(triples) * N_RISKS_PER_TARGET} combos)"
    )
    print(
        f"  Doc stratum:    {len(doc_pairs)} targets, "
        f"{len(doc_pairs) * N_RISKS_PER_TARGET} slots "
        f"(expected {len(doc_pairs) * N_RISKS_PER_TARGET / len(risks):.2f}/risk; "
        f"seed={doc_seed})"
    )
    print(
        f"  Script stratum: {len(script_pairs)} targets, "
        f"{len(script_pairs) * N_RISKS_PER_TARGET} slots "
        f"(expected {len(script_pairs) * N_RISKS_PER_TARGET / len(risks):.2f}/risk; "
        f"seed={script_seed})"
    )

    doc_vals = [doc_counts[r] for r in risks]
    script_vals = [script_counts[r] for r in risks]
    print(
        f"  Doc spread:    min={min(doc_vals)} max={max(doc_vals)} "
        f"(spread={max(doc_vals) - min(doc_vals)})"
    )
    print(
        f"  Script spread: min={min(script_vals)} max={max(script_vals)} "
        f"(spread={max(script_vals) - min(script_vals)})"
    )
    print()
    print(f"  {'risk_id':<32} {'doc':>5} {'script':>7} {'total':>6}")
    print(f"  {'-' * 32} {'-' * 5} {'-' * 7} {'-' * 6}")
    for r in risks:
        c = per_risk_counts[r]
        print(f"  {r:<32} {c['doc']:>5} {c['script']:>7} {c['total']:>6}")


if __name__ == "__main__":
    main()

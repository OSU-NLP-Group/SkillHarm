#!/usr/bin/env python3
"""
Merge and vote on task pair selections from multiple agents.

Usage:
    python vote.py <outputs_dir>

Reads all .json files in the outputs directory (excluding consensus.json),
counts how many agents selected each (task_a, task_b) pair, and produces
a ranked consensus preserving the low-risk → high-risk directionality.
"""

import json
import os
import sys
from collections import Counter, defaultdict
from pathlib import Path


def load_agent_outputs(outputs_dir: str) -> dict[str, list[dict]]:
    """Load all agent outputs from directory."""
    agents = {}
    for f in sorted(Path(outputs_dir).glob("*.json")):
        if f.stem == "consensus":
            continue
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
            pairs = data.get("pairs", [])
            if pairs:
                agents[f.stem] = pairs
                print(f"  Loaded {f.stem}: {len(pairs)} pairs")
        except Exception as e:
            print(f"  Error loading {f.name}: {e}")
    return agents


def extract_pair_key(pair: dict) -> tuple[str, str]:
    """Get canonical key — always (task_a, task_b) preserving direction."""
    a = pair.get("task_a", {}).get("name", "")
    b = pair.get("task_b", {}).get("name", "")
    return (a, b)


def normalize_key(key: tuple[str, str]) -> tuple[str, str]:
    """For dedup: sort alphabetically so A→B and B→A are the same."""
    return tuple(sorted(key))


def vote(agents: dict[str, list[dict]]) -> list[dict]:
    """Merge agent selections with voting."""
    pair_votes: Counter = Counter()
    pair_details: dict[tuple, list[dict]] = defaultdict(list)
    pair_agents: dict[tuple, list[str]] = defaultdict(list)

    for agent_name, pairs in agents.items():
        for pair in pairs:
            key = extract_pair_key(pair)
            norm = normalize_key(key)
            if key[0] and key[1]:
                pair_votes[norm] += 1
                pair_details[norm].append(pair)
                pair_agents[norm].append(agent_name)

    results = []
    for norm_key, vote_count in pair_votes.most_common():
        details = pair_details[norm_key]

        avg_feasibility = sum(d.get("feasibility_score", 5) for d in details) / len(details)
        avg_impact = sum(d.get("impact_score", 5) for d in details) / len(details)

        # Pick the best detail by individual score (not by narrative length)
        best = max(details, key=lambda d: d.get("feasibility_score", 0) * d.get("impact_score", 0))

        results.append({
            "task_a": best.get("task_a", {}),
            "task_b": best.get("task_b", {}),
            "shared_skills": best.get("shared_skills", []),
            "attack_vector": best.get("attack_vector", {}),
            "votes": vote_count,
            "voted_by": pair_agents[norm_key],
            "avg_feasibility_score": round(avg_feasibility, 1),
            "avg_impact_score": round(avg_impact, 1),
            "consensus_score": round(vote_count * avg_feasibility * avg_impact, 1),
            "narrative": best.get("narrative", ""),
        })

    results.sort(key=lambda r: r["consensus_score"], reverse=True)
    return results


def main():
    if len(sys.argv) < 2:
        print("Usage: python vote.py <outputs_dir>")
        sys.exit(1)

    outputs_dir = sys.argv[1]
    print(f"Loading agent outputs from {outputs_dir}")
    agents = load_agent_outputs(outputs_dir)

    if not agents:
        print("No agent outputs found!")
        sys.exit(1)

    print(f"\n{len(agents)} agents loaded. Voting...")
    results = vote(agents)

    print(f"\n{'='*80}")
    print(f"  CONSENSUS RANKING ({len(results)} unique pairs)")
    print(f"{'='*80}\n")

    for i, r in enumerate(results[:20], 1):
        a = r["task_a"].get("name", "?")
        b = r["task_b"].get("name", "?")
        votes = r["votes"]
        total = len(agents)
        cs = r["consensus_score"]
        skills = ", ".join(r["shared_skills"])
        voters = ", ".join(r["voted_by"])
        print(f"  {i:2d}. [{votes}/{total} votes, score={cs}] {a} -> {b}")
        print(f"      shared: {skills}")
        print(f"      voted by: {voters}")
        print()

    output_path = os.path.join(outputs_dir, "consensus.json")
    consensus = {
        "agents": list(agents.keys()),
        "total_unique_pairs": len(results),
        "pairs": results,
    }
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(consensus, f, indent=2)
    print(f"Consensus saved to {output_path}")


if __name__ == "__main__":
    main()

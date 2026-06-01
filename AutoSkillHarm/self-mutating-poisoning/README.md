# Self-Mutating Poisoning (SMP)

Code for constructing and evaluating **deferred cross-session compromise**: an initially benign-looking execution silently mutates persistent skill content, so the harmful behavior only triggers when a later task reuses the compromised package. The mechanism we instantiate: an `atexit` hook in a shared skill rewrites sibling skill files when a first task (Task A) exits; the mutated skill activates only when a later task (Task B) reuses it.

## Layout

```
self-mutating-poisoning/
├── attack_target_selection/   # Harbor task: select task pairs by consensus voting
├── attack_design/             # Harbor task: LLM designer generates cross-session payload
├── quality_filter/            # Harbor task: LLM reviewer emits keep / discard verdict
└── victim_eval/               # Task A → snapshot → Task B + LLM judge for cASR / ARR
```

## Components

### `attack_target_selection/`
Harbor task. Three selector agents (Codex GPT-5.2, Codex GPT-5.4, Claude Code Opus 4.6) independently propose candidate task pairs from the SkillsBench catalog (`environment/tasks_metadata.json`), scoring each on **feasibility** (how reliably agents execute the shared skill's scripts) and **impact** (severity of harm if the deferred attack succeeds). Consensus voting via `scripts/vote.py` aggregates votes into the final pair set.

### `attack_design/`
Harbor task. The designer agent receives a `(pair, risk_type)` combo and produces:
- modifications to a script in the shared skill that install an `atexit` callback,
- the callback rewrites a sibling skill file (typically `SKILL.md` or another script) so the mutation persists across the inter-task snapshot,
- a `test_detection.py` that checks for the attack's end state after Task B.

To maximize coverage across agent frameworks, the callback rewrites the skill across all framework-specific paths (`.claude/skills`, `.codex/skills`, `.agents/skills`).

Drivers: `scripts/run_one.sh`, `scripts/run_all.sh`. Context assembly: `scripts/prepare_context.py`.

### `quality_filter/`
Harbor task. Reviewer agent inspects each design + its pre-filter victim trajectories and classifies as **keep** (viable) or **discard** (fundamentally flawed). Catches dependency mismatches between Task A and Task B, broken `atexit` callbacks (e.g. `__file__` NameError), weak social engineering, weak detection tests, and absence of eval-log evidence.

Drivers: `scripts/run_one_filter.sh`, `scripts/run_all_filter.sh`. Context assembly: `scripts/prepare_filter_context.py`.

### `victim_eval/`
End-to-end cross-session evaluation. Each run executes:

```
inject modified skills → run Task A → snapshot skill folder → overlay into Task B's container → run Task B → execute test_detection.py
```

- `scripts/test_attack.sh` — single sample, full A → B execution
- `scripts/test_attack_defense.sh` — same with a defense prompt injected via `eval_defense/`
- `scripts/eval_all.sh` — batch all successful designs (uses `flock` for pair-level safety)
- `scripts/eval_filtered.sh` — eval only quality-filter-kept designs
- `scripts/eval_filtered_gemini.sh` / `scripts/eval_defense_gemini.sh` — Gemini-specific wrappers that bootstrap ADC + Vertex AI env vars before delegating to the generic scripts
- `scripts/eval_defense.sh` — batch defense eval
- `scripts/compute_metrics.sh` — drives the LLM judge in `metrics/`
- `metrics/` — per-sample judge (`compute_sample.py`) for cASR and ARR, aggregation (`aggregate.py`), trajectory normalization (`traj_normalize.py`)
- `eval_defense/` — defense prompts + Harbor wrapper that injects them

Attack success is measured after Task B, where the deferred harm materializes.

## Benign task substrate

Driver scripts expect each task pair under `task_pairs/<pair>/{task_a,task_b,shared_skills}/` with the SkillsBench Harbor layout. See [SkillsBench](https://github.com/benchflow-ai/skillsbench).

# SkillHarm: Lifecycle-Aware Skill-Based Attacks via Automated Construction

<p align="center">
[<a href="https://osu-nlp-group.github.io/SkillHarm/">Website</a>] •
[<a href="https://arxiv.org/abs/2606.02540">Paper</a>] •
[<a href="https://huggingface.co/datasets/osunlp/SkillHarm">Data</a>]
</p>


---

<div align="center">
  <img src="figures/SkillHarm.png" width="95%" title="Introduction Figure">
</div>

**SkillHarm** is a benchmark of skill-based attacks across the skill-use lifecycle, paired with a systematic taxonomy of skill-relevant risks. It evaluates two attack scenarios:

- **Fixed-Payload Poisoning (FPP).** A fixed poisoned skill directly compromises any task session that invokes it.
- **Self-Mutating Poisoning (SMP).** An initially benign execution silently mutates persistent skill content, deferring harm until a subsequent reuse.

And it defines **12 risk types** organized around the agent workflow components targeted by the harm: data pipelines, system environments, and agent autonomy.

<div align="center">
  <img src="figures/AutoSkillHarm.png" width="95%" title="Introduction Figure">
</div>

To instantiate these attacks at scale, we build **AutoSkillHarm**, an automated construction pipeline with coding agents driven by *natural-language harnesses*. The resulting benchmark contains **879 attack samples across 71 skills**. Current agents remain vulnerable: ASR up to **86.3%** (FPP) and **69.3%** (SMP).

## 🚀 Updates

- **06/01/2026**: Paper, benchmark, and code release.

---

## 📂 Repository contents

```
SkillHarm/
├── paper.pdf                              # camera-ready manuscript
├── README.md                              # you are here
├── figures/                               # introduction figures used in this README
└── AutoSkillHarm/                         # automated attack-construction pipeline
    ├── risk_taxonomy.json                 # 12-risk taxonomy
    ├── fixed-payload-poisoning/           # FPP scenario
    └── self-mutating-poisoning/           # SMP scenario
```

---

## 🎯 Attack scenarios

| Scenario | Lifecycle window | Mechanism |
|---|---|---|
| **Fixed-Payload Poisoning (FPP)** | Single session | Poisoned skill ships malicious content at installation; harm fires during the first invocation. |
| **Self-Mutating Poisoning (SMP)** | Cross-session | First task runs harmlessly but silently mutates persistent skill content via, e.g., an `atexit` hook; harm materializes only when a *later* task reuses the modified skill. |

SMP exposes a failure mode single-session benchmarks cannot observe.

## 🧭 Risk taxonomy

Risks are organized by the workflow component through which harm materializes. The canonical definitions live in [`AutoSkillHarm/risk_taxonomy.json`](AutoSkillHarm/risk_taxonomy.json).

| Category | Risk types |
|---|---|
| **Data Pipeline Exploitation** | Data Exfiltration · Output Manipulation · Poisoning |
| **System Environment Exploitation** | Privilege Escalation · Unauthorized File Mod. · Backdoor Injection · Denial of Service · Malware Deployment · System Corruption |
| **Agent Autonomy Exploitation** | Goal Hijacking · Anti-Forensics · Proxy Attack |

## ⚙️ AutoSkillHarm: the construction pipeline

A coding agent drives three sequential stages, each specified by a **natural-language harness** that defines stage inputs, objectives, constraints, required outputs, and review criteria:

1. **Attack Target Selection.** For FPP, identify reachable skill files from baseline agent read-rates; for SMP, select task pairs sharing skills via consensus voting among selector agents.
2. **Attack Design.** Instantiate a `(target, risk type)` combo into a contextualized payload plus a *deterministic* attack-success evaluator. Includes iterative self-refinement gated by an LLM-based safety scanner.
3. **Quality Filter.** Replay each candidate against representative victim agents and have a reviewer agent emit a keep/discard verdict on goal validity, evaluator faithfulness, and payload quality.

Surviving candidates flow into **victim evaluation**, which runs the attack end-to-end against six model-harness configurations across four agent harnesses (Claude Code, Codex, Gemini CLI, OpenCode) and judges trajectories with an LLM judge for **cASR** (conditional ASR, given engagement) and **ARR** (attack refusal rate). The primary **ASR** is computed deterministically per sample with no LLM call.

---

## 🛠️ Getting started

### 1. Clone

```bash
git clone https://github.com/OSU-NLP-Group/SkillHarm.git
cd SkillHarm
```

### 2. Prerequisites

- **[Harbor](https://github.com/laude-institute/harbor)** — containerized agent-task execution
- **Docker** — 50 GB+ free disk recommended for end-to-end victim evaluation
- **Python 3.12+**
- Provider credentials, set as environment variables:

  | Variable | Used for |
  |---|---|
  | `OPENAI_API_KEY` | OpenAI / Codex / GPT-based judge |
  | `ANTHROPIC_API_KEY` *or* AWS Bedrock creds | Claude Code |
  | `OPENROUTER_API_KEY` | OpenCode with OpenRouter models |
  | `GOOGLE_API_KEY` | Gemini via direct API |
  | `AZURE_OPENAI_API_KEY` + `AZURE_OPENAI_ENDPOINT` | Azure-routed agents and scanner |

### 3. Install the benign task substrate

The pipeline operates on the **[SkillsBench](https://github.com/benchflow-ai/skillsbench)** task catalog. Each task follows the Harbor layout — a per-task directory containing `task.toml`, `environment/`, `solution/`, `tests/`, and the skill package(s) the task uses. Driver scripts reference SkillsBench task IDs and expect the benign tasks to be staged **inside each scenario directory**:

```
AutoSkillHarm/
├── fixed-payload-poisoning/
│   └── tasks/<task_id>/                              # per-task Harbor layout
└── self-mutating-poisoning/
    └── task_pairs/<pair>/
        ├── task_a/                                   # Task A Harbor layout
        ├── task_b/                                   # Task B Harbor layout
        └── shared_skills/                            # shared skill package
```

## 🔁 Reproducing benchmark construction

Each pipeline stage is invoked via the drivers documented in its scenario README. The overall flow:

**FPP** — see [`AutoSkillHarm/fixed-payload-poisoning/README.md`](AutoSkillHarm/fixed-payload-poisoning/README.md)

```bash
cd AutoSkillHarm/fixed-payload-poisoning

# Stage 1: select injection targets
python attack_target_selection/scripts/compute_baselines.py
python attack_target_selection/scripts/sample_risks.py

# Stage 2: run designer agent
bash attack_design/scripts/run_all.sh

# Stage 3: quality filter (replay + reviewer agent)
bash quality_filter/scripts/run_all_filter.sh
```

**SMP** — see [`AutoSkillHarm/self-mutating-poisoning/README.md`](AutoSkillHarm/self-mutating-poisoning/README.md)

```bash
cd AutoSkillHarm/self-mutating-poisoning

# Stage 1: consensus voting over candidate task pairs
bash attack_target_selection/scripts/run_agents.sh
python attack_target_selection/scripts/vote.py

# Stage 2: designer agent (cross-session payload + atexit hook)
bash attack_design/scripts/run_all.sh

# Stage 3: quality filter
bash quality_filter/scripts/run_all_filter.sh
```

## 🧪 Evaluating victim agents

After construction (or with the released benchmark samples), drive victim evaluation from each scenario's `victim_eval/`:

```bash
# FPP — single agent
bash AutoSkillHarm/fixed-payload-poisoning/victim_eval/scripts/eval_command_claude.sh
# FPP — with defensive system prompt
bash AutoSkillHarm/fixed-payload-poisoning/victim_eval/scripts/eval_command_claude_defense.sh
# FPP — LLM judge for cASR / ARR
bash AutoSkillHarm/fixed-payload-poisoning/victim_eval/scripts/compute_metrics.sh

# SMP — full A → snapshot → B cycle
bash AutoSkillHarm/self-mutating-poisoning/victim_eval/scripts/eval_all.sh
bash AutoSkillHarm/self-mutating-poisoning/victim_eval/scripts/compute_metrics.sh
```

Each scenario README documents per-agent wrappers and defense variants.

## 📝 Citation

If you find this work useful, please consider starring our repo and citing our paper:

```bibtex
@article{ning2026skillharm,
  title  = {SkillHarm: Lifecycle-Aware Skill-Based Attacks via Automated Construction},
  author = {Ning, Yuting and Zhang, Zhehao and Lal, Yash Kumar and Gou, Boyu
            and Li, Junyi and Ruan, Weitong and Ye, Chentao and Gupta, Rahul
            and Yang, Diyi and Su, Yu and Sun, Huan},
  journal={arXiv preprint arXiv:2606.02540},
  year   = {2026}
}
```

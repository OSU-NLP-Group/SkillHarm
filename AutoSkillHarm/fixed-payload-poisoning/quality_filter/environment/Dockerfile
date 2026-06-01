FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Same toolchain as nl_harness so the filter agent can read PDFs (visual
# realization), parse JSON, and run language-specific syntax checks against
# the poisoned skill files it diffs.
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    jq \
    curl \
    ripgrep \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages \
    pypdf==5.1.0 \
    pyyaml

WORKDIR /root

# Designer-side artifacts. Populated per-run by prepare_filter_context.py.
# identity.json carries the verbatim identity fields the agent must echo into
# filter_result.json — kept as a separate file rather than env vars so the LLM
# cannot accidentally fall back to "unknown".
COPY identity.json /root/identity.json
COPY risk_taxonomy_entry.json /root/risk_taxonomy_entry.json
COPY attacker_goal.json /root/attacker_goal.json
COPY evaluator.py /root/evaluator.py
COPY manifest.json /root/manifest.json

# Per-realization sample artifacts (poisoned skill, sample Dockerfile, sink
# config if networked). Trimmed to what the filter actually needs to reason
# about — full sample directories are not staged in to keep the build context
# small.
COPY samples/ /root/samples/

# Clean task: instruction, Dockerfile, and the unmodified owning-skill tree
# (under environment/skills/<owning_skill>/) for diffing.
COPY task_clean/ /root/task_clean/

# Per-runner per-sample evaluation outputs. May be empty if no evaluation has
# been run for this design yet.
COPY eval_results/ /root/eval_results/

RUN mkdir -p /root/output

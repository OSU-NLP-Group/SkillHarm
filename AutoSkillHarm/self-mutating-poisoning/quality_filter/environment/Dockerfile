FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    jq \
    curl \
    ripgrep \
    && rm -rf /var/lib/apt/lists/*

# Pre-install Node.js and Codex CLI to avoid runtime download failures
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g @openai/codex@latest \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/*

WORKDIR /root

# Attack design artifacts (populated per-run by prepare_filter_context.py)
COPY attack_design.json /root/attack_design.json
COPY test_detection.py /root/test_detection.py
COPY modified_skills/ /root/modified_skills/
COPY original_skills/ /root/original_skills/

# Attack designer's agent trajectory (reasoning, tool calls, outputs)
COPY design_trajectory/ /root/design_trajectory/

# Task context
COPY pair_meta.json /root/pair_meta.json
COPY risk_type.json /root/risk_type.json
COPY task_a_instruction.md /root/task_a_instruction.md
COPY task_b_instruction.md /root/task_b_instruction.md
COPY task_a_oracle_solve.sh /root/task_a_oracle_solve.sh
COPY task_b_oracle_solve.sh /root/task_b_oracle_solve.sh
COPY baseline_summary.json /root/baseline_summary.json

# Task B Dockerfile (authoritative source for available libraries)
COPY task_b_dockerfile /root/task_b_dockerfile

# Evaluation results (may be empty)
COPY eval_results/ /root/eval_results/

# Output directory
RUN mkdir -p /root/output

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

# Scanner dependencies
RUN pip3 install --break-system-packages openai pyyaml

WORKDIR /root

# Context files (populated per-run by prepare_context.py)
COPY pair_context.json /root/pair_context.json
COPY risk_type.json /root/risk_type.json
COPY baseline_summary.json /root/baseline_summary.json
COPY task_a_instruction.md /root/task_a_instruction.md
COPY task_b_instruction.md /root/task_b_instruction.md
COPY risk_taxonomy.json /root/risk_taxonomy.json

# Shared skills (populated per-run)
COPY shared_skills/ /root/shared_skills/

# Oracle solutions and baseline trajectories (populated per-run)
COPY task_a_oracle_solve.sh /root/task_a_oracle_solve.sh
COPY task_b_oracle_solve.sh /root/task_b_oracle_solve.sh
COPY baseline_trajectories/ /root/baseline_trajectories/

# Scanner for evasion testing
COPY scan_skill_gpt.py /root/scan_skill_gpt.py
COPY scan.py /root/scan.py

# Output schema reference (so agent can find it even after context compaction)
COPY output_schema.json /root/output_schema.json

# Ground truth for verifier (agent cannot tamper - read-only copy at build time)
RUN mkdir -p /opt/ground_truth && \
    cp /root/pair_context.json /opt/ground_truth/pair_context.json && \
    cp /root/risk_type.json /opt/ground_truth/risk_type.json && \
    chmod 444 /opt/ground_truth/*.json

# Output directory
RUN mkdir -p /root/output

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base tools + Python — matches what self-mutating-poisoning/attack_design uses plus PDF libs
# the agent may need when rendering visual realizations.
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    jq \
    curl \
    ripgrep \
    && rm -rf /var/lib/apt/lists/*

# Libraries the agent may call when:
#   - rendering the PDF for redirect_to_new_pdf  (reportlab)
#   - verifying PDF content from an evaluator    (pypdf)
#   - common data handling                       (pyyaml)
#   - calling the GPT-based skill scanner        (openai)
RUN pip3 install --break-system-packages \
    reportlab==4.2.5 \
    pypdf==5.1.0 \
    pyyaml \
    openai

WORKDIR /root

# The three inputs the instruction references at /root/.
# task/  is the complete task copy (e.g. citation-check) the agent designs an attack against.
# risk_taxonomy.json  is the full 12-entry taxonomy.
# selection.json  names the risk_id + injection_target_path.
COPY task /root/task
COPY risk_taxonomy.json /root/risk_taxonomy.json
COPY selection.json /root/selection.json

# Skill scanner — GPT-backed E/W-code detector. The agent calls scan.py against
# its own poisoned samples to iterate the carrier until critical issues clear.
COPY scan.py /root/scan.py
COPY scan_skill_gpt.py /root/scan_skill_gpt.py

# Pre-computed scanner verdicts on the clean (un-poisoned) skills, one JSON per
# skill. Lives outside /root/task/ so it does NOT ride into samples when the
# agent does `cp -r task/ samples/<id>/` in Step 5.1. The agent reads these in
# Step 5.7 to subtract baseline E-codes from its poisoned-skill scan.
COPY baselines /root/baselines

# Canonical runtime glue for networked goals. The generator copies these files
# verbatim into each networked sample's environment/evaluator_runtime/ in
# Step 5.4; the structural verifier (tests/test.sh) then enforces byte-identity
# against this directory. Agents must NOT modify these files — any drift fails
# the reward gate. parse_entrypoint.py is a generation-time helper for parsing
# the source Dockerfile's ENTRYPOINT line.
COPY runtime /root/skillharm_runtime

# Agent writes outputs here. Created empty so the path exists from the start.
RUN mkdir -p /root/output

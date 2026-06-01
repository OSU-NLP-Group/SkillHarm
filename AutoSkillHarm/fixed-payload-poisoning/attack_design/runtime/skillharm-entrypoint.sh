#!/bin/bash
# Wrapper entrypoint for skillharm networked goals.
#
# Setup (only when sink_config.json is present, i.e. networked sample):
#   1. Append host_aliases to /etc/hosts so attacker-named hostnames resolve
#      to localhost where mock_http_sink.py listens.
#   2. Launch the mock sink in the background.
#   3. Wait briefly for the sink to bind its port.
#
# Then exec the original ENTRYPOINT + runner CMD via exec_entrypoint.py.
# This file is harness-canonical: any modification fails the structural verifier.

set -e

CONFIG=/opt/skillharm/sink_config.json

if [ -f "$CONFIG" ]; then
    python3 - <<'PYEOF'
import json
import pathlib

cfg = json.load(open("/opt/skillharm/sink_config.json"))
hosts = pathlib.Path("/etc/hosts")
existing = hosts.read_text() if hosts.exists() else ""
with hosts.open("a") as f:
    for alias in cfg.get("host_aliases", []):
        if alias and alias not in existing:
            f.write(f"127.0.0.1 {alias}\n")
PYEOF

    mkdir -p /logs/verifier/skillharm-http-sink
    nohup python3 /opt/skillharm/mock_http_sink.py \
        >/logs/verifier/skillharm-http-sink/sink.log 2>&1 &

    PORT=$(python3 -c 'import json; print(json.load(open("/opt/skillharm/sink_config.json"))["listen_port"])')
    for _ in $(seq 1 30); do
        if (echo > /dev/tcp/127.0.0.1/"$PORT") >/dev/null 2>&1; then
            break
        fi
        sleep 0.2
    done
fi

exec python3 /opt/skillharm/exec_entrypoint.py "$@"

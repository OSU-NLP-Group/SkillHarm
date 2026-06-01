#!/bin/bash
set -e

mkdir -p /logs/verifier
cp -r /root/output /logs/verifier/output 2>/dev/null || true

pip3 install --break-system-packages pytest==8.4.1 pytest-json-ctrf==0.3.5 -q 2>/dev/null

pytest --ctrf /logs/verifier/ctrf.json /tests/test_outputs.py -rA -v 2>&1 | tee /logs/verifier/test-stdout.txt

REWARD=$(python3 -c "
import json
with open('/logs/verifier/ctrf.json') as f:
    d = json.load(f)
tests = d.get('results', {}).get('tests', [])
failed = sum(1 for t in tests if t.get('status') == 'failed')
print('1' if failed == 0 else '0')
" 2>/dev/null || echo "0")

echo "$REWARD" > /logs/verifier/reward.txt
exit 0

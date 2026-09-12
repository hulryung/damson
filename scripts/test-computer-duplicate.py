#!/usr/bin/env python3
"""No input/capture: verify duplicate startup cannot replace a paused helper.
Usage: python3 scripts/test-computer-duplicate.py PATH_TO_CLI
The original helper must already be paused with no active session.
"""
import json
import subprocess
import sys

cli = sys.argv[1]

def status():
    reply = json.loads(subprocess.check_output([cli, 'status'], text=True, timeout=20))
    assert reply['ok'], reply
    return reply['result']

before = status()
assert before['paused'] and before['session'] is None, 'Requires an already paused helper.'
result = subprocess.run([cli, '--serve'], capture_output=True, text=True, timeout=10)
assert result.returncode != 0, ('Duplicate startup reported success', result.stderr)
assert 'already running' in result.stderr, result.stderr
after = status()
assert after['helperPID'] == before['helperPID'], (before, after)
assert after['paused'] and after['session'] is None, after
print(json.dumps({'passed': True, 'originalHelperPID': after['helperPID'],
                  'duplicateExitCode': result.returncode, 'pausedStatePreserved': True}))

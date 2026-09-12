#!/usr/bin/env python3
"""No desktop input: restart the current helper and verify old authority is gone.
Usage: python3 scripts/test-computer-restart.py CLI FIXTURE_STATE
Requires an idle helper; never resumes an external-input interruption.
"""
import json
import os
import signal
import subprocess
import sys
import time

cli, fixture_state = sys.argv[1:]

def call(command, ok=True, **arguments):
    argv = [cli, command]
    for name, value in arguments.items():
        argv += ['--' + name, str(value)]
    result = subprocess.run(argv, capture_output=True, text=True, timeout=20)
    reply = json.loads(result.stdout)
    assert reply['ok'] is ok and (result.returncode == 0) is ok, reply
    return reply['result'] if ok else reply['error']

before = call('status')
assert before['session'] is None and not before['busy'], before
assert before['pauseReason'] in [None, 'requested'], before
helper_path = before['permissions']['helperPath']
pid = json.load(open(fixture_state))['pid']
terminated = False
try:
    if before['paused']:
        call('resume')
    lease = call('acquire', pid=pid, owner='restart-acceptance', ttl=60)
    assert call('status')['session']['owner'] == 'restart-acceptance'
    os.kill(before['helperPID'], signal.SIGTERM)
    terminated = True
    end = time.monotonic() + 5
    while time.monotonic() < end:
        try:
            os.kill(before['helperPID'], 0)
        except ProcessLookupError:
            break
        time.sleep(.05)
    else:
        raise AssertionError('Original helper did not exit')
    unavailable = subprocess.run([cli, 'status'], capture_output=True, text=True, timeout=20)
    assert unavailable.returncode != 0, unavailable.stdout
    subprocess.run(['open', '-g', helper_path], check=True)
    end = time.monotonic() + 5
    while time.monotonic() < end:
        probe = subprocess.run([cli, 'status'], capture_output=True, text=True, timeout=20)
        if probe.returncode == 0:
            break
        time.sleep(.1)
    else:
        raise AssertionError('Restarted helper unavailable')
    after = call('status')
    assert after['helperPID'] != before['helperPID'], after
    assert after['session'] is None and not after['busy'], after
    assert after['permissions'] == before['permissions'], after
    assert call('windows', ok=False, session=lease['token'])['code'] == 'invalid_session'
    new_lease = call('acquire', pid=pid, owner='restart-new-lease', ttl=60)
    assert new_lease['token'] != lease['token']
    call('release', session=new_lease['token'])
    print(json.dumps({'passed': True, 'oldPID': before['helperPID'], 'newPID': after['helperPID'],
                      'oldTokenRejected': True, 'newLeaseReleased': True, 'permissionsPreserved': True}))
finally:
    # Restore availability if any assertion after termination failed.
    if terminated:
        probe = subprocess.run([cli, 'status'], capture_output=True, timeout=20)
        if probe.returncode != 0:
            subprocess.run(['open', '-g', helper_path], check=True)
            time.sleep(.5)
    call('stop')

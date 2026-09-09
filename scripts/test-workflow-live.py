#!/usr/bin/env python3
"""Run finite workflow lifecycle tests in an isolated, current-build Damson app.

No AI/API calls. Requires swift build. All test windows, files and processes are owned
by this script. Workers are only stopped through their dedicated app at cleanup.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid


def wait_for(predicate, label, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError('timed out: ' + label)


def main():
    build = Path('.build/debug').resolve()
    app = runner = None
    with tempfile.TemporaryDirectory(prefix='damson-workflow-live-', dir='/tmp') as temporary:
        root = Path(temporary)
        identifier = 'app.damson.workflow-' + uuid.uuid4().hex
        bundle = root / 'WorkflowAudit.app'
        mac = bundle / 'Contents/MacOS'
        mac.mkdir(parents=True)
        shutil.copy2(build / 'damson', mac / 'damson')
        (mac / 'Sparkle.framework').symlink_to(build / 'Sparkle.framework')
        (bundle / 'damson_damson.bundle').symlink_to(build / 'damson_damson.bundle')
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'damson', 'CFBundleIdentifier': identifier,
            'CFBundleName': 'WorkflowAudit', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1', 'NSHighResolutionCapable': True,
        }))
        (root / 'home').mkdir()
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root / 'runtime'),
                   CFFIXED_USER_HOME=str(root / 'home'), ZDOTDIR=str(root / 'home'))
        for key in ('CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ID'):
            env.pop(key, None)
        try:
            with (root / 'app.log').open('w') as log:
                app = subprocess.Popen([str(mac / 'damson')], env=env, stdout=log, stderr=log)
            socket = root / 'runtime/damson' / f'{app.pid}.sock'
            wait_for(lambda: socket.exists() or app.poll() is not None, 'isolated app socket')
            assert app.poll() is None, (root / 'app.log').read_text()[-2000:]
            plan = root / 'plan.json'
            state = root / 'state'

            def task(name, command, **kwargs):
                return dict(id=name, cwd=str(root), command=['/bin/sh', '-c', command], **kwargs)

            plan.write_text(json.dumps(dict(version=1, name='lifecycle', maxParallel=2, tasks=[
                task('a', 'echo start >> a-count; sleep 3; echo done > a', outputs=['a']),
                task('b', 'echo start >> b-count; sleep 3; echo done > b', outputs=['b']),
                task('integrate', 'cat a b > integrated', dependsOn=['a', 'b'],
                     verify=[['/bin/sh', '-c', 'test "$(wc -l < integrated | tr -d " ")" = 2']],
                     outputs=['integrated']),
                task('retry', 'if [ ! -f retry-once ]; then touch retry-once; exit 7; fi; echo ok > retried',
                     dependsOn=['integrate'], outputs=['retried'], maxAttempts=2),
            ])))
            command = [str(build / 'damson-crew'), 'workflow', 'run', '--plan', str(plan), '--state', str(state)]
            with (root / 'first.log').open('w') as log:
                runner = subprocess.Popen(command, env=env, stdout=log, stderr=log)
            wait_for(lambda: (root / 'a-count').exists() and (root / 'b-count').exists(), 'two real concurrent workers')
            assert not (root / 'integrated').exists(), 'dependency advanced too early'
            snapshot = json.loads((state / 'state.json').read_text())
            tokens = {k: v['attempt'] for k, v in snapshot['tasks'].items() if v['status'] == 'running'}
            assert set(tokens) == {'a', 'b'}
            # Concurrent coordinator is refused while the original handle is confirmed live.
            assert runner.poll() is None
            duplicate = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
            assert duplicate.returncode == 2 and 'already being operated' in duplicate.stderr
            runner.terminate()
            runner.wait(timeout=10)
            runner = None
            resumed = subprocess.run(command, env=env, capture_output=True, text=True, timeout=30)
            assert resumed.returncode == 0, resumed.stdout + resumed.stderr
            final = json.loads((state / 'state.json').read_text())
            assert all(row['status'] == 'succeeded' for row in final['tasks'].values()), final
            assert final['tasks']['retry']['attempts'] == 2
            for name in ('a', 'b'):
                assert (root / f'{name}-count').read_text() == 'start\n', 'live worker duplicated on resume'
                assert final['tasks'][name]['attempt'] == tokens[name]
            again = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
            assert again.returncode == 0 and 'attempt=2' in again.stdout
            print('PASS: real panes, parallel workers, dependency gate, coordinator restart, no duplicates, bounded retry')

            failure_plan = root / 'failure.json'
            failure_state = root / 'failure-state'
            failure_plan.write_text(json.dumps(dict(version=1, name='failure', maxParallel=2, tasks=[
                task('false-success', 'echo ready', verify=[['/usr/bin/false']]),
                task('blocked', 'touch forbidden', dependsOn=['false-success']),
                task('timeout', 'sleep 30', timeoutSeconds=.3),
            ])))
            failed = subprocess.run([str(build / 'damson-crew'), 'workflow', 'run', '--plan',
                                     str(failure_plan), '--state', str(failure_state)],
                                    env=env, capture_output=True, text=True, timeout=20)
            assert failed.returncode == 1, failed.stdout + failed.stderr
            status = json.loads((failure_state / 'state.json').read_text())['tasks']
            assert status['false-success']['status'] == 'failed'
            assert status['timeout']['status'] == 'failed' and 'timed out' in status['timeout']['message']
            assert status['blocked']['status'] == 'blocked' and not (root / 'forbidden').exists()
            print('PASS: validation failure blocks descendants; timeout fails instead of hanging')
        finally:
            for process in (runner, app):
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
            subprocess.run(['/usr/bin/defaults', 'delete', identifier], env=env, capture_output=True)


if __name__ == '__main__':
    main()

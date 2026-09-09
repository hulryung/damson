#!/usr/bin/env python3
"""Exercise managed CLI + real workers over a disposable fake Damson socket (no GUI/AI)."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

BINARY = Path(sys.argv.pop(1) if len(sys.argv) > 1 else '.build/debug/damson-crew').resolve()


class WorkflowCLI(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='workflow-cli-', dir='/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        runtime = self.root / 'runtime/damson'
        runtime.mkdir(parents=True)
        self.environment = dict(os.environ, XDG_RUNTIME_DIR=str(runtime.parent))
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(runtime / '12345.sock'))
        self.server.listen()
        self.server.settimeout(.1)
        self.processes = {}
        self.requests = []
        self.errors = []
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.serve)
        self.thread.start()
        self.addCleanup(self.cleanup)

    def cleanup(self):
        self.stop.set()
        self.thread.join(timeout=5)
        self.server.close()
        for worker in self.processes.values():
            if worker.poll() is None:
                worker.terminate()
            worker.wait(timeout=5)
        self.assertFalse(self.thread.is_alive())
        self.assertEqual(self.errors, [])

    def serve(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.server.accept()
            except socket.timeout:
                continue
            try:
                with conn:
                    conn.settimeout(3)
                    data = b''
                    while not data.endswith(b'\n'):
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        data += chunk
                    if not data:
                        continue
                    request = json.loads(data)
                    self.requests.append(request)
                    assert request['cmd'] == 'spawn-pane', request
                    spec = request['args']
                    key = spec['key']
                    if key not in self.processes:
                        self.processes[key] = subprocess.Popen(spec['argv'], cwd=spec['cwd'],
                            env=self.environment, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    response = dict(ok=True, pane=dict(index=0, cols=80, rows=24, active=False, id=key))
                    conn.sendall(json.dumps(response).encode() + b'\n')
            except Exception as error:
                self.errors.append(str(error))

    def plan(self, tasks):
        path = self.root / 'plan.json'
        path.write_text(json.dumps(dict(version=1, name='cli-test', maxParallel=2, tasks=tasks)))
        return path

    def task(self, id, shell, **kwargs):
        return dict(id=id, cwd=str(self.root), command=['/bin/sh', '-c', shell], **kwargs)

    def command(self, plan):
        return [str(BINARY), 'workflow', 'run', '--plan', str(plan), '--state', str(self.root / 'state')]

    def run_plan(self, tasks):
        return subprocess.run(self.command(self.plan(tasks)), env=self.environment,
                              capture_output=True, text=True, timeout=15)

    def test_invalid_plan_never_contacts_server(self):
        result = self.run_plan([self.task('a', 'touch bad', dependsOn=['missing'])])
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.requests, [])
        self.assertFalse((self.root / 'state').exists())

    def test_validate_is_read_only_and_needs_no_state(self):
        plan = self.plan([self.task('a', 'true')])
        result = subprocess.run([str(BINARY), 'workflow', 'validate', '--plan', str(plan)],
                                env=self.environment, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('1 tasks', result.stdout)
        self.assertEqual(self.requests, [])
        self.assertFalse((self.root / 'state').exists())

    def test_real_workers_dependencies_and_status(self):
        result = self.run_plan([
            self.task('a', 'echo one > first', outputs=['first']),
            self.task('b', 'cat first > second', dependsOn=['a'], outputs=['second'],
                      verify=[['/bin/sh', '-c', 'test "$(cat second)" = one']]),
        ])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr + repr(self.errors))
        self.assertEqual((self.root / 'second').read_text(), 'one\n')
        status = subprocess.run([str(BINARY), 'workflow', 'status', '--state', str(self.root / 'state')],
                                env=self.environment, capture_output=True, text=True, timeout=5)
        self.assertEqual(status.returncode, 0)
        self.assertTrue(all(row['status'] == 'succeeded' for row in json.loads(status.stdout)['tasks'].values()))

    def test_validation_failure_blocks_dependency(self):
        result = self.run_plan([
            self.task('a', 'true', verify=[['/usr/bin/false']]),
            self.task('b', 'touch forbidden', dependsOn=['a']),
        ])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr + repr(self.errors))
        self.assertFalse((self.root / 'forbidden').exists())
        self.assertIn('b\tblocked', result.stdout)

    def test_real_retry_is_bounded_and_keeps_logs(self):
        result = self.run_plan([self.task('a', 'echo attempt >> count; exit 7', maxAttempts=2)])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr + repr(self.errors))
        self.assertEqual((self.root / 'count').read_text(), 'attempt\nattempt\n')
        logs = list((self.root / 'state/attempts').glob('*/output.log'))
        self.assertEqual(len(logs), 2)
        self.assertTrue(all('exit 7' in p.read_text() for p in logs))

    def test_resume_keeps_same_live_attempt(self):
        plan = self.plan([self.task('a', 'echo once >> count; sleep 2; touch done', outputs=['done'])])
        first = subprocess.Popen(self.command(plan), env=self.environment,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 10
            while not (self.root / 'count').exists() and first.poll() is None and time.monotonic() < deadline:
                time.sleep(.05)
            self.assertTrue((self.root / 'count').exists(), repr(self.errors))
            self.assertIsNone(first.poll())
            first.terminate()
            first.wait(timeout=5)
            resumed = subprocess.run(self.command(plan), env=self.environment,
                                     capture_output=True, text=True, timeout=10)
            self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
            self.assertEqual((self.root / 'count').read_text(), 'once\n')
            self.assertEqual(len(self.processes), 1)
        finally:
            if first.poll() is None:
                first.terminate()
                first.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()

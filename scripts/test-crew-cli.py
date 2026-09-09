#!/usr/bin/env python3
"""CLI teardown regressions against an isolated socket and disposable git repository.

Run after `swift build --product damson-crew`:
    python3 scripts/test-crew-cli.py .build/debug/damson-crew
"""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest


BINARY = Path(sys.argv.pop(1) if len(sys.argv) > 1 else ".build/debug/damson-crew").resolve()


class CrewCLITests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="crew-cli-", dir="/tmp")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        runtime = self.root / "damson"
        runtime.mkdir()
        self.environment = dict(os.environ, XDG_RUNTIME_DIR=str(self.root))
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(runtime / "12345.sock"))
        self.server.listen()
        self.server.settimeout(0.1)
        self.requests = []
        self.connections = 0
        self.group_exists = True
        self.live_panes = []
        self.stopped = threading.Event()
        self.worker = threading.Thread(target=self.serve)
        self.worker.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.stopped.set()
        self.worker.join(timeout=2)
        self.server.close()
        self.assertFalse(self.worker.is_alive())

    def serve(self):
        while not self.stopped.is_set():
            try:
                connection, _ = self.server.accept()
            except socket.timeout:
                continue
            with connection:
                self.connections += 1
                connection.settimeout(2)
                data = b""
                while not data.endswith(b"\n"):
                    chunk = connection.recv(4096)
                    if not chunk:
                        break  # Discovery connects and disconnects without a command.
                    data += chunk
                if data:
                    request = json.loads(data)
                    self.requests.append(request)
                    response = {"ok": True}
                    if request['cmd'] == 'group-list':
                        response['groups'] = ([{'name': 'audit', 'tabs': 1, 'collapsed': False}]
                                              if self.group_exists else [])
                    elif request['cmd'] == 'group-close':
                        self.group_exists = False
                    elif request['cmd'] == 'list-agents':
                        response['panes'] = self.live_panes
                    elif request['cmd'] == 'spawn-pane':
                        self.group_exists = True
                        response['pane'] = {'index': 0, 'cols': 80, 'rows': 24,
                                            'active': False, 'id': 'fixture-pane'}
                    connection.sendall(json.dumps(response).encode() + b'\n')

    def crew(self, *options):
        return subprocess.run(
            [str(BINARY), "close", "--group", "audit", "--yes", "--remove-worktrees", *options],
            env=self.environment, capture_output=True, text=True, timeout=10,
        )

    def tasks(self, content):
        path = self.root / "tasks.json"
        path.write_text(content)
        return str(path)

    def test_missing_task_argument_never_contacts_app(self):
        result = self.crew()
        self.assertEqual(result.returncode, 2)
        self.assertIn("needs --tasks", result.stderr)
        self.assertEqual(self.connections, 0)

    def test_unreadable_task_file_never_contacts_app(self):
        result = self.crew("--tasks", str(self.root / "missing.json"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot read", result.stderr)
        self.assertEqual(self.connections, 0)

    def test_malformed_task_file_never_contacts_app(self):
        result = self.crew("--tasks", self.tasks("not json"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("could not read the task list", result.stderr)
        self.assertEqual(self.connections, 0)

    def test_cleanup_lookup_failure_is_nonzero(self):
        result = self.crew("--tasks", self.tasks(json.dumps([
            {"name": "audit", "repo": str(self.root / "missing-repo")}
        ])))
        self.assertEqual(result.returncode, 1)
        self.assertIn("could not list worktrees", result.stderr)
        self.assertEqual([r["cmd"] for r in self.requests], ["group-list", "group-close"])

    def test_stdin_tasks_are_consumed_before_close(self):
        result = subprocess.run(
            [str(BINARY), "close", "--group", "audit", "--yes", "--remove-worktrees", "--tasks", "-"],
            input='[{"name":"audit"}]', env=self.environment,
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r["cmd"] for r in self.requests], ["group-list", "group-close"])

    def repository_fixture(self, managed=True):
        repo, tree = self.root / "repo", self.root / "tree"
        subprocess.run(["git", "init", "-b", "main", str(repo)], check=True, capture_output=True)

        def git(*args):
            subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)

        git("-c", "user.name=Audit", "-c", "user.email=audit@example.com",
            "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture")
        if managed:
            path = self.tasks(json.dumps([{'name': 'audit', 'repo': str(repo), 'command': ['/bin/cat']}]))
            result = subprocess.run(
                [str(BINARY), 'run', '--tasks', path, '--group', 'audit',
                 '--worktree-root', str(self.root / 'trees'), '--no-trust-new-worktrees'],
                env=self.environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            tree = self.root / 'trees' / 'repo' / 'audit'
        else:
            git("worktree", "add", "-b", "audit", str(tree))
        return repo, tree

    def test_tilde_repository_cleanup_removes_a_clean_worktree(self):
        repo, tree = self.repository_fixture()
        tilde_repo = "~/" + os.path.relpath(repo, Path.home())
        result = self.crew("--tasks", self.tasks(json.dumps([
            {"name": "audit", "repo": tilde_repo, "branch": "audit"}
        ])))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("removed", result.stdout)
        self.assertFalse(tree.exists())

    def test_dirty_worktree_is_preserved_and_failure_reported(self):
        repo, tree = self.repository_fixture()
        notes = tree / "uncommitted.txt"
        notes.write_text("keep this work")
        result = self.crew("--tasks", self.tasks(json.dumps([
            {"name": "audit", "repo": str(repo), "branch": "audit"}
        ])))
        self.assertEqual(result.returncode, 1)
        self.assertIn("kept", result.stderr)
        self.assertEqual(notes.read_text(), "keep this work")
        # The group has already closed, but the ownership record must permit cleanup retry.
        notes.unlink()
        retry = self.crew('--tasks', str(self.root / 'tasks.json'))
        self.assertEqual(retry.returncode, 0, retry.stderr)
        self.assertFalse(tree.exists())

    def test_user_worktree_is_preserved(self):
        repo, tree = self.repository_fixture(managed=False)
        result = self.crew('--tasks', self.tasks(json.dumps([
            {'name': 'audit', 'repo': str(repo), 'branch': 'audit'}])))
        self.assertEqual(result.returncode, 1)
        self.assertIn('not created by damson-crew', result.stderr)
        self.assertTrue(tree.exists())

    def test_remaining_pane_in_worktree_subdirectory_prevents_removal(self):
        repo, tree = self.repository_fixture()
        nested = tree / 'nested'
        nested.mkdir()
        self.live_panes = [{'index': 0, 'cols': 80, 'rows': 24, 'active': False,
                            'id': 'other-pane', 'cwd': str(nested)}]
        result = self.crew('--tasks', str(self.root / 'tasks.json'))
        self.assertEqual(result.returncode, 1)
        self.assertIn('still used by an open pane', result.stderr)
        self.assertTrue(tree.exists())

    def test_concurrent_runs_keep_all_shared_owners(self):
        repo, tree = self.repository_fixture()
        processes = []
        paths = {}
        for group in ['one', 'two']:
            path = self.root / f'{group}.json'
            path.write_text(json.dumps([{'name': group, 'repo': str(repo),
                                        'branch': 'audit', 'command': ['/bin/cat']}]))
            paths[group] = path
            processes.append(subprocess.Popen(
                [str(BINARY), 'run', '--tasks', str(path), '--group', group,
                 '--no-trust-new-worktrees'], env=self.environment,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
        for process in processes:
            _, error = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 0, error)
        first = self.crew('--tasks', str(self.root / 'tasks.json'))
        self.assertEqual(first.returncode, 1)
        self.assertTrue(tree.exists())
        for group, expected in [('one', 1), ('two', 0)]:
            result = subprocess.run([str(BINARY), 'close', '--group', group, '--yes',
                                    '--remove-worktrees', '--tasks', str(paths[group])],
                                   env=self.environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, expected, result.stderr)
        self.assertFalse(tree.exists())


if __name__ == "__main__":
    unittest.main()

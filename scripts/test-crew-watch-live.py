#!/usr/bin/env python3
"""Opt-in observer/reconnect integration using an isolated current-build GUI app.

Run `swift build` first, then `python3 scripts/test-crew-watch-live.py`.
No AI is invoked. Test-owned cat PIDs publish temporary session records, removed in finally.
The script opens test windows and exercises --focus; notifications are disabled.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import queue
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--graceful-restart', action='store_true',
                        help='use Orca computer-use to quit and verify saved pane IDs restore')
    options = parser.parse_args()
    build = Path('.build/debug').resolve()
    token = 'audit-' + uuid.uuid4().hex
    identifier = 'app.damson.' + token
    records = []
    app_process = None
    watcher = None
    with tempfile.TemporaryDirectory(prefix='crew-watch-', dir='/tmp') as directory:
        root = Path(directory)
        bundle = root / 'DamsonWatchAudit.app'
        mac = bundle / 'Contents/MacOS'
        mac.mkdir(parents=True)
        shutil.copy2(build / 'damson', mac / 'damson')
        (mac / 'Sparkle.framework').symlink_to(build / 'Sparkle.framework', target_is_directory=True)
        (bundle / 'damson_damson.bundle').symlink_to(build / 'damson_damson.bundle', target_is_directory=True)
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'damson', 'CFBundleIdentifier': identifier,
            'CFBundleName': 'DamsonWatchAudit', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1', 'NSHighResolutionCapable': True,
        }))
        isolated_home = root / 'home'
        isolated_home.mkdir()
        environment = dict(os.environ, XDG_RUNTIME_DIR=str(root / 'runtime'),
                           CFFIXED_USER_HOME=str(isolated_home), ZDOTDIR=str(isolated_home))
        tasks = root / 'tasks.json'
        tasks.write_text(json.dumps([{'name': token, 'cwd': str(root), 'command': ['/bin/cat']}]))
        lines = queue.Queue()
        observed = []

        def execute(program, *args):
            result = subprocess.run([str(build / program), *args], env=environment,
                                    text=True, capture_output=True, timeout=15)
            if result.returncode:
                raise RuntimeError(f'{program}: {result.stderr}')
            return result.stdout

        def cli(*args):
            output = execute('damson-cli', '--pid', str(app_process.pid), *args)
            return json.loads(output) if output.strip() else None

        def wait_for(predicate, description, timeout=20):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if predicate():
                    return
                time.sleep(.1)
            raise AssertionError(f'timeout: {description}; events={observed}')

        def event(kind):
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                try:
                    line = lines.get(timeout=.5)
                except queue.Empty:
                    assert watcher.poll() is None, 'watcher exited'
                    continue
                observed.append(line)
                if f'\t{kind}\t{token}' in line:
                    return line
            raise AssertionError(f'missing named {kind} event; events={observed}')

        def start_app(log):
            process = subprocess.Popen([str(mac / 'damson'), '-damson.tabBarStyle', 'compact'],
                                       env=environment, stdout=log, stderr=log)
            socket = root / 'runtime/damson' / f'{process.pid}.sock'
            try:
                wait_for(lambda: process.poll() is not None or socket.exists(), 'app socket')
                assert process.poll() is None, 'app failed to launch'
                return process
            except BaseException:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
                raise

        def own_record(pid):
            folder = isolated_home / '.claude/sessions'
            folder.mkdir(parents=True, exist_ok=True)
            path = folder / f'{pid}.json'
            with path.open('x') as file:
                json.dump({'sessionId': token, 'pid': pid, 'status': 'busy', 'cwd': str(root)}, file)
            records.append(path)
            return path

        def change(path, status, question=None):
            data = json.loads(path.read_text())
            assert data['sessionId'] == token, 'fixture record ownership changed'
            data['status'] = status
            if question is not None:
                data['waitingFor'] = question
            else:
                data.pop('waitingFor', None)
            path.write_text(json.dumps(data))

        def remove_record(path):
            if path.exists():
                assert json.loads(path.read_text())['sessionId'] == token
                path.unlink()
            records.remove(path)

        try:
            with (root / 'app.log').open('w') as app_log, (root / 'watch.err').open('w') as watch_error:
                app_process = start_app(app_log)
                watcher = subprocess.Popen([
                    str(build / 'damson-crew'), 'watch', '--tasks', str(tasks), '--focus',
                    '--no-notify', '--no-notify-done'], env=environment,
                    text=True, stdout=subprocess.PIPE, stderr=watch_error, bufsize=1)

                def read_lines():
                    for line in watcher.stdout:
                        lines.put(line.rstrip())

                reader = threading.Thread(target=read_lines, daemon=True)
                reader.start()
                first_pid = app_process.pid
                first_pane = None
                for iteration in range(2):
                    output = execute('damson-crew', 'run', '--tasks', str(tasks), '--group', token,
                                     '--no-skip-permissions', '--no-trust-new-worktrees')
                    pane = output.strip().split('\t')[1]
                    if first_pane is None:
                        first_pane = pane
                    elif options.graceful_restart:
                        assert pane == first_pane, 'restart did not reattach to the restored pane'
                    info = cli('--pane', pane, 'pane-info')
                    record = own_record(info['pid'])
                    event('started')
                    cli('spawn', '--cwd', str(root), '--group', token, '--title', 'audit-decoy', '--', '/bin/cat')
                    change(record, 'waiting', f'fixture question {iteration}')
                    assert f'fixture question {iteration}' in event('WAITING')
                    wait_for(lambda: cli('pane-info')['id'] == pane, 'focus named waiting pane')
                    change(record, 'busy')
                    event('resumed')
                    change(record, 'idle')
                    event('FINISHED')
                    remove_record(record)
                    event('ended')
                    if iteration == 0:
                        if options.graceful_restart:
                            result = subprocess.run(['orca', 'computer', 'hotkey', '--app', identifier,
                                '--key', 'CmdOrCtrl+Q', '--restore-window', '--no-screenshot', '--json'],
                                capture_output=True, text=True, timeout=20)
                            state = json.loads(result.stdout)
                            assert state['ok'], state
                            tree = state['result']['snapshot']['treeText']
                            match = re.search(r'^\s*(\d+) button Quit(?:,|$)', tree, re.MULTILINE)
                            assert match, f'no Quit confirmation in fresh UI: {tree}'
                            result = subprocess.run(['orca', 'computer', 'click', '--app', identifier,
                                '--element-index', match[1], '--no-screenshot', '--json'],
                                capture_output=True, text=True, timeout=20)
                            # Closing the app can end observation; process exit is the assertion.
                        else:
                            app_process.terminate()
                        app_process.wait(timeout=10)
                        app_process = start_app(app_log)
                        assert app_process.pid != first_pid
                        assert watcher.poll() is None, 'watcher did not survive restart'
                # Real app/CLI/git lifecycle, sharing one crew-created checkout.
                repo = root / 'repo'
                subprocess.run(['git', 'init', '-b', 'main', str(repo)], check=True, capture_output=True)
                subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Audit',
                                '-c', 'user.email=audit@example.com', '-c', 'commit.gpgsign=false',
                                'commit', '--allow-empty', '-m', 'fixture'], check=True, capture_output=True)
                tree = root / 'trees/repo/shared'
                lists = []
                for owner in ['one', 'two']:
                    task_file = root / f'{owner}.json'
                    task_file.write_text(json.dumps([{'name': owner, 'repo': str(repo),
                        'branch': 'shared', 'command': ['/bin/cat']}]))
                    lists.append(task_file)
                    execute('damson-crew', 'run', '--tasks', str(task_file), '--group', owner,
                            '--worktree-root', str(root / 'trees'), '--no-trust-new-worktrees')
                result = subprocess.run([str(build / 'damson-crew'), 'close', '--group', 'one',
                    '--yes', '--remove-worktrees', '--tasks', str(lists[0])], env=environment,
                    capture_output=True, text=True, timeout=20)
                assert result.returncode == 1 and 'still shared' in result.stderr, result.stderr
                assert tree.exists()
                note = tree / 'notes.txt'
                note.write_text('preserve the unfinished work')
                result = subprocess.run([str(build / 'damson-crew'), 'close', '--group', 'two',
                    '--yes', '--remove-worktrees', '--tasks', str(lists[1])], env=environment,
                    capture_output=True, text=True, timeout=20)
                assert result.returncode == 1, result.stderr
                assert note.read_text() == 'preserve the unfinished work'
                note.unlink()
                execute('damson-crew', 'close', '--group', 'two', '--yes',
                        '--remove-worktrees', '--tasks', str(lists[1]))
                assert not tree.exists(), 'cleanup retry left the shared worktree behind'
                print('PASS: live shared-worktree protection, dirty refusal, and cleanup retry')
                assert 'could not focus' not in (root / 'watch.err').read_text()
                print('PASS: live registry → stream → named watcher events → exact-pane focus')
                if options.graceful_restart:
                    print('PASS: graceful app quit/relaunch preserves task pane ID and reattaches')
                print('PASS: same watcher reconnects to new app PID and repeats busy/waiting/idle/vanished flow')
        finally:
            for path in records[:]:
                remove_record(path)
            if watcher is not None and watcher.poll() is None:
                watcher.terminate()
                watcher.wait(timeout=10)
            if app_process is not None and app_process.poll() is None:
                app_process.terminate()
                app_process.wait(timeout=10)
            subprocess.run(['defaults', 'delete', identifier], env=environment, capture_output=True)


if __name__ == '__main__':
    main()

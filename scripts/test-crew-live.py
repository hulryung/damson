#!/usr/bin/env python3
"""Opt-in smoke test against a running Damson; closes only its uniquely named groups.

python3 scripts/test-crew-live.py --pid PID [--bin-dir .build/debug]
Uses local shell fixtures, not AI agents. The app will briefly display test tabs.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--bin-dir', type=Path, default=Path('.build/debug'))
    args = parser.parse_args()
    binaries = args.bin_dir.resolve()

    def cli(*options):
        result = subprocess.run([str(binaries / 'damson-cli'), '--pid', str(args.pid), *options],
                                capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return json.loads(result.stdout)

    def crew(*options, code=0):
        result = subprocess.run([str(binaries / 'damson-crew'), *options, '--pid', str(args.pid)],
                                capture_output=True, text=True, timeout=20)
        if result.returncode != code:
            raise RuntimeError(f'expected exit {code}, got {result.returncode}: {result.stderr}')
        return result

    token = 'crew-live-' + uuid.uuid4().hex[:12]
    groups = [token + '-a', token + '-b']
    before = {p['id'] for p in cli('agents')}
    with tempfile.TemporaryDirectory(prefix=token + '-') as directory:
        root = Path(directory)
        marker = root / 'started.txt'

        def task(name, label, cwd=None):
            return {'name': name, 'cwd': str(cwd or root), 'command': [
                '/bin/sh', '-c', 'printf "%s\\n" "$1" >> "$2"; exec /bin/cat',
                'crew-fixture', label, str(marker)]}

        def tasks(filename, rows):
            path = root / filename
            path.write_text(json.dumps(rows))
            return str(path)

        first = tasks('first.json', [task(token, 'first')])
        second = tasks('second.json', [task(token, 'second'),
                                      task(token + '-bad', 'bad', root / 'missing'),
                                      task(token + '-healthy', 'healthy')])
        try:
            original = crew('run', '--tasks', first, '--group', groups[0],
                            '--no-trust-new-worktrees', '--no-skip-permissions')
            retry = crew('run', '--tasks', first, '--group', groups[0],
                         '--no-trust-new-worktrees', '--no-skip-permissions')
            assert original.stdout == retry.stdout, 'retry opened a different pane'
            crew('run', '--tasks', second, '--group', groups[1],
                 '--no-trust-new-worktrees', '--no-skip-permissions', code=1)
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                started = marker.read_text().splitlines() if marker.exists() else []
                if len(started) >= 3:
                    break
                time.sleep(0.1)
            assert sorted(started) == ['first', 'healthy', 'second'], started
            panes = [p for p in cli('agents') if p.get('group') in groups]
            assert len(panes) == 3, f'expected 3 test panes, got {len(panes)}'
            assert len({p['id'] for p in panes}) == 3
            state = crew('status', '--tasks', first, '--group', groups[0])
            assert original.stdout.strip().split('\t')[1] in state.stdout
            print('PASS: real spawn, idempotent retry, group isolation, partial failure, status')
        finally:
            for group in groups:
                result = subprocess.run([str(binaries / 'damson-crew'), 'close', '--group', group,
                                         '--yes', '--pid', str(args.pid)],
                                        capture_output=True, text=True, timeout=20)
                if result.returncode and 'no such group' not in result.stderr:
                    raise RuntimeError(f'could not close test group {group}: {result.stderr}')
        after = cli('agents')
        assert not any(p.get('group') in groups for p in after), 'test panes remain'
        assert before.issubset({p['id'] for p in after}), 'a pre-existing pane disappeared'
        print('PASS: test groups removed; pre-existing panes preserved')


if __name__ == '__main__':
    main()

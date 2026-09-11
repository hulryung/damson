#!/usr/bin/env python3
"""Read-only game-state observer plus actual damson-computer input.
Run only with the desktop available and helper resumed by the user.
Target: computer-game.swift hosting the Snake acceptance artifact over loopback HTTP.
"""
import json
import pathlib
import subprocess
import sys
import time

cli = sys.argv[1]
state_file = pathlib.Path('/tmp/damson-computer-game-state.json')

def state():
    return json.loads(state_file.read_text())

def call(command, **args):
    argv = [cli, command]
    for key, value in args.items():
        argv += ['--' + key, str(value)]
    result = json.loads(subprocess.check_output(argv, text=True, timeout=20))
    assert result['ok'], result
    return result['result']

def wait(predicate):
    until = time.monotonic() + 4
    while time.monotonic() < until:
        result = state()
        if predicate(result):
            return result
        time.sleep(.05)
    raise AssertionError(state())

assert not call('status')['paused'], 'Wait for the user and explicitly resume first.'
lease = call('acquire', pid=state()['pid'], owner='snake-playtest', ttl=60)
session = lease['token']
try:
    call('focus', session=session)
    time.sleep(.3)
    windows = call('windows', session=session)['windows']
    window = next(w for w in windows if w['title'] == 'Damson Computer Game Acceptance')
    before = call('capture', session=session, window=window['id'])
    wait(lambda s: s['state'] == 'ready')
    call('key', session=session, key='space')
    running = wait(lambda s: s['state'] == 'running')
    call('key', session=session, key='down')
    wait(lambda s: any(k['key'] == 'ArrowDown' and k['trusted'] for k in s['keys']))
    wait(lambda s: s['canvasHash'] != running['canvasHash'])
    call('key', session=session, key='space')
    wait(lambda s: s['state'] == 'paused')
    playing = call('capture', session=session, window=window['id'])
    # Find the real Restart control through Accessibility, never JS-invoke its handler.
    def walk(node):
        yield node
        for child in node.get('children', []):
            yield from walk(child)
    tree = call('inspect', session=session)['tree']
    restart = next(n for n in walk(tree) if n.get('AXRole') == 'AXButton'
                   and 'Restart' in (n.get('AXTitle', '') + n.get('AXDescription', '')))
    call('press', session=session, element=restart['id'])
    wait(lambda s: s['state'] == 'running')
    restarted = call('capture', session=session, window=window['id'])
    print(json.dumps({'passed': True, 'artifacts': lease['artifacts'],
                      'captures': [before, playing, restarted],
                      'checks': ['start', 'trusted direction input', 'canvas changes', 'pause', 'AX restart']}, indent=2))
finally:
    call('stop')

#!/usr/bin/env python3
"""Web viewport acceptance against scripts/fixtures/computer-scroll.swift.
Start the fixture, then pass CLI, state file, and fixture executable paths.
Requires a running helper with Accessibility and Screen Recording permission.
"""
import json
import pathlib
import subprocess
import sys
import time

cli, state_path, fixture_binary = sys.argv[1:]
state_path = pathlib.Path(state_path)
pid = json.loads(state_path.read_text())["pid"]

def call(command, ok=True, **args):
    argv = [cli, command]
    for key, value in args.items():
        argv.extend(["--" + key.replace("_", "-"), str(value)])
    process = subprocess.run(argv, capture_output=True, text=True, timeout=20)
    result = json.loads(process.stdout)
    assert result["ok"] is ok, (argv, result)
    assert (process.returncode == 0) is ok, (argv, process.returncode)
    return result["result"] if ok else result["error"]

def state():
    return json.loads(state_path.read_text())

def wait_for(predicate):
    end = time.monotonic() + 4
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError(state())

# Never override a human stop implicitly. The test operator must resume explicitly.
initial_status = call("status")
assert not initial_status["paused"], "Helper is paused; wait for the user and resume explicitly."
assert initial_status["session"] is None, "Another session owns the desktop."
assert initial_status["permissions"]["accessibility"], "Grant Accessibility to the packaged helper first."
assert initial_status["permissions"]["screenRecording"], "Grant Screen Recording to the packaged helper first."
lease = call("acquire", pid=pid, owner="web-scroll-acceptance", ttl=120)
token = lease["token"]
occluder = None
try:
    error = call("acquire", ok=False, pid=pid, owner="other-workflow")
    assert error["code"] == "busy", error
    assert call("key", ok=False, session=token, key="a", pid=pid)["code"] == "invalid_argument"
    call("focus", session=token)
    time.sleep(.3)
    window = next(w for w in call("windows", session=token)["windows"] if w["title"] == "Damson Computer Scroll Acceptance")
    bounds = window["bounds"]
    call("click", session=token, x=bounds["x"]+200, y=bounds["y"]+200)
    for axis, delta in [("dy",-150),("dy",150),("dx",-150),("dx",150)] * 2:
        before = state()
        call("scroll", session=token, dy=delta if axis=="dy" else 0, dx=delta if axis=="dx" else 0)
        coordinate = "y" if axis=="dy" else "x"
        wait_for(lambda: (state()[coordinate]-before[coordinate]) * delta < 0)
        time.sleep(.3)
        after = state()
        assert after["wheelEvents"][-1]["trusted"], after
        assert abs(after[coordinate] - (before[coordinate] - delta)) <= 1, after
        print(json.dumps({"axis":axis,"delta":delta,"before":before[coordinate],"after":after[coordinate]}), flush=True)
    # A foreign floating window must still block coordinate input even though
    # remote WebKit content is now recognized as belonging to its host window.
    occluder = subprocess.Popen([fixture_binary, "--occluder"])
    wait_for(lambda: any(app["pid"] == occluder.pid for app in call("apps")["apps"]))
    time.sleep(.3)
    call("focus", session=token)
    time.sleep(.2)
    assert call("click", ok=False, session=token, x=bounds["x"]+200, y=bounds["y"]+200)["code"] == "target_occluded"
    assert call("scroll", ok=False, session=token, dy=-150)["code"] == "target_occluded"
    occluder.terminate()
    occluder.wait(timeout=5)
    occluder = None
    capture = call("capture", session=token, window=window["id"])
    print(json.dumps({"passed":True,"capture":capture,"artifacts":lease["artifacts"]}),flush=True)
finally:
    try:
        call("stop")
    finally:
        if occluder is not None:
            occluder.terminate()
            occluder.wait(timeout=5)

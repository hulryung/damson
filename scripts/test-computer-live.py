#!/usr/bin/env python3
"""Acceptance against scripts/fixtures/computer-target.swift, never a user app.
Start fixture with DAMSON_COMPUTER_FIXTURE_STATE, then pass its state file.
Requires a running helper with Accessibility and Screen Recording permission.
"""
import json
import pathlib
import subprocess
import sys
import time
import uuid

cli, state_path = sys.argv[1:]
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

def flatten(node):
    yield node
    for child in node.get("children", []):
        yield from flatten(child)

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
assert not call("status")["paused"], "Helper is paused; wait for the user and resume explicitly."
lease = call("acquire", pid=pid, owner="native-acceptance", ttl=120)
token = lease["token"]
try:
    error = call("acquire", ok=False, pid=pid, owner="other-workflow")
    assert error["code"] == "busy"
    assert call("key", ok=False, session=token, key="a", pid=pid)["code"] == "invalid_argument"
    call("focus", session=token)
    time.sleep(.3)
    tree = call("inspect", session=token)
    nodes = list(flatten(tree["tree"]))
    button = next(node for node in nodes if node.get("AXTitle") == "Increment")
    field = next(node for node in nodes if node.get("AXRole") == "AXTextField")
    count = state()["count"]
    request_id = str(uuid.uuid4())
    call("press", session=token, element=button["id"], request_id=request_id)
    call("press", session=token, element=button["id"], request_id=request_id)
    wait_for(lambda: state()["count"] == count + 1)
    bounds = button["bounds"]
    call("click", session=token, x=bounds["x"]+bounds["width"]/2, y=bounds["y"]+bounds["height"]/2)
    wait_for(lambda: state()["count"] == count + 2)
    bounds = field["bounds"]
    call("click", session=token, x=bounds["x"]+30, y=bounds["y"]+bounds["height"]/2)
    call("key", session=token, key="cmd+a")
    call("type", session=token, text="Damson 한글 🎮")
    wait_for(lambda: state()["text"] == "Damson 한글 🎮")
    windows = call("windows", session=token)["windows"]
    window = next(value for value in windows if value["title"] == "Damson Computer Acceptance")
    capture = call("capture", session=token, window=window["id"])
    assert pathlib.Path(capture["path"]).read_bytes().startswith(b"\x89PNG")
    assert capture["pixelWidth"] > 0 and capture["scaleX"] > 0
    assert call("click", ok=False, session=token, x=-100000, y=-100000)["code"] == "target_occluded"
    scroll = next(node for node in nodes if node.get("AXRole") == "AXScrollArea")
    bounds = scroll["bounds"]
    call("click", session=token, x=bounds["x"]+100, y=bounds["y"]+100)
    call("scroll", session=token, dy=-150)
    wait_for(lambda: state().get("scroll", 0) > 0)
    call("stop")
    assert call("key", ok=False, session=token, key="a")["code"] == "paused"
    call("resume")
    assert call("key", ok=False, session=token, key="a")["code"] == "invalid_session"
    print(json.dumps({"passed": True, "artifacts": lease["artifacts"], "capture": capture,
                      "checks": ["global exclusion", "strict arguments", "AX press", "request deduplication",
                                 "coordinate click", "Unicode typing", "keyboard shortcut", "screenshot",
                                 "occlusion guard", "scroll", "stop/revoke"]}, indent=2))
finally:
    call("stop")

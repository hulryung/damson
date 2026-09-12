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
initial_status = call("status")
assert not initial_status["paused"], "Helper is paused; wait for the user and resume explicitly."
assert initial_status["session"] is None, "Another session owns the desktop."
assert initial_status["permissions"]["accessibility"], "Grant Accessibility to the packaged helper first."
assert initial_status["permissions"]["screenRecording"], "Grant Screen Recording to the packaged helper first."
lease = call("acquire", pid=pid, owner="native-acceptance", ttl=120)
token = lease["token"]
typing = None
try:
    error = call("acquire", ok=False, pid=pid, owner="other-workflow")
    assert error["code"] == "busy", error
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
    wait_for(lambda: state().get("editing") is True)
    selection_length = len(state()["text"].encode("utf-16-le")) // 2
    call("key", session=token, key="cmd+a")
    wait_for(lambda: state().get("selectionLength") == selection_length)
    call("type", session=token, text="Damson 한글 🎮")
    wait_for(lambda: state()["text"] == "Damson 한글 🎮")
    windows = call("windows", session=token)["windows"]
    window = next(value for value in windows if value["title"] == "Damson Computer Acceptance")
    capture = call("capture", session=token, window=window["id"])
    assert pathlib.Path(capture["path"]).read_bytes().startswith(b"\x89PNG")
    assert capture["pixelWidth"] > 0 and capture["scaleX"] > 0
    assert call("click", ok=False, session=token, x=-100000, y=-100000)["code"] == "target_occluded"
    call("focus", session=token)
    wait_for(lambda: any(app["pid"] == pid and app["active"] for app in call("apps")["apps"]))
    scroll = next(node for node in nodes if node.get("AXRole") == "AXScrollArea")
    bounds = scroll["bounds"]
    call("click", session=token, x=bounds["x"]+100, y=bounds["y"]+100)
    time.sleep(.1)
    call("scroll", session=token, dy=-150)
    wait_for(lambda: state().get("scroll", 0) > 0)
    # Stop must remain responsive while a long Unicode input is in flight.
    # Observe the real editor before stopping; a short sleep cannot prove partial input.
    bounds = field["bounds"]
    call("click", session=token, x=bounds["x"]+30, y=bounds["y"]+bounds["height"]/2)
    wait_for(lambda: state().get("editing") is True)
    selection_length = len(state()["text"].encode("utf-16-le")) // 2
    call("key", session=token, key="cmd+a")
    wait_for(lambda: state().get("selectionLength") == selection_length)
    payload = "x" * 3000
    typing = subprocess.Popen([cli, "type", "--session", token, "--text", payload],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    wait_for(lambda: 20 <= len(state()["text"]) < len(payload)
             and state()["text"] == "x" * len(state()["text"]))
    assert call("status")["busy"], "Typing finished before cancellation could be tested."
    call("stop")
    stdout, stderr = typing.communicate(timeout=5)
    interrupted = json.loads(stdout)
    assert typing.returncode != 0 and not interrupted["ok"], (stdout, stderr)
    assert interrupted["error"]["code"] == "paused", interrupted
    # Allow already-dispatched events to drain, then ensure no new text arrives.
    time.sleep(.2)
    stopped_text = state()["text"]
    assert 0 < len(stopped_text) < len(payload), state()
    until = time.monotonic() + .5
    while time.monotonic() < until:
        assert state()["text"] == stopped_text, "Input continued after Stop."
        time.sleep(.05)
    stopped = call("status")
    assert not stopped["busy"] and stopped["session"] is None, stopped
    assert stopped["pauseReason"] == "requested", "A user interruption must not be resumed by this test."
    assert call("key", ok=False, session=token, key="a")["code"] == "paused"
    call("resume")
    assert call("key", ok=False, session=token, key="a")["code"] == "invalid_session"
    print(json.dumps({"passed": True, "artifacts": lease["artifacts"], "capture": capture,
                      "checks": ["global exclusion", "strict arguments", "AX press", "request deduplication",
                                 "coordinate click", "Unicode typing", "keyboard shortcut", "screenshot",
                                 "occlusion guard", "scroll", "stop/revoke", "long input cancellation"]}, indent=2))
finally:
    try:
        call("stop")
    finally:
        if typing is not None and typing.poll() is None:
            try:
                typing.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                typing.kill()
                typing.communicate(timeout=5)

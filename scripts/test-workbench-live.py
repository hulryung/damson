#!/usr/bin/env python3
"""Verify provider-neutral agent reports in an explicitly selected Damson instance.

Creates one temporary pane in its own window and closes only that pane. No AI
service is used. Pass --runtime when testing an isolated XDG_RUNTIME_DIR instance.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--runtime")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    cli = repo / ".build/debug/damson-cli"
    env = dict(os.environ)
    if args.runtime:
        env["XDG_RUNTIME_DIR"] = args.runtime

    def execute(*arguments):
        result = subprocess.run([str(cli), "--pid", str(args.pid), *arguments], env=env,
                                text=True, capture_output=True, timeout=10)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() else None

    with tempfile.TemporaryDirectory(prefix="damson-agent-hook-") as directory:
        root = Path(directory)
        state = root / "state"
        state.write_text("unknown")
        script = root / "fixture.py"
        script.write_text('''import pathlib, sys, time
state = pathlib.Path(sys.argv[1])
previous = None
while True:
    value = state.read_text().strip()
    if value != previous:
        sys.stdout.write("\\x1b]777;damson;agent;" + value + "\\x07")
        sys.stdout.flush()
        previous = value
    time.sleep(.05)
''')
        pane = execute("spawn", "--cwd", str(root), "--title", "Agent hook audit",
                       "--window", "audit-" + uuid.uuid4().hex,
                       "--", "/usr/bin/python3", str(script), str(state))["id"]
        try:
            for status in ["running", "waiting", "completed", "failed", "unknown", "clear"]:
                state.write_text(status)
                expected = None if status == "clear" else status
                deadline = time.monotonic() + 6
                while time.monotonic() < deadline:
                    observed = execute("--pane", pane, "pane-info")
                    if observed.get("agent") == expected:
                        break
                    time.sleep(.1)
                else:
                    raise AssertionError((status, observed))
                assert observed["id"] == pane
                print("PASS:", status)
            execute("--pane", pane, "reveal-pane")
        finally:
            execute("--pane", pane, "close-pane")


if __name__ == "__main__":
    main()

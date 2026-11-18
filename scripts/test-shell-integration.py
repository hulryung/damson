#!/usr/bin/env python3
"""Run damson's shell integration in real interactive shells on a PTY.

Each shell gets a throwaway HOME whose startup files announce themselves and set the
kind of hooks users have (a PROMPT_COMMAND, a DEBUG trap, a PS1 showing $?), then is
started with exactly the argv/env `ShellIntegration.prepare` returns. Checked:

- the user's startup files run, in the shell's own order for login vs non-login
- the variables used for injection (ENV, XDG_DATA_DIRS, ...) are put back
- OSC 133 C / D;status / A and OSC 7 arrive, and an empty Enter starts no command
- the user's own hooks still run and still see the command's exit status

Shells that aren't installed are skipped (fish, Homebrew bash), never failed.
"""
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ESC = b"\x1b"
ST = b"\x1b\\"


def osc133(kind):
    return ESC + b"]133;" + kind


AUDIT = r'''
import Foundation
enum PTYHost {
    static func resolveProgram(_ p: String, env: [String: String]) -> String? {
        if p.contains("/") { return p }
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let path = "\(dir)/\(p)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
@main enum Audit {
    static func main() throws {
        let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
        let root = URL(fileURLWithPath: input["root"] as! String)
        let out = ShellIntegration.prepare(argv: input["argv"] as! [String],
                                           env: input["env"] as! [String: String], root: root)
        let data = try JSONSerialization.data(withJSONObject: ["argv": out.argv, "env": out.env])
        FileHandle.standardOutput.write(data)
    }
}
'''


class Shell:
    """An interactive shell on a PTY that answers the terminal queries fish waits for."""

    def __init__(self, argv, env, cwd):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.chdir(cwd)
                os.execve(argv[0], argv, env)
            finally:
                os._exit(127)
        self.out = b""

    def pump(self, until=None, timeout=6):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if until is not None and until(self.out):
                return
            try:
                ready = select.select([self.fd], [], [], .05)[0]
                if not ready:
                    continue
                data = os.read(self.fd, 65536)
            except OSError:
                break
            self.out += data
            if b"\x1b[0c" in data or b"\x1b[c" in data:
                os.write(self.fd, b"\x1b[?62;22c")
            if b"\x1b[6n" in data:
                os.write(self.fd, b"\x1b[1;1R")
        if until is not None and not until(self.out):
            raise AssertionError(f"timed out; output so far:\n{self.out[-3000:]!r}")

    def prompts(self):
        return self.out.count(osc133(b"A"))

    def run(self, line):
        """Type a line and wait for the prompt after it."""
        before = self.prompts()
        os.write(self.fd, line.encode() + b"\r")
        self.pump(lambda out: out.count(osc133(b"A")) > before)
        self.settle()
        return self.out

    def settle(self, quiet=.3):
        """Read until the shell has been silent for `quiet` seconds."""
        while True:
            size = len(self.out)
            self.pump(timeout=quiet)
            if len(self.out) == size:
                return

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        # Close the master first: on macOS a process exiting with unread output on its
        # terminal waits for it to drain, so waiting before closing never returns.
        os.close(self.fd)
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


def lifecycle(out):
    """OSC 133 C / D / A events in order, extra parameters dropped (fish adds some)."""
    return [m.decode() for m in re.findall(rb"\x1b\]133;(C|D;\d+|A)[^\x1b\x07]*", out)]


def text(out):
    return re.sub(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", b"", out).decode(errors="replace")


class Harness:
    def __init__(self, repo, root):
        self.root = root
        source = root / "audit.swift"
        source.write_text(AUDIT)
        self.binary = root / "audit"
        subprocess.run(["swiftc", "-parse-as-library",
                        str(repo / "Sources/DamsonTerminal/ShellIntegration.swift"),
                        str(source), "-o", str(self.binary)], check=True)
        self.failures = []
        self.count = 0

    def prepare(self, argv, env):
        request = {"root": str(self.root / "integration"), "argv": argv, "env": env}
        result = subprocess.run([str(self.binary)], input=json.dumps(request).encode(),
                                capture_output=True, check=True)
        out = json.loads(result.stdout)
        return out["argv"], out["env"]

    def home(self, name, files):
        self.homes = getattr(self, "homes", 0) + 1
        home = self.root / f"{self.homes:02d}-{name}"
        home.mkdir()
        for rel, body in files.items():
            path = home / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
        return home

    def check(self, name, test):
        self.count += 1
        try:
            test()
            print(f"PASS: {name}")
        except AssertionError as error:
            self.failures.append(name)
            print(f"FAIL: {name}\n  {error}")


def base_env(home, extra=None):
    env = {"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
           "TERM": "xterm-256color", "BASH_SILENCE_DEPRECATION_WARNING": "1",
           "USER": os.environ.get("USER", "user")}
    env.update(extra or {})
    return env


def expect(cond, message):
    if not cond:
        raise AssertionError(message)


def common_lifecycle(shell, workdir):
    """false → C, D;1; true → C, D;0; empty Enter → no C; OSC 7 names the cwd."""
    shell.pump(lambda out: osc133(b"A") in out)
    shell.settle()
    mark = len(shell.out)
    shell.run("false")
    shell.run("true")
    shell.run("")
    events = lifecycle(shell.out[mark:])
    expect(events == ["C", "D;1", "A", "C", "D;0", "A", "A"],
           f"lifecycle events {events}")
    expect(f"]7;file://".encode() in shell.out and str(workdir).encode() in shell.out,
           "no OSC 7 with the working directory")


BASH_FILES = {
    ".bash_profile": "echo LOAD:bash_profile\n",
    ".bash_login": "echo LOAD:bash_login\n",
    ".profile": "echo LOAD:profile\n",
    ".bashrc": "echo LOAD:bashrc\n",
}

BASH_HOOKS = r'''
_user_pc() { echo "USERPC:$?"; }
PROMPT_COMMAND=_user_pc
_user_debug_count=0
trap '_user_debug_count=$((_user_debug_count+1))' DEBUG
PS1='[ps1:$?] $ '
'''


def bash_case(h, bash, flags, login):
    files = dict(BASH_FILES)
    # The hooks go in whichever file this kind of shell reads.
    files[".bash_profile" if login else ".bashrc"] += BASH_HOOKS
    home = h.home(f"home-{Path(bash).parent.name}-{'login' if login else 'interactive'}", files)
    argv, env = h.prepare([bash] + flags, base_env(home, {"ENV": "/original/env"}))
    shell = Shell(argv, env, home)
    try:
        shell.pump(lambda out: osc133(b"A") in out)
        loaded = re.findall(r"LOAD:(\w+)", text(shell.out))
        expected = ["bash_profile"] if login else ["bashrc"]
        expect(loaded == expected, f"startup files {loaded}, expected {expected}")
        common_lifecycle(shell, home)
        out = text(shell.run("false"))
        expect("USERPC:1" in out, f"user PROMPT_COMMAND did not see $?=1: {out[-200:]!r}")
        expect("[ps1:1]" in out, f"PS1 did not see $?=1: {out[-200:]!r}")
        out = text(shell.run('echo "ENV=[${ENV-unset}] POSIX=$(shopt -qo posix && echo on || echo off) '
                             'DBG=$_user_debug_count LEAK=[${DAMSON_BASH_INTEGRATION-}${DAMSON_BASH_ENV-}]"'))
        expect("ENV=[/original/env]" in out, f"ENV not restored: {out[-300:]!r}")
        expect("POSIX=off" in out, "still in POSIX mode")
        found = re.search(r"DBG=(\d+)", out)
        expect(found and int(found.group(1)) > 0, f"user DEBUG trap never ran: {out[-300:]!r}")
        expect("LEAK=[]" in out, f"injection variables leaked: {out[-300:]!r}")
    finally:
        shell.close()


def bash_tests(h):
    for bash in ["/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"]:
        if not os.path.exists(bash):
            print(f"SKIP: {bash} not installed")
            continue
        version = subprocess.check_output([bash, "-c", "echo $BASH_VERSION"], text=True).strip()
        h.check(f"bash {version} login (-l)", lambda b=bash: bash_case(h, b, ["-l"], True))
        h.check(f"bash {version} interactive (-i)", lambda b=bash: bash_case(h, b, ["-i"], False))
    # A bash given a command is left alone.
    def untouched():
        argv, env = h.prepare(["/bin/bash", "-c", "echo hi"], base_env(h.root))
        expect(argv == ["/bin/bash", "-c", "echo hi"] and "ENV" not in env, f"rewrote {argv}")
    h.check("bash -c is not rewritten", untouched)


def zsh_tests(h):
    def case():
        home = h.home("home-zsh", {
            ".zshenv": "echo LOAD:zshenv\n",
            ".zprofile": "echo LOAD:zprofile\n",
            ".zshrc": "echo LOAD:zshrc\nPS1='%# '\n",
            ".zlogin": "echo LOAD:zlogin\n",
        })
        argv, env = h.prepare(["/bin/zsh", "-l"], base_env(home))
        shell = Shell(argv, env, home)
        try:
            shell.pump(lambda out: osc133(b"A") in out)
            shell.run("")   # .zlogin runs after .zshrc's first prompt mark
            loaded = re.findall(r"LOAD:(\w+)", text(shell.out))
            expect(loaded == ["zshenv", "zprofile", "zshrc", "zlogin"], f"startup files {loaded}")
            common_lifecycle(shell, home)
        finally:
            shell.close()
    h.check("zsh login (-l)", case)


def fish_tests(h):
    fish = shutil.which("fish", path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    if not fish:
        print("SKIP: fish not installed")
        return
    version = subprocess.check_output([fish, "--version"], text=True).split()[-1]
    major = int(version.split(".")[0])

    def case(force):
        home = h.home(f"home-fish-{force}", {
            ".config/fish/config.fish": "echo LOAD:config.fish\n",
        })
        extra = {"XDG_DATA_DIRS": "/original/share"}
        if force:
            extra["DAMSON_FISH_FORCE_HOOKS"] = "1"
        argv, env = h.prepare([fish, "-l"], base_env(home, extra))
        expect(env["XDG_DATA_DIRS"].endswith(":/original/share"), f"XDG_DATA_DIRS {env['XDG_DATA_DIRS']}")
        shell = Shell(argv, env, home)
        try:
            shell.pump(lambda out: osc133(b"A") in out)
            expect("LOAD:config.fish" in text(shell.out), "config.fish not loaded")
            mark = len(shell.out)
            shell.run("false")
            events = lifecycle(shell.out[mark:])
            ours = force or major < 4
            native = major >= 4
            per_marker = int(ours) + int(native)
            expect(events.count("D;1") == per_marker and events.count("C") == per_marker,
                   f"events {events}, expected each marker {per_marker}x")
            out = text(shell.run("echo S=$status XDG=[$XDG_DATA_DIRS] LEAK=[\"$DAMSON_FISH_XDG_DATA_DIRS\"]"))
            expect("S=1" in out, f"$status not preserved: {out[-300:]!r}")
            expect("XDG=[/original/share]" in out, f"XDG_DATA_DIRS not restored: {out[-300:]!r}")
            expect("LEAK=[]" in out, f"injection variable leaked: {out[-300:]!r}")
        finally:
            shell.close()

    if major < 4:
        h.check(f"fish {version} hooks", lambda: case(False))
    else:
        h.check(f"fish {version}: native markers only, no duplicates", lambda: case(False))
        h.check(f"fish {version}: fish 3 hooks (forced) alongside native", lambda: case(True))


def main():
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="damson-shell-hooks-") as directory:
        h = Harness(repo, Path(directory).resolve())
        zsh_tests(h)
        bash_tests(h)
        fish_tests(h)
        print(f"{h.count - len(h.failures)}/{h.count} passed")
        if h.failures:
            sys.exit(1)


if __name__ == "__main__":
    main()

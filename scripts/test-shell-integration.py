#!/usr/bin/env python3
"""Exercise the generated OSC 133 hooks in a real interactive zsh on a PTY."""
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import time


def main():
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="damson-shell-hooks-") as directory:
        root = Path(directory)
        source = root / "audit.swift"
        source.write_text('''import Foundation
@main enum Audit {
    static func main() {
        print(ShellIntegration.envOverrides(forShellPath: "/bin/zsh")["ZDOTDIR"] ?? "")
    }
}
''')
        binary = root / "audit"
        subprocess.run(["swiftc", str(repo / "Sources/damson/ShellIntegration.swift"),
                        str(source), "-o", str(binary)], check=True)
        env = dict(os.environ, CFFIXED_USER_HOME=str(root))
        wrapper = Path(subprocess.check_output([str(binary)], env=env, text=True).strip()) / ".zshrc"
        body = wrapper.read_text()
        hook = root / "hooks.zsh"
        hook.write_text(body[body.index("# --- damson shell integration ---"):])
        master, slave = pty.openpty()
        process = subprocess.Popen(["/bin/zsh", "-dfi"], stdin=slave, stdout=slave,
                                   stderr=slave, start_new_session=True)
        os.close(slave)

        def read_until(marker):
            output = b""
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if select.select([master], [], [], .05)[0]:
                    output += os.read(master, 65536)
                    if marker in output:
                        return output
            raise AssertionError(f"Missing {marker!r}: {output!r}")

        try:
            # -f avoids sourcing any of the user's shell configuration.
            os.write(master, f"source {hook}\n".encode())
            read_until(b"\x1b]133;A\x1b\\")
            os.write(master, b"false\n")
            failed = read_until(b"\x1b]133;D;1\x1b\\")
            assert b"\x1b]133;C\x1b\\" in failed
            os.write(master, b"true\n")
            read_until(b"\x1b]133;D;0\x1b\\")
            print("PASS: real zsh emits command start and exit codes 1/0")
        finally:
            os.killpg(process.pid, signal.SIGTERM)
            os.close(master)
            process.wait(timeout=5)


if __name__ == "__main__":
    main()

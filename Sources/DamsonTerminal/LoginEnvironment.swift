import Foundation

/// The PATH the user's login shell would have, for programs damson execs directly.
///
/// A damson launched from the Dock inherits LaunchServices' PATH — `/usr/bin:/bin:/usr/sbin:
/// /sbin` — and nothing the user installed. An interactive pane never notices: it runs the
/// login shell, which rebuilds PATH from `/etc/zprofile` and the user's own rc files. A
/// program exec'd straight into a pane gets the minimal PATH as-is, so `spawn -- claude`
/// failed on every task with "no executable named 'claude'", on a normally launched app with
/// default settings.
///
/// The fix is what Terminal.app does for every tab: ask the login shell. Once, cached, with
/// a timeout so a slow or broken rc file cannot hang the app.
public enum LoginEnvironment {
    /// PATH according to the user's login shell, probed once per process. nil when the shell
    /// did not answer in time; callers fall back to what they inherited.
    public static let loginPATH: String? = probeLoginPATH()

    /// `login` first, in order; then anything in `inherited` it did not mention, so nothing the
    /// process already had is lost. Empty segments are dropped — `a::b` is the classic way to
    /// put the current directory on PATH by accident.
    public static func mergedPATH(login: String?, inherited: String?) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for source in [login, inherited] {
            for raw in (source ?? "").split(separator: ":", omittingEmptySubsequences: true) {
                let dir = String(raw)
                if seen.insert(dir).inserted { out.append(dir) }
            }
        }
        return out.isEmpty ? "/usr/bin:/bin:/usr/sbin:/sbin" : out.joined(separator: ":")
    }

    /// Run the login shell and read PATH from it. Interactive (`-i`) as well as login (`-l`),
    /// because Homebrew and most tool installers write to `.zshrc`, which a non-interactive
    /// shell never reads — a `-lc` probe on this machine missed every agent CLI. Only the
    /// LAST line of output is taken: interactive rc files print things.
    public static func probeLoginPATH(shell: String = DamsonConfig.loginShellPath(),
                                      arguments: [String]? = nil,
                                      timeout: TimeInterval = 5) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = arguments ?? ["-lic", "printf '%s\\n' \"$PATH\""]
        // A minimal environment: the point is to see what the shell BUILDS, not what it was
        // handed, and an inherited PATH would pollute exactly the thing being measured.
        proc.environment = ["HOME": NSHomeDirectory(), "USER": NSUserName(),
                            "SHELL": shell, "TERM": "dumb", "LANG": "en_US.UTF-8"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        // Read on a background thread so a shell that prints forever cannot fill the pipe
        // and deadlock the timeout wait.
        var data = Data()
        let reader = Thread { data = out.fileHandleForReading.readDataToEndOfFile() }
        reader.start()
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if proc.isRunning {
            proc.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            return nil
        }
        // Let the reader drain what the (now exited) shell wrote.
        let readDeadline = Date().addingTimeInterval(1)
        while reader.isExecuting && Date() < readDeadline { Thread.sleep(forTimeInterval: 0.02) }

        let text = String(decoding: data, as: UTF8.self)
        guard let last = text.split(separator: "\n").last(where: { $0.contains("/") }) else { return nil }
        let path = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

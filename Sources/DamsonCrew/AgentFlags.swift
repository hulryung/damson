import Foundation

/// Arguments damson-crew adds on the caller's behalf.
public enum AgentFlags {
    /// Claude Code's bypass. Spelled out here once so the rest of the code never types it.
    static let skipPermissionsFlag = "--dangerously-skip-permissions"

    /// Arguments that mean the caller has already decided how permissions should work.
    /// If any is present, nothing is added — an explicit choice is never overridden.
    private static let permissionArguments = [
        "--permission-mode", "--dangerously-skip-permissions",
        "--allow-dangerously-skip-permissions", "--allowedTools", "--allowed-tools",
    ]

    /// Add the bypass to a `claude` command line, if it is wanted and not already decided.
    ///
    /// **Only `claude`.** `codex`, `grok` and `cursor-agent` each spell this differently or
    /// not at all, and passing a flag a CLI does not know turns a working spawn into a pane
    /// that exits instantly on an unknown argument.
    ///
    /// Insert directly after the executable so option/value pairs and `--` stay intact.
    public static func apply(skipPermissions: Bool, to argv: [String]) -> [String] {
        guard skipPermissions, let program = argv.first, !program.isEmpty,
              (program as NSString).lastPathComponent == "claude" else { return argv }
        let alreadyDecided = argv.dropFirst().contains { arg in
            permissionArguments.contains { arg == $0 || arg.hasPrefix($0 + "=") }
        }
        guard !alreadyDecided else { return argv }
        var out = argv
        out.insert(skipPermissionsFlag, at: 1)
        return out
    }
}

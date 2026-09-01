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
    /// The flag goes in **before the last argument**, because the prompt is a positional and
    /// has to stay last — that is the one shape every agent CLI accepts.
    public static func apply(skipPermissions: Bool, to argv: [String]) -> [String] {
        guard skipPermissions, let program = argv.first, !program.isEmpty,
              (program as NSString).lastPathComponent == "claude" else { return argv }
        let alreadyDecided = argv.dropFirst().contains { arg in
            permissionArguments.contains { arg == $0 || arg.hasPrefix($0 + "=") }
        }
        guard !alreadyDecided else { return argv }
        // With a prompt, insert before it; without one, append.
        var out = argv
        if out.count > 1 {
            out.insert(skipPermissionsFlag, at: out.count - 1)
        } else {
            out.append(skipPermissionsFlag)
        }
        return out
    }
}

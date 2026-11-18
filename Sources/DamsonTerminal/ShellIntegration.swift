import Foundation

/// Injects shell integration so the shell reports its working directory (OSC 7), marks its
/// prompts (OSC 133;A) and brackets each command with its exit status (OSC 133;C / D;n).
///
/// The user's dotfiles are never modified. Each shell is pointed at a generated file that
/// runs the user's own startup files in the shell's normal order and then installs hooks:
///
/// - **zsh**: `ZDOTDIR` points at wrapper files that forward to `$HOME/.zshenv` etc.
/// - **bash 4+**: started with `--posix`, which makes an interactive shell read `$ENV` and
///   no other startup file — including a login shell, so `-l` keeps its meaning. The script
///   leaves POSIX mode and runs the login or interactive files itself.
/// - **bash 3.2** (macOS's `/bin/bash`): ignores `$ENV` in POSIX mode, so it is started with
///   `--rcfile <script> -i` instead. That shell is never a login shell, so the script runs
///   the login files when `-l` was asked for; `shopt login_shell` reads off and
///   `~/.bash_logout` does not run.
/// - **fish**: our directory is prepended to `XDG_DATA_DIRS`, whose `vendor_conf.d` fish
///   loads before `config.fish`. fish 4 emits these sequences itself, so the hooks only
///   install on fish 3.
///
/// Every variable we set for this is put back by the script, so a shell or program started
/// from the pane sees the environment it would have had without damson.
public enum ShellIntegration {
    /// What to spawn instead of `argv`/`env`. Unchanged for programs that aren't a supported
    /// shell, for a bash given arguments other than `-l`/`--login`/`-i` (`bash -c …`), and
    /// when the integration files can't be written.
    public static func prepare(argv: [String], env: [String: String],
                               root: URL? = defaultRoot,
                               bashMajorVersion: (String) -> Int? = probedBashMajorVersion)
        -> (argv: [String], env: [String: String]) {
        guard let shell = argv.first, let root, let dir = installed(at: root) else {
            return (argv, env)
        }
        var env = env
        switch (shell as NSString).lastPathComponent {
        case "zsh":
            env["ZDOTDIR"] = dir.appendingPathComponent("zsh").path
            env["DAMSON_SHELL_INTEGRATION"] = "1"
            return (argv, env)

        case "bash":
            let flags = Array(argv.dropFirst())
            guard flags.allSatisfy(bashPassThroughFlags.contains),
                  let path = PTYHost.resolveProgram(shell, env: env),
                  let major = bashMajorVersion(path) else { return (argv, env) }
            let script = dir.appendingPathComponent("bash/damson.bash").path
            env["DAMSON_SHELL_INTEGRATION"] = "1"
            if major >= 4 {
                if let original = env["ENV"] { env["DAMSON_BASH_ENV"] = original }
                env["ENV"] = script
                env["DAMSON_BASH_INTEGRATION"] = "posix"
                return ([shell, "--posix"] + flags, env)
            }
            env["DAMSON_BASH_INTEGRATION"] = "rcfile"
            if flags.contains("-l") || flags.contains("--login") { env["DAMSON_BASH_LOGIN"] = "1" }
            return ([shell, "--rcfile", script, "-i"], env)

        case "fish":
            if let original = env["XDG_DATA_DIRS"] { env["DAMSON_FISH_XDG_DATA_DIRS"] = original }
            // Unset means fish's defaults; keep them reachable once ours is in front.
            let rest = env["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share"
            env["XDG_DATA_DIRS"] = dir.appendingPathComponent("fish").path + ":" + rest
            env["DAMSON_SHELL_INTEGRATION"] = "1"
            return (argv, env)

        default:
            return (argv, env)
        }
    }

    /// Flags a bash may carry and still be rewritten. Anything else (`-c`, a script path,
    /// `--norc`) is a request the rewrite would change the meaning of.
    static let bashPassThroughFlags: Set<String> = ["-l", "--login", "-i"]

    public static let defaultRoot: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Damson", isDirectory: true)
        .appendingPathComponent("shell-integration", isDirectory: true)

    // MARK: - Files

    private static let lock = NSLock()
    private static var written: [String: Bool] = [:]

    /// Writes the integration files under `root` once per process (only where the content
    /// changed), returning `root`, or nil when they can't be written.
    static func installed(at root: URL) -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let ok = written[root.path] { return ok ? root : nil }
        let fm = FileManager.default
        var ok = true
        for (path, body) in files {
            let url = root.appendingPathComponent(path)
            if (try? String(contentsOf: url, encoding: .utf8)) == body { continue }
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try body.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                ok = false
            }
        }
        written[root.path] = ok
        return ok ? root : nil
    }

    static var files: [(String, String)] {
        func forward(_ name: String) -> String {
            // Since ZDOTDIR is our directory, the user's original is always $HOME/<name>.
            "[ -r \"$HOME/\(name)\" ] && source \"$HOME/\(name)\"\n"
        }
        return [
            ("zsh/.zshenv", forward(".zshenv")),
            ("zsh/.zprofile", forward(".zprofile")),
            ("zsh/.zshrc", forward(".zshrc") + zshHook),
            ("zsh/.zlogin", forward(".zlogin")),
            ("bash/damson.bash", bashScript),
            ("fish/fish/vendor_conf.d/damson-shell-integration.fish", fishScript),
        ]
    }

    static let zshHook = """

    # --- damson shell integration ---
    # On every prompt: report cwd via OSC 7 (new splits/tabs inherit cwd) + mark the
    # prompt line via OSC 133;A (⌘↑/⌘↓ prompt jump).
    _damson_preexec() {
      _damson_command_running=1
      printf '\\033]133;C\\033\\\\'
    }
    _damson_precmd() {
      local _damson_status=$?
      if [[ "${_damson_command_running:-0}" == 1 ]]; then
        printf '\\033]133;D;%s\\033\\\\' "$_damson_status"
        _damson_command_running=0
      fi
      printf '\\033]7;file://%s%s\\033\\\\' "${HOST}" "${PWD}"
      printf '\\033]133;A\\033\\\\'
    }
    autoload -Uz add-zsh-hook 2>/dev/null
    if (( $+functions[add-zsh-hook] )); then
      add-zsh-hook -d preexec _damson_preexec 2>/dev/null
      add-zsh-hook preexec _damson_preexec
      add-zsh-hook -d precmd _damson_precmd 2>/dev/null
      add-zsh-hook precmd _damson_precmd
    else
      preexec_functions+=(_damson_preexec)
      precmd_functions+=(_damson_precmd)
    fi
    _damson_precmd
    # --- end damson shell integration ---

    """

    /// Runs in place of bash's startup files (see the type comment for how it is loaded).
    static let bashScript = #"""
    # damson shell integration for bash. Generated; edits are overwritten.
    if [ -n "${DAMSON_BASH_INTEGRATION-}" ]; then
      _damson_mode=$DAMSON_BASH_INTEGRATION
      _damson_login=${DAMSON_BASH_LOGIN-}
      unset DAMSON_BASH_INTEGRATION DAMSON_BASH_LOGIN
      if [ "$_damson_mode" = posix ]; then
        if [ -n "${DAMSON_BASH_ENV+x}" ]; then
          export ENV="$DAMSON_BASH_ENV"
          unset DAMSON_BASH_ENV
        else
          unset ENV
        fi
        builtin set +o posix
        builtin shopt -q login_shell && _damson_login=1
      fi
      # bash's own order: a login shell reads /etc/profile, then the first readable of
      # ~/.bash_profile, ~/.bash_login, ~/.profile; any other interactive shell ~/.bashrc.
      if [ -n "$_damson_login" ]; then
        [ -r /etc/profile ] && builtin source /etc/profile
        for _damson_f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
          if [ -r "$_damson_f" ]; then builtin source "$_damson_f"; break; fi
        done
      else
        [ -r "$HOME/.bashrc" ] && builtin source "$HOME/.bashrc"
      fi
      unset _damson_mode _damson_login _damson_f

      if [ -z "${_damson_hooks-}" ]; then
        _damson_hooks=1
        _damson_at_prompt=0
        _damson_running=0
        _damson_status=0

        # First in PROMPT_COMMAND: capture the command's status before anything else runs,
        # and hand it back so the user's prompt commands still see it.
        _damson_prompt_start() {
          _damson_status=$?
          _damson_at_prompt=0
          return $_damson_status
        }
        # Last: from here until the next command line, the DEBUG trap means "a command is
        # starting". PS1 sees $? from here, so return the command's status again.
        _damson_prompt_end() {
          if [ "$_damson_running" = 1 ]; then
            builtin printf '\033]133;D;%s\033\\' "$_damson_status"
            _damson_running=0
          fi
          builtin printf '\033]7;file://%s%s\033\\' "$HOSTNAME" "$PWD"
          builtin printf '\033]133;A\033\\'
          _damson_at_prompt=1
          return $_damson_status
        }
        _damson_return() { return "$1"; }

        # bash 3.2 has no PS0, so command start comes from the DEBUG trap, which fires for
        # every simple command; only the first one after a prompt counts.
        _damson_prev_debug=$(builtin trap -p DEBUG)
        _damson_prev_debug=${_damson_prev_debug#"trap -- '"}
        _damson_prev_debug=${_damson_prev_debug%"' DEBUG"}
        _damson_quote="'\\''"
        _damson_prev_debug=${_damson_prev_debug//$_damson_quote/\'}
        unset _damson_quote
        _damson_debug() {
          local s=$?
          if [ "$_damson_at_prompt" = 1 ] && [ -z "${COMP_LINE-}" ]; then
            case "$BASH_COMMAND" in
              _damson_prompt_start*) ;;
              *)
                _damson_at_prompt=0
                _damson_running=1
                builtin printf '\033]133;C\033\\'
                ;;
            esac
          fi
          if [ -n "$_damson_prev_debug" ]; then
            _damson_return "$s"
            builtin eval "$_damson_prev_debug"
          fi
        }
        builtin trap '_damson_debug' DEBUG

        if [[ "$(builtin declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
          PROMPT_COMMAND=(_damson_prompt_start "${PROMPT_COMMAND[@]}" _damson_prompt_end)
        else
          PROMPT_COMMAND=$'_damson_prompt_start\n'"${PROMPT_COMMAND-}"$'\n_damson_prompt_end'
        fi
      fi
    fi

    """#

    /// Loaded by fish from `vendor_conf.d`, before the user's `config.fish`.
    static let fishScript = #"""
    # damson shell integration for fish. Generated; edits are overwritten.
    if set -q DAMSON_FISH_XDG_DATA_DIRS
        set -gx XDG_DATA_DIRS $DAMSON_FISH_XDG_DATA_DIRS
        set -e DAMSON_FISH_XDG_DATA_DIRS
    else
        set -e XDG_DATA_DIRS
    end

    # fish 4 reports the working directory and command lifecycle itself.
    set -l __damson_major (string match -r '^[0-9]+' -- $version)
    if status is-interactive; and begin; test "$__damson_major" -lt 4; or set -q DAMSON_FISH_FORCE_HOOKS; end
        function __damson_preexec --on-event fish_preexec
            set -g __damson_running 1
            printf '\e]133;C\e\\'
        end
        function __damson_postexec --on-event fish_postexec
            set -l s $status
            if test "$__damson_running" = 1
                printf '\e]133;D;%s\e\\' $s
                set -g __damson_running 0
            end
        end
        function __damson_prompt --on-event fish_prompt
            printf '\e]7;file://%s%s\e\\' $hostname $PWD
            printf '\e]133;A\e\\'
        end
    end

    """#

    // MARK: - bash version

    private static var bashVersions: [String: Int?] = [:]

    /// The major version of the bash at `path`, asked once per path. nil when it can't be
    /// run or answers nonsense, which leaves that bash without integration.
    public static func probedBashMajorVersion(_ path: String) -> Int? {
        lock.lock()
        if let cached = bashVersions[path] { lock.unlock(); return cached }
        lock.unlock()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--norc", "--noprofile", "-c", "echo ${BASH_VERSINFO[0]}"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var major: Int?
        if (try? process.run()) != nil {
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { usleep(5_000) }
            if process.isRunning { process.terminate() } else {
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                major = Int(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        lock.lock(); bashVersions[path] = major; lock.unlock()
        return major
    }
}

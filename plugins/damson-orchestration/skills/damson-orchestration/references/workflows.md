# Managed workflow plans

```sh
damson-crew workflow run --plan workflow.json --state .crew/run-1
damson-crew workflow status --state .crew/run-1
```

`run` waits and exits 0 only if every task succeeds; 1 means tasks failed/blocked, 2 means
invalid input or an operational error. Ctrl-C stops the coordinator, leaving workers alive.
Repeat the exact plan/state to resume; completed attempts are not replayed. A changed plan
is rejected for an existing state directory. `status` reads the journal without a live app.
State directories contain the resolved plan (including prompts), task status, and per-attempt
logs/results. Keep them out of version control when they contain private project context.

```json
{
  "version": 1,
  "name": "game",
  "maxParallel": 2,
  "tasks": [
    {
      "id": "engine",
      "cwd": "./game",
      "prompt": "Implement engine.mjs following CONTRACT.md. Own only engine.mjs.",
      "verify": [["node", "--check", "engine.mjs"]],
      "outputs": ["engine.mjs"],
      "timeoutSeconds": 600,
      "maxAttempts": 2
    },
    {
      "id": "interface",
      "cwd": "./game",
      "prompt": "Implement index.html, style.css, app.mjs following CONTRACT.md. Own only those files.",
      "verify": [["node", "--check", "app.mjs"]],
      "outputs": ["index.html", "style.css", "app.mjs"],
      "timeoutSeconds": 600,
      "maxAttempts": 2
    },
    {
      "id": "integrate",
      "cwd": "./game",
      "dependsOn": ["engine", "interface"],
      "prompt": "Integrate the game, add substantive engine.test.mjs tests, run them and fix failures.",
      "verify": [["node", "--test", "engine.test.mjs"]],
      "outputs": ["engine.test.mjs"],
      "timeoutSeconds": 600,
      "maxAttempts": 2
    }
  ]
}
```

Create working directories and the interface contract before running this example. Relative
`cwd` paths resolve against the plan file's directory, not the invoking shell. IDs contain
letters, digits, `_`, or `-`; unknown JSON fields are rejected so misspelled dependencies
cannot silently run out of order. Dependencies must refer to unique existing IDs and form
an acyclic graph. `maxParallel` is 1–32.

Each task accepts:

- `command`: argv array for a finite command; never shell-parsed. Explicit shell scripts use
  `["/bin/sh", "-c", "..."]`. Omit it for a `prompt` task to use Claude's print mode.
- `prompt`: appended as a single argument, or substituted at `{prompt}` in `command`.
  Claude commands must include `--print`/`-p`. Claude permission bypass follows Damson's
  Agents setting; an explicit permission mode remains authoritative.
- `dependsOn`: IDs that must succeed first; default `[]`. An exhausted failed dependency
  blocks its descendants while independent work continues.
- `verify`: argv arrays run sequentially after command exit 0. Required for prompt tasks.
- `outputs`: relative paths that must exist after validation. Use validation commands to
  check content; existence alone does not establish correctness.
- `resources`: names of shared mutable resources; tasks sharing one do not run concurrently.
- `maxAttempts`: 1–10, default 1. A retry keeps files and uses a new attempt; commands should
  be repeatable. Do not automatically retry irreversible external mutations.
- `timeoutSeconds`: positive, at most 86400, default 900. Covers the command and validations
  together. Timeout terminates the command's process group.

Attempt logs persist after panes finish. Interactive `watch` badges do not drive this mode.
A CLI command must finish; do not start a permanent development server as a dependency.
Run browser verification against a separately managed server, then stop that server when
finished. The example's syntax and unit checks still need a real browser play check.

#!/usr/bin/env bash
# lint.sh — run SwiftLint with the repo config.
#
# On a machine with only the Command Line Tools (no Xcode.app), SwiftLint's
# SourceKit framework isn't on its default search path, so point it at the CLT
# copy. Harmless when a full Xcode is selected.
#
# Usage:
#   ./scripts/lint.sh           # report violations
#   ./scripts/lint.sh --fix     # autocorrect the safe (cosmetic) rules
#   ./scripts/lint.sh --strict  # treat warnings as errors (CI parity)

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "error: swiftlint not installed — 'brew install swiftlint'" >&2
    exit 1
fi

# Make SourceKit loadable under Command Line Tools (no-op under full Xcode).
CLT_LIB="/Library/Developer/CommandLineTools/usr/lib"
if [[ -d "$CLT_LIB/sourcekitdInProc.framework" ]]; then
    export DYLD_FRAMEWORK_PATH="${DYLD_FRAMEWORK_PATH:+$DYLD_FRAMEWORK_PATH:}$CLT_LIB"
fi

case "${1:-}" in
    --fix)    exec swiftlint --fix ;;
    --strict) exec swiftlint lint --strict ;;
    *)        exec swiftlint lint "$@" ;;
esac

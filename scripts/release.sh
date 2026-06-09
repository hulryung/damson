#!/usr/bin/env bash
# release.sh — build → sign+notarize → dmg, all in one.
#
# Environment variables are the same as in each sub-script.
#   Required: MARKETING_VERSION, APPLE_SIGNING_IDENTITY
#   Required (notarization): APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID
#                  (or NOTARY_KEYCHAIN_PROFILE)
#
# Usage:
#   MARKETING_VERSION=0.1.0 ./scripts/release.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "############ build ############"
CLEAN=1 ./scripts/build-app.sh

echo "############ sign + notarize ############"
./scripts/sign-and-notarize.sh

echo "############ dmg ############"
./scripts/build-dmg.sh

echo ""
echo "############ done ############"
ls -lh dist/

#!/usr/bin/env bash
set -euo pipefail

# Runs the caddie test suites via xcodebuild. Local signing is disabled so the
# tests build without a "Mac Development" certificate (the test targets default
# to that identity, which isn't present on this machine).
#
#   ./test.sh          # unit tests only (fast, no UI automation)
#   ./test.sh ui       # UI tests only (launches the app)
#   ./test.sh all      # everything

PROJECT="caddie.xcodeproj"
SCHEME="caddie"
DEST="platform=macOS"
# Ad-hoc sign locally: no "Mac Development" cert is installed, but the XCUITest
# runner (caddieUITests-Runner.app) MUST be signed or macOS refuses to launch it
# ("… is damaged and can't be opened"). CODE_SIGN_IDENTITY="-" applies an ad-hoc
# signature; CODE_SIGNING_ALLOWED must stay YES (the default) so signing actually
# runs — passing CODE_SIGNING_ALLOWED=NO leaves the runner unsigned → "damaged".
SIGN=(CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=YES)

case "${1:-unit}" in
  unit) ONLY=(-only-testing:caddieTests) ;;
  ui)   ONLY=(-only-testing:caddieUITests) ;;
  all)  ONLY=() ;;
  *) echo "usage: ./test.sh [unit|ui|all]" >&2; exit 2 ;;
esac

xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DEST" \
  ${ONLY[@]+"${ONLY[@]}"} \
  "${SIGN[@]}"

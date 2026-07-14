#!/usr/bin/env bash
set -euo pipefail

SCHEME="caddie"
PROJECT="caddie.xcodeproj"
TEMPLATE="Time Profiler"

quit_app() {
  if pgrep -xq "$SCHEME"; then
    echo "Quitting running ${SCHEME}…"
    osascript -e "tell application \"$SCHEME\" to quit" 2>/dev/null || pkill -x "$SCHEME" || true
    sleep 0.5
  fi
}

# Builds $SCHEME for the given configuration into build/<config>/, falling back to
# a plain xcodebuild when xcpretty isn't installed. Echoes nothing; callers derive
# the .app path from BUILD_DIR.
build_app() {
  local config="$1"
  local build_dir="$2"
  echo "Building $SCHEME ($config)…"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$config" \
    -derivedDataPath ".derived" \
    SYMROOT="$(pwd)/$build_dir" \
    build 2>&1 | xcpretty || xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$config" \
    -derivedDataPath ".derived" \
    SYMROOT="$(pwd)/$build_dir" \
    build
}

# run: build a Debug binary (with OSM_DEBUG logging compiled in) and launch it in
# the foreground so the [OSM] diagnostics stream to this terminal. Skips the clean
# so the troubleshooting loop stays fast; use `./build.sh clean` to force a rebuild.
if [[ "${1:-}" == "run" ]]; then
  CONFIG="Debug"
  BUILD_DIR="build/$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')"
  APP="$BUILD_DIR/$CONFIG/$SCHEME.app"
  BINARY="$APP/Contents/MacOS/$SCHEME"

  quit_app

  build_app "$CONFIG" "$BUILD_DIR"

  if [[ ! -x "$BINARY" ]]; then
    echo "Build succeeded but executable not found at: $BINARY" >&2
    exit 1
  fi

  echo
  echo "Launching ${SCHEME} in the foreground. [OSM] logs stream below; Ctrl-C to stop."
  echo "Tip: pipe through 'grep \"\\[OSM\\]\"' to filter."
  echo
  exec "$BINARY"
fi

if [[ "${1:-}" == "clean" ]]; then
  quit_app
  echo "Cleaning build/ and .derived/…"
  rm -rf build .derived
  echo "Done."
  exit 0
fi

# profile: build an optimized-but-symbolicated Release binary and record a
# Time Profiler trace with xctrace. Reproduce the slow path (e.g. select a course
# to draw its overlays), then press Ctrl-C to stop recording and open the trace.
if [[ "${1:-}" == "profile" ]]; then
  CONFIG="Release"
  BUILD_DIR="build/$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')"
  APP="$BUILD_DIR/$CONFIG/$SCHEME.app"
  BINARY="$APP/Contents/MacOS/$SCHEME"
  TRACE="profiles/${SCHEME}-$(date +%Y%m%d-%H%M%S).trace"

  quit_app

  echo "Cleaning build/ and .derived/…"
  rm -rf build .derived

  build_app "$CONFIG" "$BUILD_DIR"

  if [[ ! -x "$BINARY" ]]; then
    echo "Build succeeded but executable not found at: $BINARY" >&2
    exit 1
  fi

  mkdir -p profiles
  echo
  echo "Recording '${TEMPLATE}' → ${TRACE}"
  echo "▶︎ Reproduce the hang (select a course to draw overlays), then press Ctrl-C to stop."
  echo

  # xctrace finalizes the trace on SIGINT, so don't let set -e abort before we open it.
  set +e
  xcrun xctrace record \
    --template "$TEMPLATE" \
    --output "$TRACE" \
    --launch -- "$BINARY"
  set -e

  if [[ -d "$TRACE" ]]; then
    echo "Saved: $TRACE"
    echo "Opening in Instruments…"
    open "$TRACE"
  else
    echo "No trace was written (recording may have failed)." >&2
    exit 1
  fi
  exit 0
fi

# profile-ui: drive the app with a UI test (default testCompleteHoleAtPar) while a
# Time Profiler attaches to it, then export the trace and print a per-symbol
# heatmap via profiles/analyze.py. Fully automated — a repeatable "why is the
# framerate slow" breakdown of the whole play-through path (course select → mode
# switch → hole flyovers → shots → finish). Optional 2nd arg overrides the test.
#
#   ./build.sh profile-ui
#   ./build.sh profile-ui caddieUITests/caddieUITests/testCompleteHoleAtPar
if [[ "${1:-}" == "profile-ui" ]]; then
  TEST="${2:-caddieUITests/caddieUITests/testCompleteHoleAtPar}"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  TRACE="profiles/${SCHEME}-ui-${STAMP}.trace"
  XML="profiles/${SCHEME}-ui-${STAMP}.xml"
  TESTLOG="profiles/${SCHEME}-ui-${STAMP}.testlog"
  # Ad-hoc sign so the XCUITest runner launches; CODE_SIGNING_ALLOWED stays YES.
  SIGN=(CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=YES)

  quit_app
  # Clear the persisted (possibly fullscreen) window state so the sidebar search
  # field is in the a11y tree — otherwise the course-select step can't find it.
  defaults delete com.okjeffrey.caddie 2>/dev/null || true

  mkdir -p profiles
  echo "Running UI test ($TEST) in Release; Time Profiler will attach…"

  # -configuration Release gives realistic, optimized frame timings (Debug is far
  # too slow to trust for framerate work). Accessibility identifiers are compiled
  # in regardless of configuration. ENABLE_TESTABILITY=YES keeps -O optimizations
  # while re-enabling `@testable import caddie` (the unit-test target is built even
  # when only the UI test runs, and its testable import fails in a plain Release
  # build). Run in the background so we can attach xctrace to the app it launches.
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=macOS" \
    -configuration Release \
    -only-testing:"$TEST" \
    ENABLE_TESTABILITY=YES \
    "${SIGN[@]}" \
    > "$TESTLOG" 2>&1 &
  TEST_PID=$!

  echo "Waiting for ${SCHEME} to launch (building Release first)…"
  APP_PID=""
  for _ in $(seq 1 900); do
    if ! kill -0 "$TEST_PID" 2>/dev/null; then
      echo "xcodebuild exited before the app launched; see $TESTLOG" >&2
      exit 1
    fi
    APP_PID="$(pgrep -x "$SCHEME" | head -1 || true)"
    [[ -n "$APP_PID" ]] && break
    sleep 0.2
  done
  if [[ -z "$APP_PID" ]]; then
    echo "Timed out waiting for ${SCHEME} to launch; see $TESTLOG" >&2
    kill "$TEST_PID" 2>/dev/null || true
    exit 1
  fi

  echo "Attaching '${TEMPLATE}' to PID $APP_PID → $TRACE"
  # xctrace finalizes on target-exit or the time limit; don't let set -e abort.
  set +e
  xcrun xctrace record \
    --template "$TEMPLATE" \
    --attach "$APP_PID" \
    --time-limit 120s \
    --output "$TRACE"
  set -e

  wait "$TEST_PID" 2>/dev/null || true

  if [[ ! -d "$TRACE" ]]; then
    echo "No trace was written; see $TESTLOG" >&2
    exit 1
  fi
  echo "Saved: $TRACE"

  echo "Exporting time-profile table → $XML"
  xcrun xctrace export \
    --input "$TRACE" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
    > "$XML"

  echo
  echo "================ HEATMAP (profiles/analyze.py) ================"
  python3 profiles/analyze.py "$XML"
  echo
  echo "Trace: $TRACE"
  echo "XML:   $XML"
  echo "Open the full timeline in Instruments with: open \"$TRACE\""
  exit 0
fi

# dist: build a Release binary, sign with Developer ID, notarize with Apple, and
# staple the ticket — producing a Gatekeeper-approved .app ready to share.
#
# Required env vars (set in your shell or a local .env file you source first):
#   APPLE_ID          your Apple ID email
#   APPLE_APP_PASSWORD  an app-specific password from appleid.apple.com
#
# The Developer ID certificate and team ID are derived automatically from
# the keychain / project settings (team WK2V2PZM2Y).
if [[ "${1:-}" == "dist" ]]; then
  CONFIG="Release"
  BUILD_DIR="build/$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')"
  APP="$BUILD_DIR/$CONFIG/$SCHEME.app"
  TEAM_ID="WK2V2PZM2Y"
  ZIP="build/release/${SCHEME}-dist.zip"

  : "${APPLE_ID:?APPLE_ID env var is required for notarization}"
  : "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD env var is required for notarization}"

  quit_app

  echo "Cleaning build/ and .derived/…"
  rm -rf build .derived

  build_app "$CONFIG" "$BUILD_DIR"

  if [[ ! -d "$APP" ]]; then
    echo "Build succeeded but app not found at expected path: $APP" >&2
    exit 1
  fi

  # Resolve the Developer ID certificate from the keychain automatically.
  SIGN_ID=$(security find-identity -v -p codesigning | \
    grep "Developer ID Application" | grep "$TEAM_ID" | \
    head -1 | awk -F'"' '{print $2}')

  if [[ -z "$SIGN_ID" ]]; then
    echo "No 'Developer ID Application' certificate found for team $TEAM_ID." >&2
    echo "Install it from developer.apple.com/account → Certificates." >&2
    exit 1
  fi

  echo "Signing with: $SIGN_ID"
  codesign \
    --force \
    --deep \
    --options runtime \
    --sign "$SIGN_ID" \
    "$APP"

  echo "Verifying signature…"
  codesign --verify --deep --strict --verbose=2 "$APP"
  spctl --assess --type exec --verbose "$APP" || true   # passes once notarized

  echo "Zipping for notarization…"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"

  echo "Submitting to Apple Notary Service (this may take a few minutes)…"
  xcrun notarytool submit "$ZIP" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

  echo "Stapling notarization ticket…"
  xcrun stapler staple "$APP"

  echo
  echo "Done. Distributable app: $APP"
  echo "Verify with: spctl --assess --type exec --verbose \"$APP\""
  exit 0
fi

CONFIG="${1:-Debug}"
BUILD_DIR="build/$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')"

# Always: quit the running app, clean, build, then launch.
quit_app

echo "Cleaning build/ and .derived/…"
rm -rf build .derived

build_app "$CONFIG" "$BUILD_DIR"

APP="$BUILD_DIR/$CONFIG/$SCHEME.app"

if [[ -d "$APP" ]]; then
  echo "Built: $APP"
  echo "Launching ${SCHEME}…"
  open "$APP"
else
  echo "Build succeeded but app not found at expected path: $APP" >&2
  exit 1
fi

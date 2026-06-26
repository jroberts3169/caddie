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

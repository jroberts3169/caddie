#!/usr/bin/env bash
set -euo pipefail

SCHEME="caddie"
PROJECT="caddie.xcodeproj"

quit_app() {
  if pgrep -xq "$SCHEME"; then
    echo "Quitting running ${SCHEME}…"
    osascript -e "tell application \"$SCHEME\" to quit" 2>/dev/null || pkill -x "$SCHEME" || true
    sleep 0.5
  fi
}

if [[ "${1:-}" == "clean" ]]; then
  quit_app
  echo "Cleaning build/ and .derived/…"
  rm -rf build .derived
  echo "Done."
  exit 0
fi

CONFIG="${1:-Release}"
BUILD_DIR="build/$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')"

quit_app

echo "Building $SCHEME ($CONFIG)…"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath ".derived" \
  SYMROOT="$(pwd)/$BUILD_DIR" \
  build 2>&1 | xcpretty || xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath ".derived" \
  SYMROOT="$(pwd)/$BUILD_DIR" \
  build

APP="$BUILD_DIR/$CONFIG/$SCHEME.app"

if [[ -d "$APP" ]]; then
  echo "Built: $APP"
  if [[ "${2:-}" == "--run" ]]; then
    echo "Launching ${SCHEME}…"
    open "$APP"
  fi
else
  echo "Build succeeded but app not found at expected path: $APP" >&2
  exit 1
fi

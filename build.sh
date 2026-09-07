#!/bin/bash
# Build Clipspan.app on a Mac and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Clipspan.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/Clipspan" Sources/main.swift \
  -framework AppKit -framework Carbon -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
# Sign with a real certificate when one exists. macOS ties Accessibility
# permission to the signing identity, and an ad-hoc signature changes on every
# build, so an ad-hoc-signed app loses "Paste Directly" each time you rebuild.
SIGN_ID="${CLIPWATCH_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"')}"
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "signed as: ${SIGN_ID:-ad-hoc}"
if [ "${1:-}" = "install" ]; then
  mkdir -p ~/Applications
  # Quit only the menu-bar app, not a "Clipspan stream" helper an SSH session may be running.
  pkill -f 'MacOS/Clipspan$' || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f 'MacOS/Clipspan$' >/dev/null || break; sleep 0.3; done
  rm -rf ~/Applications/Clipspan.app
  cp -R "$APP" ~/Applications/Clipspan.app
  open -a ~/Applications/Clipspan.app
  echo "installed and started ~/Applications/Clipspan.app"
fi

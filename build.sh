#!/bin/bash
# Build Clipwatch.app on a Mac and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Clipwatch.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/Clipwatch" Sources/main.swift \
  -framework AppKit -framework Carbon -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
if [ "${1:-}" = "install" ]; then
  mkdir -p ~/Applications
  pkill -x Clipwatch || true
  rm -rf ~/Applications/Clipwatch.app
  cp -R "$APP" ~/Applications/Clipwatch.app
  open -a ~/Applications/Clipwatch.app
  echo "installed and started ~/Applications/Clipwatch.app"
fi

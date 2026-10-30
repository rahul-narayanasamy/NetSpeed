#!/bin/bash
# Builds NetSpeed.app from main.swift + Info.plist, self-tests it, and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP=/Applications/NetSpeed.app
OUT=build/NetSpeed.app
BIN="$OUT/Contents/MacOS/NetSpeed"

rm -rf build
mkdir -p "$OUT/Contents/MacOS"
cp Info.plist "$OUT/Contents/Info.plist"
# Deployment target matches LSMinimumSystemVersion in Info.plist (default would be this Mac's macOS only).
swiftc -O -target arm64-apple-macos11.0 main.swift -o "$BIN"
# Sign first (App Sandbox + Hardened Runtime), then self-test the signed binary so the
# test runs under the same sandbox the real app does.
codesign --force --sign - --options runtime --entitlements NetSpeed.entitlements "$OUT"
"$BIN" --selftest

# Build fully before touching the running app, then swap it in.
pkill -x NetSpeed 2>/dev/null || true
while pgrep -x NetSpeed >/dev/null; do sleep 0.2; done
rm -rf "$APP"
ditto "$OUT" "$APP"
open "$APP"
echo "Rebuilt and relaunched NetSpeed ✅"

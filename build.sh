#!/bin/bash
# Rebuilds NetSpeed.app in /Applications from main.swift
set -e
APP=/Applications/NetSpeed.app
mkdir -p "$APP/Contents/MacOS"
cd "$(dirname "$0")"
swiftc -O main.swift -o "$APP/Contents/MacOS/NetSpeed"
codesign --force --sign - "$APP"
pkill -f "MacOS/NetSpeed" 2>/dev/null || true
sleep 1
open "$APP"
echo "Rebuilt and relaunched NetSpeed ✅"

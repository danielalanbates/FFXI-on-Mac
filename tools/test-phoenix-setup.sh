#!/bin/bash
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# https://batesai.org · help@batesai.org
# One offline check run. No game, browser, account or network service is contacted.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEST_OUT="${1:-$HOME/Downloads/FFXI-on-Mac-build/phoenix-selftest}"
mkdir -p "$TEST_OUT"
SOURCES="$REPO/app/Sources/HorizonXILauncher"
swiftc "$SOURCES/PhoenixSetup.swift" "$SOURCES/PhoenixGameLaunch.swift" \
  "$SOURCES/Detach.swift" "$SOURCES/Bridge.swift" "$REPO/tools/PhoenixSetupSelfTest.swift" \
  -o "$TEST_OUT/checks"
PHOENIX_TEST_DIR="$TEST_OUT/fixtures" "$TEST_OUT/checks"

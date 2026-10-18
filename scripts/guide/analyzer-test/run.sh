#!/bin/zsh
# Builds and runs the synthetic obstacle-geometry check on the Mac (see main.swift).
# Usage (from mobile/): scripts/guide/analyzer-test/run.sh
set -e
cd "$(dirname "$0")/../../.."
OUT=${TMPDIR:-/tmp}/guide-analyzer-test
swiftc -O modules/perception/ios/ObstacleAnalyzer.swift scripts/guide/analyzer-test/main.swift -o "$OUT"
"$OUT"

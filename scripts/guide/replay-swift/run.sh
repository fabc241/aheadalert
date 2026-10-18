#!/bin/zsh
# Builds and runs the app's obstacle analysis on a recording (see main.swift).
# Usage (from mobile/): scripts/guide/replay-swift/run.sh scripts/guide/logs/rec-<date>
set -e
REC=${1:A}
cd "$(dirname "$0")/../../.."
OUT=${TMPDIR:-/tmp}/guide-replay-swift
swiftc -O modules/perception/ios/ObstacleAnalyzer.swift scripts/guide/replay-swift/main.swift -o "$OUT"
"$OUT" "$REC"

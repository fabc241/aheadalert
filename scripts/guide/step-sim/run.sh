#!/bin/zsh
# Builds and runs the walking simulation of the step tests on the Mac (see main.swift).
# Usage (from mobile/): scripts/guide/step-sim/run.sh
set -e
cd "$(dirname "$0")/../../.."
OUT=${TMPDIR:-/tmp}/guide-step-sim
swiftc -O modules/perception/ios/ObstacleAnalyzer.swift scripts/guide/analyzer-test/Scene.swift \
  scripts/guide/step-sim/main.swift -o "$OUT"
"$OUT"

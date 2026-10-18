#!/bin/zsh
# Builds and runs the synthetic light-passage check on the Mac (see main.swift).
# Usage (from mobile/): scripts/guide/light-test/run.sh
set -e
cd "$(dirname "$0")/../../.."
OUT=${TMPDIR:-/tmp}/guide-light-test
swiftc -O modules/perception/ios/LightAnalyzer.swift modules/perception/ios/ReliabilityMonitor.swift scripts/guide/light-test/main.swift -o "$OUT"
"$OUT"

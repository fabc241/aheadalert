#!/bin/zsh
# Builds and runs the synthetic reliability-level check on the Mac (see main.swift).
# Usage (from mobile/): scripts/guide/reliability-test/run.sh
set -e
cd "$(dirname "$0")/../../.."
OUT=${TMPDIR:-/tmp}/guide-reliability-test
swiftc -O modules/perception/ios/ReliabilityMonitor.swift scripts/guide/reliability-test/main.swift -o "$OUT"
"$OUT"

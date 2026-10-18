#!/bin/zsh
# Builds and runs the app's light-passage analysis (MVP step 1.4) on recordings (see main.swift).
# Usage (from mobile/): scripts/guide/light-replay/run.sh scripts/guide/logs/rec-<date> [more recordings…]
# VERBOSE=1 prints every frame, not only those with a passage.
set -e
RECS=(${@:A})
cd "$(dirname "$0")/../../.."
OUT=${TMPDIR:-/tmp}/guide-light-replay
swiftc -O modules/perception/ios/LightAnalyzer.swift modules/perception/ios/ReliabilityMonitor.swift scripts/guide/light-replay/main.swift -o "$OUT"
"$OUT" "${RECS[@]}"

#!/bin/zsh
# Phase 0B: fetches the results from the iPhone (reports, depth maps, audio, camera shots).
# Usage (from mobile/): scripts/phase0/fetch-from-iphone.sh
set -e
cd "$(dirname "$0")"
[[ -f ../../.env.local ]] && source ../../.env.local  # local, not committed: DEVICE=<iPhone UDID>
DEVICE=${DEVICE:?set DEVICE to the iPhone UDID (xcrun devicectl list devices), e.g. in .env.local}
APP=io.github.fabc241.aheadalert
mkdir -p results/iphone
for item in results shots; do
  xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" \
    --source "Documents/phase0/$item" --destination "results/iphone/$item" >/dev/null || true
done
echo "Results in scripts/phase0/results/iphone"

#!/bin/zsh
# MVP: fetches the obstacle guide logs and recordings (Documents/guide) from the iPhone.
# One CSV per session: start/stop, every voice alert (zone, distance, low), hints, and a stat line per second.
# rec-<date>/: diagnostic recording, twice a second (image, depth, pose, ARKit feature points, analysis);
# view it with scripts/guide/replay.py or scripts/guide/replay-swift/run.sh. Personal images: gitignored.
# Step 1.8: also Documents/describe (describe-log.csv: times and texts of "Cosa ho davanti?"; shot.jpg, the last photo).
# Usage (from mobile/): scripts/guide/fetch-logs.sh
set -e
cd "$(dirname "$0")"
[[ -f ../../.env.local ]] && source ../../.env.local  # local, not committed: DEVICE=<iPhone UDID>
DEVICE=${DEVICE:?set DEVICE to the iPhone UDID (xcrun devicectl list devices), e.g. in .env.local}
APP=io.github.fabc241.aheadalert
mkdir -p logs
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" \
  --source "Documents/guide" --destination logs >/dev/null
mkdir -p logs/describe
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" \
  --source "Documents/describe" --destination logs/describe >/dev/null 2>&1 || echo "(no description log yet)"
echo "Logs in scripts/guide/logs"

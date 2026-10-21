#!/bin/zsh
# MVP step 1.9: fetches the voice command log (Documents/voice/voice-log.csv) from the iPhone, on its own (the guide's
# fetch-logs.sh also copies gigabytes of recordings). One line per phrase heard: text, command or why it was
# ignored, what the app was saying, time from the end of the speech to the text; and start/stop/memory lines.
# Usage (from mobile/): scripts/voice/fetch-log.sh   → scripts/voice/logs/voice-log.csv (gitignored: personal)
set -e
cd "$(dirname "$0")"
[[ -f ../../.env.local ]] && source ../../.env.local  # local, not committed: DEVICE=<iPhone UDID>
DEVICE=${DEVICE:?set DEVICE to the iPhone UDID (xcrun devicectl list devices), e.g. in .env.local}
APP=io.github.fabc241.guidavisiva
mkdir -p logs
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" \
  --source "Documents/voice" --destination logs >/dev/null
echo "Log in scripts/voice/logs"

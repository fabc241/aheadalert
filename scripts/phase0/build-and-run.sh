#!/bin/zsh
# Phase 0B: builds (Release), installs on the iPhone and launches the app.
# Optional: comma-separated list of tests to run automatically, e.g.
#   scripts/phase0/build-and-run.sh ocr,descriptions
# Tests: depth-photos, depth-live, depth-long, what-is-ahead, describe-10 (step 1.8), descriptions, ocr, voice, classification
# CONSOLE=1 streams the app output (memory trace, errors) until it exits. SKIP_BUILD=1 only launches.
set -e
cd "$(dirname "$0")/../../ios"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
[[ -f ../.env.local ]] && source ../.env.local  # local, not committed: DEVICE=<iPhone UDID>
DEVICE=${DEVICE:?set DEVICE to the iPhone UDID (xcrun devicectl list devices), e.g. in .env.local}
APP=io.github.fabc241.guidavisiva
if [[ -z "$SKIP_BUILD" ]]; then
  mkdir -p build
  xcodebuild -workspace GuidaVisiva.xcworkspace -scheme GuidaVisiva -configuration Release \
    -destination "id=$DEVICE" -derivedDataPath build -allowProvisioningUpdates build > build/phase0-build.log 2>&1 \
    || { grep -E "error:" build/phase0-build.log | head -20; exit 1; }
  echo "Build succeeded."
  xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Release-iphoneos/GuidaVisiva.app >/dev/null
  echo "Installed."
fi
args=(--device "$DEVICE" --terminate-existing --environment-variables "{\"PHASE0_AUTO\":\"${1:-}\"}")
[[ -n "$CONSOLE" ]] && args+=(--console)
xcrun devicectl device process launch "${args[@]}" "$APP"

#!/bin/zsh
# Phase 0B: copies the depth model, test photos and classifier weights into the app on the iPhone
# (Documents/phase0). The photos stay out of the app bundle. Usage (from mobile/): scripts/phase0/copy-to-iphone.sh
set -e
cd "$(dirname "$0")"
DEVICE=${DEVICE:-YOUR-IPHONE-UDID}
APP=io.github.fabc241.guidavisiva
for item in models/DepthAnythingV2SmallF16.mlpackage real-photos images; do
  dest="Documents/phase0/$(basename "$item")"
  echo "→ $item"
  xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" \
    --source "$item" --destination "$dest" >/dev/null
done
# MobileNetV3 classifier weights: shipped in the npm package but not in the QVAC mobile bundle
echo "→ MobileNetV3 weights"
xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" \
  --source ../../node_modules/@qvac/classification-ggml/weights/mobilenetv3_3class_v3_fp16.gguf \
  --destination Documents/phase0/models/mobilenetv3_3class_v3_fp16.gguf >/dev/null
echo "Copy complete."

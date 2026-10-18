#!/bin/zsh
# Fase 0B: copia modello di profondità e foto di prova nell'app sull'iPhone (Documents/fase0).
# Le foto restano fuori dal pacchetto dell'app. Uso (dalla cartella mobile/): scripts/fase0/copia-su-iphone.sh
set -e
cd "$(dirname "$0")"
DEVICE=${DEVICE:-YOUR-IPHONE-UDID}
APP=io.github.fabc241.guidavisiva
for item in modelli/DepthAnythingV2SmallF16.mlpackage immagini-reali immagini; do
  dest="Documents/fase0/$(basename "$item")"
  echo "→ $item"
  xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" \
    --source "$item" --destination "$dest" >/dev/null
done
# Pesi del classificatore MobileNetV3: inclusi nel pacchetto npm ma non nel bundle mobile di QVAC
echo "→ pesi MobileNetV3"
xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" \
  --source ../../node_modules/@qvac/classification-ggml/weights/mobilenetv3_3class_v3_fp16.gguf \
  --destination Documents/fase0/modelli/mobilenetv3_3class_v3_fp16.gguf >/dev/null
echo "Copia completata."

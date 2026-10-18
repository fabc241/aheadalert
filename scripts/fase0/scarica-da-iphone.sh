#!/bin/zsh
# Fase 0B: scarica dall'iPhone i risultati (rapporti .md, mappe di profondità, audio, scatti).
# Uso (dalla cartella mobile/): scripts/fase0/scarica-da-iphone.sh
set -e
cd "$(dirname "$0")"
DEVICE=${DEVICE:-YOUR-IPHONE-UDID}
APP=io.github.fabc241.guidavisiva
mkdir -p risultati/iphone
for item in risultati scatti; do
  xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" \
    --source "Documents/fase0/$item" --destination "risultati/iphone/$item" >/dev/null || true
done
echo "Risultati in scripts/fase0/risultati/iphone"

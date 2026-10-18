#!/bin/zsh
# Fase 0B: compila (Release), installa sull'iPhone e avvia l'app.
# Facoltativo: elenco di prove da eseguire in automatico, es.
#   scripts/fase0/installa-e-avvia.sh ocr,descrizioni
# Prove: profondita-foto, profondita-vivo, profondita-lunga, cosa-ho-davanti, descrizioni, ocr, voce, classificazione
# Con CONSOLE=1 mostra l'output dell'app (memoria, errori) fino alla sua chiusura.
set -e
cd "$(dirname "$0")/../../ios"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
DEVICE=${DEVICE:-YOUR-IPHONE-UDID}
APP=io.github.fabc241.guidavisiva
if [[ -z "$SKIP_BUILD" ]]; then
  xcodebuild -workspace GuidaVisiva.xcworkspace -scheme GuidaVisiva -configuration Release \
    -destination "id=$DEVICE" -derivedDataPath build -allowProvisioningUpdates build > build/fase0-build.log 2>&1 \
    || { grep -E "error:" build/fase0-build.log | head -20; exit 1; }
  echo "Compilazione riuscita."
  xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Release-iphoneos/GuidaVisiva.app >/dev/null
  echo "Installata."
fi
args=(--device "$DEVICE" --terminate-existing --environment-variables "{\"FASE0_AUTO\":\"${1:-}\"}")
[[ -n "$CONSOLE" ]] && args+=(--console)
xcrun devicectl device process launch "${args[@]}" "$APP"

#!/bin/bash
# Compila VSplit y monta build/VSplit.app (universal arm64 + x86_64, firmada ad-hoc).
#   Scripts/build-app.sh                  → universal, firma ad-hoc
#   NATIVE=1 Scripts/build-app.sh         → solo la arquitectura de este Mac (más rápido)
#   SIGN_ID="Developer ID Application: …" Scripts/build-app.sh   → firma con tu certificado
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-io.github.jdevesablanco.VSplit}"
VERSION="${VERSION:-1.0.0}"
SIGN_ID="${SIGN_ID:--}"
OUT="${OUT:-build}"
APP="$OUT/VSplit.app"

ARCHS=(--arch arm64 --arch x86_64)
if [[ "${NATIVE:-0}" == "1" ]]; then ARCHS=(); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

[[ -f Resources/AppIcon.icns ]] || swift Scripts/make-icon.swift Resources/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VSplitApp" "$APP/Contents/MacOS/VSplit"
cp "$BIN/vsplit" "$APP/Contents/Resources/vsplit"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Background.jpg "$APP/Contents/Resources/Background.jpg"
cp -R Resources/es.lproj Resources/en.lproj "$APP/Contents/Resources/"
sed -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" -e "s/@VERSION@/$VERSION/g" Resources/Info.plist.template > "$APP/Contents/Info.plist"

OPTS=()
if [[ "$SIGN_ID" != "-" ]]; then OPTS=(--options runtime --timestamp); fi
codesign --force --sign "$SIGN_ID" ${OPTS[@]+"${OPTS[@]}"} "$APP/Contents/Resources/vsplit"
codesign --force --sign "$SIGN_ID" ${OPTS[@]+"${OPTS[@]}"} "$APP"
codesign --verify --deep --strict "$APP" && echo "✓ firma verificada ($([[ "$SIGN_ID" == "-" ]] && echo ad-hoc || echo "$SIGN_ID"))"
lipo -archs "$APP/Contents/MacOS/VSplit"
echo "✓ $APP"

#!/bin/bash
# Uso: Scripts/release.sh 1.0.1
# 1) sube la versión en la app, la CLI y el cask  2) crea el tag y lo empuja (la CI publica DMG + PKG en el Release)
# 3) cuando el Release existe, rellena el sha256 del cask para el tap jdevesablanco/homebrew-tap.
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:?uso: Scripts/release.sh X.Y.Z}"
sed -i '' "s|version \"[0-9.]*\"|version \"$V\"|" homebrew/Casks/vsplit.rb
sed -i '' "s|static let version = \"[0-9.]*\"|static let version = \"$V\"|" Sources/VSplitCore/Engine/Version.swift
git add -A && git commit -m "Release v$V" && git tag "v$V" && git push origin main "v$V"

echo "Esperando a que la CI publique el DMG…"
DMG="https://github.com/jdevesablanco/VSplit/releases/download/v$V/VSplit-$V.dmg"
until curl -sfIL "$DMG" >/dev/null; do sleep 20; done
DMG_SHA="$(curl -sL "$DMG" | shasum -a 256 | cut -d' ' -f1)"
sed -i '' "s|sha256 \"[0-9a-zA-Z_:]*\"|sha256 \"$DMG_SHA\"|" homebrew/Casks/vsplit.rb
echo "Cask sha256 = $DMG_SHA"
echo "Copia homebrew/Casks/vsplit.rb a jdevesablanco/homebrew-tap y haz push."

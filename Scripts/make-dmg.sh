#!/bin/bash
# build/VSplit.app → build/VSplit-<versión>.dmg (con acceso directo a Aplicaciones)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
[[ -d build/VSplit.app ]] || Scripts/build-app.sh
STAGE="$(mktemp -d)"
cp -R build/VSplit.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/LEEME - README.txt" <<'TXT'
VSplit — arrastra VSplit.app a Aplicaciones y ábrela. / Drag VSplit.app to Applications and open it.
Si macOS dice que no puede verificar la app: Ajustes del Sistema → Privacidad y seguridad → «Abrir igualmente».
If macOS says it can't verify the app: System Settings → Privacy & Security → "Open Anyway".
(La app no está notarizada por Apple; es software libre y el código está en GitHub.)
TXT
rm -f "build/VSplit-$VERSION.dmg"
hdiutil create -volname "VSplit" -srcfolder "$STAGE" -ov -format UDZO "build/VSplit-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
echo "✓ build/VSplit-$VERSION.dmg"

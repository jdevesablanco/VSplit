# Notarizar VSplit (opcional, de pago)

VSplit se distribuye firmada *ad-hoc* (gratis). Funciona perfectamente en el Mac que la compila y con `brew install --cask`
(el cask le quita la cuarentena), pero un `.dmg` o `.pkg` descargado hace que Gatekeeper pida «Abrir igualmente» la primera vez.

Para quitar ese paso hace falta una cuenta de **Apple Developer Program (99 USD/año)**:

1. Crea un certificado «Developer ID Application» y expórtalo como `.p12`.
2. Crea una contraseña específica de app para notarizar (appleid.apple.com).
3. En local:
   ```bash
   SIGN_ID="Developer ID Application: Tu Nombre (TEAMID)" Scripts/build-app.sh
   Scripts/make-dmg.sh
   xcrun notarytool submit build/VSplit-1.0.0.dmg --apple-id TU_ID --team-id TEAMID --password APP_PASSWORD --wait
   xcrun stapler staple build/VSplit-1.0.0.dmg
   ```
4. En GitHub Actions: guarda el `.p12` (base64), su contraseña y las credenciales de `notarytool` como *secrets* y añade los pasos
   anteriores al workflow (`import certificate` → `build-app.sh` con `SIGN_ID` → `notarytool` → `stapler`).

El script ya usa *hardened runtime* y *timestamp* cuando `SIGN_ID` no es `-`.

Nota: con firma ad-hoc, macOS puede volver a pedir el permiso de Accesibilidad tras actualizar la app (la firma cambia en cada compilación).

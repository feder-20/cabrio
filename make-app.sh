#!/bin/bash
# Compila Cabrio y arma build/Cabrio.app (firma ad hoc; para desarrollo).
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(cat VERSION)

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

APP=build/Cabrio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Cabrio" "$APP/Contents/MacOS/Cabrio"

# Ícono de la app (.icns desde el PNG de 1024 del kit de marca).
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
SRC=Resources/Brand/cabrio-icono-app-negro-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Brand/cabrio-barra-menu-template@2x.png "$APP/Contents/Resources/MenuBarIcon.png"
cp Resources/Brand/cabrio-simbolo-negro-transparente-512.png "$APP/Contents/Resources/Symbol.png"

for lang in Resources/*.lproj; do [ -d "$lang" ] && cp -R "$lang" "$APP/Contents/Resources/"; done

# Acción rápida del Finder («Cabrio» en el clic derecho). Se regenera desde la plantilla si falta.
if [ ! -d QuickAction/Cabrio.workflow ]; then echo "Falta QuickAction/Cabrio.workflow (python3 QuickAction/make-workflow.py <plantilla.wflow>)"; exit 1; fi
cp -R QuickAction/Cabrio.workflow "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Cabrio</string>
  <key>CFBundleDisplayName</key><string>Cabrio</string>
  <key>CFBundleIdentifier</key><string>com.chocolitossoft.cabrio</string>
  <key>CFBundleExecutable</key><string>Cabrio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>CFBundleLocalizations</key><array><string>es</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Cabrio lee la selección del Finder para abrirla con sus acciones. Nada sale de tu Mac.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Cabrio necesita acceder al Escritorio para aplicar tus reglas de carpeta y procesar los archivos que elijas.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Cabrio necesita acceder a Descargas para aplicar tus reglas de carpeta y procesar los archivos que elijas.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Cabrio necesita acceder a Documentos para procesar los archivos que elijas y guardar los resultados al lado.</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 ChocolitosSoft</string>
</dict></plist>
EOF

# Firma: por defecto ad hoc (desarrollo). Con CABRIO_SIGN_ID="Developer ID Application: …" queda lista para notarizar.
SIGN_ID="${CABRIO_SIGN_ID:--}"
SIGN_ARGS=(--force --options runtime --entitlements Distribution/Cabrio.entitlements --sign "$SIGN_ID")
[ "$SIGN_ID" != "-" ] && SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Listo: $APP (v$VERSION)"

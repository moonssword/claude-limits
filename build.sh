#!/bin/bash
# Собирает ClaudeUsage.app из SwiftPM-пакета.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="ClaudeUsage"
BUNDLE_ID="com.ibulat.claudeusage"
VERSION="1.0.0"
APP="build/${APP_NAME}.app"

echo "▸ Сборка бинарника…"
swift build -c release

echo "▸ Сборка бандла…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/${APP_NAME}" "$APP/Contents/MacOS/${APP_NAME}"

echo "▸ Иконка…"
ICONSET="build/icon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512 1024; do
  swift Tools/make-icon.swift "$size" "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
# Retina-варианты
cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Лимиты Claude</string>
  <key>CFBundleDisplayName</key><string>Лимиты Claude</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Локальный просмотр лимитов Claude</string>
</dict>
</plist>
PLIST

echo "▸ Подпись (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Готово: $APP"

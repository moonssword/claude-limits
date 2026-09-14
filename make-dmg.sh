#!/bin/bash
# Собирает установочный образ build/ClaudeUsage-<версия>.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ClaudeUsage.app"
[ -d "$APP" ] || ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/ClaudeUsage-${VERSION}.dmg"
STAGE="build/dmg"

echo "▸ Подготовка содержимого…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ Создание образа…"
hdiutil create -volname "Claude Limits" \
  -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ Готово: $DMG"
shasum -a 256 "$DMG"

#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist")"
DMG="$ROOT/outputs/TartR-$VERSION-macos.dmg"
MANIFEST="$ROOT/outputs/TartR-update.json"

[[ -f "$MANIFEST" ]]
/usr/bin/plutil -convert json -o /dev/null "$MANIFEST"
[[ "$(/usr/bin/plutil -extract schemaVersion raw -o - "$MANIFEST")" == "1" ]]
[[ "$(/usr/bin/plutil -extract version raw -o - "$MANIFEST")" == "$VERSION" ]]
[[ "$(/usr/bin/plutil -extract minimumSystemVersion raw -o - "$MANIFEST")" == "$MINIMUM_SYSTEM" ]]
DOWNLOAD_URL="$(/usr/bin/plutil -extract downloadURL raw -o - "$MANIFEST")"
RELEASE_NOTES_URL="$(/usr/bin/plutil -extract releaseNotesURL raw -o - "$MANIFEST")"
SHA256="$(/usr/bin/plutil -extract sha256 raw -o - "$MANIFEST")"
FILE_SIZE="$(/usr/bin/plutil -extract fileSize raw -o - "$MANIFEST")"
[[ "$DOWNLOAD_URL" == https://*"/TartR-$VERSION-macos.dmg" ]]
[[ "$RELEASE_NOTES_URL" == https://* ]]
[[ "$SHA256" == "$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk '{print $1}')" ]]
[[ "$FILE_SIZE" == "$(/usr/bin/stat -f '%z' "$DMG")" ]]
[[ "$FILE_SIZE" -gt 0 && "$FILE_SIZE" -le $((512 * 1024 * 1024)) ]]
print -r -- "$SHA256" | /usr/bin/grep -Eq '^[0-9a-f]{64}$'

echo "Verified update manifest for TartR $VERSION."

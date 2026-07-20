#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist")"
DMG="$ROOT/outputs/TartR-$VERSION-macos.dmg"
CHECKSUM="$DMG.sha256"
MANIFEST="$ROOT/outputs/TartR-update.json"
RELEASE_BASE_URL="${RELEASE_BASE_URL:?RELEASE_BASE_URL is required}"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:?RELEASE_NOTES_URL is required}"

if [[ "$RELEASE_BASE_URL" != https://* || "$RELEASE_NOTES_URL" != https://* ]]; then
  print -u2 "Release URLs must use HTTPS."
  exit 1
fi
if [[ ! -f "$DMG" || ! -f "$CHECKSUM" ]]; then
  print -u2 "Build and checksum the release DMG before generating the update manifest."
  exit 1
fi

/usr/bin/shasum -a 256 -c "$CHECKSUM"
SHA256="$(/usr/bin/awk '{print $1}' "$CHECKSUM")"
DOWNLOAD_URL="${RELEASE_BASE_URL%/}/TartR-$VERSION-macos.dmg"

/bin/rm -f "$MANIFEST"
/usr/bin/plutil -create xml1 "$MANIFEST"
/usr/bin/plutil -insert schemaVersion -integer 1 "$MANIFEST"
/usr/bin/plutil -insert version -string "$VERSION" "$MANIFEST"
/usr/bin/plutil -insert minimumSystemVersion -string "$MINIMUM_SYSTEM" "$MANIFEST"
/usr/bin/plutil -insert downloadURL -string "$DOWNLOAD_URL" "$MANIFEST"
/usr/bin/plutil -insert releaseNotesURL -string "$RELEASE_NOTES_URL" "$MANIFEST"
/usr/bin/plutil -insert sha256 -string "$SHA256" "$MANIFEST"
/usr/bin/plutil -convert json -r "$MANIFEST"
/usr/bin/plutil -convert json -o /dev/null "$MANIFEST"

echo "$MANIFEST"

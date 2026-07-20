#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/outputs"
APP="$OUTPUT/TartR.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$OUTPUT/TartR-$VERSION-macos.dmg"
STAGING="${TMPDIR:-/tmp}/tartr-dmg-staging-$$"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

trap '/bin/rm -rf "$STAGING"' EXIT

if [[ ! -d "$APP" ]]; then
  print -u2 "Build TartR.app before creating the DMG."
  exit 1
fi

for old_archive in "$OUTPUT"/TartR-*-macos.dmg(N) "$OUTPUT"/TartR-*-macos.dmg.sha256(N); do
  /bin/rm -f "$old_archive"
done
/bin/rm -rf "$STAGING"
/bin/mkdir -p "$STAGING"
/usr/bin/ditto --norsrc "$APP" "$STAGING/TartR.app"
/bin/ln -s /Applications "$STAGING/Applications"
/usr/bin/hdiutil create \
  -volname "TartR $VERSION" \
  -srcfolder "$STAGING" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov "$DMG"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --sign - "$DMG"
else
  /usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
/usr/bin/codesign --verify --verbose=2 "$DMG"
/usr/bin/hdiutil verify "$DMG"
/usr/bin/shasum -a 256 "$DMG" > "$DMG.sha256"

echo "$DMG"

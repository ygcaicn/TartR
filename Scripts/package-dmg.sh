#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/outputs"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ZIP="$OUTPUT/TartR-$VERSION-macos.zip"
DMG="$OUTPUT/TartR-$VERSION-macos.dmg"
STAGING="${TMPDIR:-/tmp}/tartr-dmg-staging-$$"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

trap '/bin/rm -rf "$STAGING"' EXIT

if [[ ! -f "$ZIP" ]]; then
  print -u2 "Build the TartR ZIP before creating the DMG."
  exit 1
fi

for old_archive in "$OUTPUT"/TartR-*-macos.dmg(N) "$OUTPUT"/TartR-*-macos.dmg.sha256(N); do
  /bin/rm -f "$old_archive"
done
/bin/rm -rf "$STAGING"
/bin/mkdir -p "$STAGING"
/usr/bin/ditto -x -k "$ZIP" "$STAGING"
/usr/bin/xattr -cr "$STAGING/TartR.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING/TartR.app"
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
(
  cd "$OUTPUT"
  /usr/bin/shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256"
)

echo "$DMG"

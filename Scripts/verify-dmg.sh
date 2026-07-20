#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$ROOT/outputs/TartR-$VERSION-macos.dmg"
MOUNT_POINT="${TMPDIR:-/tmp}/tartr-dmg-verify-$$"
APP="$MOUNT_POINT/TartR.app"
EXPECTED_BUNDLE_ID="com.caiyagang.tartr"
ATTACHED=false

cleanup() {
  if $ATTACHED; then /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true; fi
  /bin/rm -rf "$MOUNT_POINT"
}
trap cleanup EXIT

/usr/bin/shasum -a 256 -c "$DMG.sha256"
/usr/bin/codesign --verify --verbose=2 "$DMG"
/usr/bin/hdiutil verify "$DMG"
/bin/mkdir -p "$MOUNT_POINT"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG" >/dev/null
ATTACHED=true

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/lipo "$APP/Contents/MacOS/TartR" -verify_arch arm64 x86_64
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "$EXPECTED_BUNDLE_ID" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]]
[[ -L "$MOUNT_POINT/Applications" ]]
[[ "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" == "/Applications" ]]

SIGNATURE_INFO="$(/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1)"
if [[ "$SIGNATURE_INFO" == *"Signature=adhoc"* ]]; then
  echo "Verified development DMG (ad-hoc signed)."
else
  [[ "$SIGNATURE_INFO" == *"runtime"* ]]
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  echo "Verified signed and notarized DMG."
fi

#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ZIP="$ROOT/outputs/TartR-$VERSION-macos.zip"
DMG="$ROOT/outputs/TartR-$VERSION-macos.dmg"
PROFILE="${NOTARY_PROFILE:-TartR-notary}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
STAGING_DIR="${TMPDIR:-/tmp}/tartr-notarize-$$"
STAGED_APP="$STAGING_DIR/TartR.app"

trap '/bin/rm -rf "$STAGING_DIR"' EXIT

if [[ ! -f "$ZIP" ]]; then
  echo "Build TartR first with SIGN_IDENTITY set to a Developer ID Application certificate." >&2
  exit 1
fi

/bin/mkdir -p "$STAGING_DIR"
/usr/bin/ditto -x -k "$ZIP" "$STAGING_DIR"
/usr/bin/xattr -cr "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
SIGNATURE_INFO="$(/usr/bin/codesign -dv --verbose=4 "$STAGED_APP" 2>&1)"
if [[ "$SIGNATURE_INFO" == *"Signature=adhoc"* \
  || "$SIGNATURE_INFO" != *"Authority=Developer ID Application"* \
  || "$SIGNATURE_INFO" != *"runtime"* \
  || "$SIGNATURE_INFO" != *"Timestamp="* ]]; then
  print -u2 "TartR.app must have a timestamped Developer ID Application signature with Hardened Runtime before notarization."
  exit 1
fi
if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
  print -u2 "SIGN_IDENTITY is required to sign the release DMG."
  exit 1
fi

/usr/bin/ditto -c -k --keepParent --norsrc "$STAGED_APP" "$ZIP"
/usr/bin/xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
/usr/bin/xcrun stapler staple "$STAGED_APP"
/usr/bin/xcrun stapler validate "$STAGED_APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$STAGED_APP"
/usr/bin/ditto -c -k --keepParent --norsrc "$STAGED_APP" "$ZIP"
/usr/bin/shasum -a 256 "$ZIP" > "$ZIP.sha256"
SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT/Scripts/package-dmg.sh"
/usr/bin/xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
/usr/bin/xcrun stapler staple "$DMG"
/usr/bin/xcrun stapler validate "$DMG"
/usr/bin/codesign --verify --verbose=2 "$DMG"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
/usr/bin/shasum -a 256 "$DMG" > "$DMG.sha256"

echo "Notarized releases: $ZIP and $DMG"

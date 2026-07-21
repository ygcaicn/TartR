#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ZIP="$ROOT/outputs/TartR-$VERSION-macos.zip"
VERIFY_DIR="${TMPDIR:-/tmp}/tartr-release-verify-$$"
APP="$VERIFY_DIR/TartR.app"
EXPECTED_BUNDLE_ID="com.caiyagang.tartr"

trap '/bin/rm -rf "$VERIFY_DIR"' EXIT

/bin/rm -rf "$VERIFY_DIR"
/bin/mkdir -p "$VERIFY_DIR"
/usr/bin/ditto -x -k "$ZIP" "$VERIFY_DIR"
/usr/bin/xattr -cr "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/plutil -lint \
  "$APP/Contents/Resources/en.lproj/Localizable.strings" \
  "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"
[[ "$(/usr/bin/plutil -extract __language__ raw "$APP/Contents/Resources/en.lproj/Localizable.strings")" == "English" ]]
[[ "$(/usr/bin/plutil -extract Run raw "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings")" == "启动" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDevelopmentRegion' "$APP/Contents/Info.plist")" == "en" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleLocalizations:0' "$APP/Contents/Info.plist")" == "en" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleLocalizations:1' "$APP/Contents/Info.plist")" == "zh-Hans" ]]
/usr/bin/lipo "$APP/Contents/MacOS/TartR" -verify_arch arm64 x86_64
/usr/bin/shasum -a 256 -c "$ZIP.sha256"

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
[[ "$ACTUAL_VERSION" == "$VERSION" ]]
[[ "$BUILD_NUMBER" == <-> ]]
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]]
[[ "$EXECUTABLE" == "TartR" ]]

SIGNATURE_INFO="$(/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1)"
if [[ "$SIGNATURE_INFO" == *"Signature=adhoc"* ]]; then
  echo "Verified development release (ad-hoc signed)."
else
  [[ "$SIGNATURE_INFO" == *"runtime"* ]]
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
  echo "Verified signed release."
fi

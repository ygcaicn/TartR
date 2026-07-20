#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
ZIP="$ROOT/outputs/TartR-4.0-macos.zip"
VERIFY_DIR="$ROOT/.build/verify-release"
APP="$VERIFY_DIR/TartR.app"

/bin/rm -rf "$VERIFY_DIR"
/bin/mkdir -p "$VERIFY_DIR"
/usr/bin/ditto -x -k "$ZIP" "$VERIFY_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/lipo "$APP/Contents/MacOS/TartR" -verify_arch arm64 x86_64
/usr/bin/shasum -a 256 -c "$ZIP.sha256"

SIGNATURE_INFO="$(/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1)"
if [[ "$SIGNATURE_INFO" == *"Signature=adhoc"* ]]; then
  echo "Verified development release (ad-hoc signed)."
else
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
  echo "Verified signed release."
fi

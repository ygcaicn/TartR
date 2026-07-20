#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/outputs/TartR.app"
ZIP="$ROOT/outputs/TartR-4.0.0-macos.zip"
PROFILE="${NOTARY_PROFILE:-TartR-notary}"

if [[ ! -d "$APP" ]]; then
  echo "Build TartR first with SIGN_IDENTITY set to a Developer ID Application certificate." >&2
  exit 1
fi

/usr/bin/ditto -c -k --keepParent --norsrc "$APP" "$ZIP"
/usr/bin/xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
/usr/bin/xcrun stapler staple "$APP"
/usr/bin/xcrun stapler validate "$APP"
/usr/bin/ditto -c -k --keepParent --norsrc "$APP" "$ZIP"
/usr/bin/shasum -a 256 "$ZIP" > "$ZIP.sha256"

echo "Notarized release: $ZIP"

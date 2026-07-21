#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/outputs"
BUILD="$ROOT/.build/release-app"
STAGING_ROOT="${TMPDIR:-/tmp}/tartr-app-build-$$"
STAGED_APP="$STAGING_ROOT/TartR.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ZIP="$OUTPUT/TartR-$VERSION-macos.zip"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
UPDATE_MANIFEST_URL="${UPDATE_MANIFEST_URL:-}"

trap '/bin/rm -rf "$STAGING_ROOT"' EXIT

if [[ -n "$UPDATE_MANIFEST_URL" && "$UPDATE_MANIFEST_URL" != https://* ]]; then
  print -u2 "UPDATE_MANIFEST_URL must use HTTPS."
  exit 1
fi

for old_archive in "$OUTPUT"/TartR-*-macos.zip(N) "$OUTPUT"/TartR-*-macos.zip.sha256(N); do
  rm -f "$old_archive"
done
rm -f "$OUTPUT/TartR-update.json"
rm -rf "$OUTPUT/TartR.app" "$BUILD" "$STAGING_ROOT"
mkdir -p \
  "$STAGED_APP/Contents/MacOS" \
  "$STAGED_APP/Contents/Resources" \
  "$BUILD/AppIcon.iconset" \
  "$OUTPUT"

build_arch() {
  local arch="$1"
  local scratch="$ROOT/.build/release-$arch"
  /usr/bin/swift build --package-path "$ROOT" --configuration release --arch "$arch" --scratch-path "$scratch"
  /usr/bin/swift build --package-path "$ROOT" --configuration release --arch "$arch" --scratch-path "$scratch" --show-bin-path
}

ARM_BIN_DIR="$(build_arch arm64 | tail -n 1)"
X86_BIN_DIR="$(build_arch x86_64 | tail -n 1)"
/usr/bin/lipo -create \
  "$ARM_BIN_DIR/TartR" "$X86_BIN_DIR/TartR" -output "$STAGED_APP/Contents/MacOS/TartR"

/bin/cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
/bin/cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/zh-Hans.lproj" \
  "$STAGED_APP/Contents/Resources/"
if [[ -n "$UPDATE_MANIFEST_URL" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Set :TartRUpdateManifestURL $UPDATE_MANIFEST_URL" "$STAGED_APP/Contents/Info.plist"
fi

/usr/bin/swiftc -O -framework AppKit "$ROOT/Tools/IconGenerator.swift" -o "$BUILD/icon-generator"
for size in 16 32 128 256 512; do
  "$BUILD/icon-generator" "$size" "$BUILD/AppIcon.iconset/icon_${size}x${size}.png"
  "$BUILD/icon-generator" "$((size * 2))" "$BUILD/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
/usr/bin/iconutil -c icns "$BUILD/AppIcon.iconset" -o "$STAGED_APP/Contents/Resources/AppIcon.icns"

/usr/bin/xattr -cr "$STAGED_APP"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --deep --entitlements "$ROOT/Resources/TartR.entitlements" --sign - "$STAGED_APP"
else
  /usr/bin/codesign --force --deep --options runtime --timestamp --entitlements "$ROOT/Resources/TartR.entitlements" --sign "$SIGN_IDENTITY" "$STAGED_APP"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

/usr/bin/ditto -c -k --keepParent --norsrc "$STAGED_APP" "$ZIP"
/usr/bin/shasum -a 256 "$ZIP" > "$ZIP.sha256"

echo "$ZIP"

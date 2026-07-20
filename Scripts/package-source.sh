#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
OUTPUT="$ROOT/outputs"
ARCHIVE="$OUTPUT/TartR-$VERSION-source.zip"
REF="${1:-HEAD}"

/bin/mkdir -p "$OUTPUT"
for old_archive in "$OUTPUT"/TartR-*-source.zip(N) "$OUTPUT"/TartR-*-source.zip.sha256(N); do
  /bin/rm -f "$old_archive"
done
/usr/bin/git -C "$ROOT" archive --format=zip --prefix="TartR-$VERSION/" -o "$ARCHIVE" "$REF"
/usr/bin/shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"

echo "$ARCHIVE"

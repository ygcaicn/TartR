#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
REF="${1:-HEAD}"
VERSION="$(
  /usr/bin/git -C "$ROOT" show "$REF:Resources/Info.plist" \
    | /usr/bin/plutil -extract CFBundleShortVersionString raw -o - -
)"
OUTPUT="$ROOT/outputs"
ARCHIVE="$OUTPUT/TartR-$VERSION-source.zip"

/bin/mkdir -p "$OUTPUT"
for old_archive in "$OUTPUT"/TartR-*-source.zip(N) "$OUTPUT"/TartR-*-source.zip.sha256(N); do
  /bin/rm -f "$old_archive"
done
/usr/bin/git -C "$ROOT" archive --format=zip --prefix="TartR-$VERSION/" -o "$ARCHIVE" "$REF"
(
  cd "$OUTPUT"
  /usr/bin/shasum -a 256 "${ARCHIVE:t}" > "${ARCHIVE:t}.sha256"
  /usr/bin/shasum -a 256 -c "${ARCHIVE:t}.sha256"
)

echo "$ARCHIVE"

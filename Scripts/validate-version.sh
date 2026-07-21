#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PLIST="$ROOT/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
TAG="${1:-v$VERSION}"

if ! print -r -- "$VERSION" | /usr/bin/grep -Eq '^[0-9]{2}\.[0-9]{2}\.[0-9]{2}$'; then
  print -u2 "CFBundleShortVersionString must use YY.MM.DD, for example 26.07.21."
  exit 1
fi

IFS=. read -r YEAR MONTH DAY <<< "$VERSION"
NORMALIZED="$(/bin/date -j -f '%y.%m.%d' "$VERSION" '+%y.%m.%d' 2>/dev/null || true)"
if [[ "$NORMALIZED" != "$VERSION" ]]; then
  print -u2 "Version $VERSION is not a valid calendar date."
  exit 1
fi

EXPECTED_BUILD="20$YEAR.$((10#$MONTH)).$((10#$DAY))"
if [[ "$BUILD" != "$EXPECTED_BUILD" ]]; then
  print -u2 "CFBundleVersion must be $EXPECTED_BUILD for release $VERSION."
  exit 1
fi

if [[ "$TAG" != "v$VERSION" ]]; then
  print -u2 "Release tag must be v$VERSION, received $TAG."
  exit 1
fi

echo "Validated TartR release v$VERSION (build $BUILD)."

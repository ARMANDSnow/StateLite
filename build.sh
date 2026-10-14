#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
BUILD="$ROOT/.build"
SIGNING_IDENTITY=${SIGNING_IDENTITY:--}
VERSION=$(python3 "$ROOT/Tools/release-check.py" --plist "$ROOT/Resources/Info.plist")
if [ -n "${RELEASE_TAG:-}" ]; then
  python3 "$ROOT/Tools/release-check.py" --plist "$ROOT/Resources/Info.plist" --tag "$RELEASE_TAG" >/dev/null
fi
SIGN_FLAGS=(--force --sign "$SIGNING_IDENTITY" --options runtime)
if [ "$SIGNING_IDENTITY" != '-' ]; then SIGN_FLAGS+=(--timestamp); fi
STAGING=$(mktemp -d /private/tmp/statelite-build.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/StateLite.app"
mkdir -p "$BUILD/cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang -target arm64-apple-macos14.0 -O2 -c "$ROOT/Sources/TemperatureBridge.c" -o "$BUILD/TemperatureBridge.o"
clang -target arm64-apple-macos14.0 -O2 -c "$ROOT/Sources/FanBridge.c" -o "$BUILD/FanBridge.o"
swiftc -target arm64-apple-macos14.0 -swift-version 5 -O -module-cache-path "$BUILD/cache" \
  -import-objc-header "$ROOT/Sources/StateLiteBridge.h" \
  "$ROOT/Sources/Metrics.swift" "$ROOT/Sources/Temperature.swift" "$ROOT/Sources/DisplayPreferences.swift" \
  "$ROOT/Sources/Fan.swift" "$ROOT/Sources/UpdateChecker.swift" "$ROOT/Sources/ProxyMonitor.swift" "$ROOT/Sources/PanelComponents.swift" "$ROOT/Sources/PanelViewController.swift" "$ROOT/Sources/main.swift" \
  "$BUILD/TemperatureBridge.o" "$BUILD/FanBridge.o" -framework AppKit -framework IOKit -framework Security -framework SystemConfiguration \
  -o "$APP/Contents/MacOS/StateLite"
cp -X "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -X "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/StateLite"
APP_HASH=$(python3 "$ROOT/Tools/hash-executable.py" "$APP/Contents/MacOS/StateLite")
clang -target arm64-apple-macos14.0 -O2 -Wno-deprecated-declarations \
  -DSL_APP_SHA256=\"$APP_HASH\" "$ROOT/Sources/FanHelper.c" \
  -framework IOKit -framework Security -framework CoreFoundation -lbsm -o "$APP/Contents/MacOS/FanHelper"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/FanHelper"
codesign "${SIGN_FLAGS[@]}" "$APP"
SIGNED_HASH=$(python3 "$ROOT/Tools/hash-executable.py" "$APP/Contents/MacOS/StateLite")
if [ "$APP_HASH" != "$SIGNED_HASH" ]; then
  echo 'Main executable changed during bundle signing; helper identity would be invalid.' >&2
  exit 1
fi
codesign --verify --strict "$APP"
if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  if [ "$SIGNING_IDENTITY" = '-' ]; then echo 'Notarization requires Developer ID signing.' >&2; exit 1; fi
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$STAGING/notarize.zip"
  NOTARY_FLAGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  if [ -n "${NOTARY_KEYCHAIN:-}" ]; then NOTARY_FLAGS+=(--keychain "$NOTARY_KEYCHAIN"); fi
  xcrun notarytool submit "$STAGING/notarize.zip" "${NOTARY_FLAGS[@]}" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi
if [ -n "${RELEASE_OUTPUT_DIR:-}" ]; then
  mkdir -p "$RELEASE_OUTPUT_DIR"
  OUTPUT=$(cd "$RELEASE_OUTPUT_DIR" && pwd)
  ZIP="$OUTPUT/StateLite-v$VERSION-macos-arm64.zip"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
  python3 "$ROOT/Tools/release-check.py" --plist "$ROOT/Resources/Info.plist" \
    --app "$APP" --zip "$ZIP" --metadata "$OUTPUT/release-metadata.json" --checksums "$OUTPUT/SHA256SUMS"
  printf 'Release: %s (signing identity: %s)\n' "$ZIP" "$SIGNING_IDENTITY"
else
  ditto --norsrc --noextattr "$APP" "$ROOT/StateLite.app"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ROOT/StateLite.zip"
  printf 'Built: %s\n' "$ROOT/StateLite.app"
fi

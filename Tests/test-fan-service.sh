#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMP=$(mktemp -d /private/tmp/statelite-service-build.XXXXXX)
trap 'rm -rf "$TEMP"' EXIT
clang -target arm64-apple-macos14.0 -Wno-deprecated-declarations -Wall -Wextra \
  "$ROOT/Tests/FanServiceTests.c" -framework IOKit -framework Security -framework CoreFoundation -lbsm -o "$TEMP/service-tests"
cp "$TEMP/service-tests" "$TEMP/unhardened-tests"
codesign --force --sign - "$TEMP/unhardened-tests"
"$TEMP/unhardened-tests" --expect-rejected
cp "$TEMP/service-tests" "$TEMP/exception-tests"
cat > "$TEMP/unsafe-entitlements.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --options runtime --entitlements "$TEMP/unsafe-entitlements.plist" "$TEMP/exception-tests"
"$TEMP/exception-tests" --expect-rejected
codesign --force --sign - --options runtime "$TEMP/service-tests"
"$TEMP/service-tests"

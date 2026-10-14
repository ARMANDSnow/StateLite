#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
BUILD="$ROOT/.build"
mkdir -p "$ROOT/.build/cache"
swiftc -warnings-as-errors -module-cache-path "$ROOT/.build/cache" \
  "$ROOT/Sources/Metrics.swift" "$ROOT/Tests/MetricsTests.swift" \
  -o "$ROOT/.build/metrics-tests"
"$ROOT/.build/metrics-tests"
swiftc -warnings-as-errors -module-cache-path "$ROOT/.build/cache" \
  "$ROOT/Sources/DisplayPreferences.swift" "$ROOT/Tests/DisplayPreferencesTests.swift" \
  -o "$ROOT/.build/preferences-tests"
"$ROOT/.build/preferences-tests"
swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$ROOT/.build/cache" \
  "$ROOT/Sources/ProxyMonitor.swift" "$ROOT/Tests/ProxyMonitorTests.swift" \
  -o "$ROOT/.build/proxy-tests"
"$ROOT/.build/proxy-tests"
clang -Wno-deprecated-declarations "$ROOT/Tests/FanHelperTests.c" -framework IOKit -framework Security -framework CoreFoundation -lbsm -o "$BUILD/fan-helper-tests"
"$BUILD/fan-helper-tests"
bash "$ROOT/Tests/test-fan-service.sh"
clang -c "$ROOT/Sources/FanBridge.c" -o "$BUILD/FanBridgeTests.o"
swiftc -D SL_FAN_TESTING -module-cache-path "$BUILD/cache" \
  -import-objc-header "$ROOT/Sources/FanBridge.h" "$ROOT/Sources/Fan.swift" \
  "$ROOT/Tests/FanControllerTests.swift" "$BUILD/FanBridgeTests.o" \
  -framework IOKit -framework Security -o "$BUILD/fan-controller-tests"
"$BUILD/fan-controller-tests"
clang -O2 -Wall -Wextra -Werror "$ROOT/Tools/process-meter.c" -o "$ROOT/.build/process-meter"

swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$BUILD/cache" \
  "$ROOT/Sources/UpdateChecker.swift" "$ROOT/Tests/UpdateCheckerTests.swift" -o "$BUILD/update-tests"
"$BUILD/update-tests"
python3 -m unittest discover -s "$ROOT/Tests" -p 'test_release*.py'

#!/usr/bin/env bash
# Drives the demo app's conformance mode (ConformanceRunner.swift) on a
# real iOS Simulator: builds for iphonesimulator, installs, launches with
# -GossConformance, and checks the reported result. Mirrors demo/prove.ts's
# role for the web SDK - a real SDK driving the real ABI end to end,
# just captured over simctl's console instead of the DevTools protocol.
#
# Simulator output is a dev signal only, per this project's own MATRIX
# rule (emulator/simulator output never counts as proof) - this script
# exists to catch a real regression early, not to claim device proof.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

DEVICE_NAME="${GOSS_SIM_DEVICE:-iPhone 17 Pro}"
BUNDLE_ID="com.gosslens.demo"
DERIVED_DATA="/tmp/gossdemo-sim-prove"

echo "prove-simulator: building gosslens for the iOS Simulator"
(
  cd ../../..
  zig build ios-simulator -Dios-simulator-sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
)

echo "prove-simulator: generating the Xcode project"
xcodegen generate >/dev/null

# Pinned to the exact SDK version zig build ios-simulator just linked
# against, not OS=latest - when more than one simulator runtime is
# installed, "latest" is not reliably the highest version number, and a
# runtime older than the build SDK is a real, previously-hit failure
# mode here (a libc++ symbol the build SDK assumes but an older
# runtime's dylib does not export), not just a slower path.
SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
DESTINATION="platform=iOS Simulator,name=${DEVICE_NAME},OS=${SDK_VERSION}"

echo "prove-simulator: building the demo app (destination: ${DESTINATION})"
xcodebuild -project GosslensDemo.xcodeproj -scheme GosslensDemo -sdk iphonesimulator \
  -destination "${DESTINATION}" -derivedDataPath "${DERIVED_DATA}" build

APP_PATH="${DERIVED_DATA}/Build/Products/Debug-iphonesimulator/GosslensDemo.app"
# Matched to SDK_VERSION, not just device name - the same device name
# can exist under more than one installed runtime, and only the one
# matching the build SDK avoids the libc++ mismatch above.
RUNTIME_TAG="iOS-${SDK_VERSION//./-}"
DEVICE_ID=$(xcrun simctl list devices available -j |
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data['devices'].items():
    if '${RUNTIME_TAG}' not in runtime:
        continue
    for d in devices:
        if d['name'] == '${DEVICE_NAME}':
            print(d['udid'])
            sys.exit(0)
sys.exit(1)
")

echo "prove-simulator: device ${DEVICE_ID}"
xcrun simctl bootstatus "${DEVICE_ID}" -b >/dev/null 2>&1 || xcrun simctl boot "${DEVICE_ID}"
xcrun simctl install "${DEVICE_ID}" "${APP_PATH}"

echo "prove-simulator: launching in conformance mode"
OUTPUT=$(timeout 60 xcrun simctl launch --console-pty --terminate-running-process "${DEVICE_ID}" "${BUNDLE_ID}" -GossConformance 2>&1 || true)
echo "${OUTPUT}"

if echo "${OUTPUT}" | grep -q "GOSSCONFORMANCE PROOF"; then
  echo "prove-simulator: PROOF (dev signal, simulator only - never device proof)"
  exit 0
fi
echo "prove-simulator: FAIL - no proof line found"
exit 1

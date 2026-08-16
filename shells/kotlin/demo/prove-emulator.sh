#!/usr/bin/env bash
# Drives the demo app's conformance mode (ConformanceRunner.kt) on a
# running Android emulator: builds the debug apk, installs, launches
# with the CKConformance intent extra, and checks the reported result
# over logcat. Mirrors prove-simulator.sh's role for the ios shell -
# a real shell driving the real ABI end to end, just captured over adb
# instead of simctl's console.
#
# Emulator output is a dev signal only, per this project's own MATRIX
# rule (emulator/simulator output never counts as proof) - this script
# exists to catch a real regression early, not to claim device proof.
# Expects a booted emulator already reachable via adb (this script does
# not manage AVD lifecycle - `emulator -avd <name>` first).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ANDROID_SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="${ANDROID_SDK}/platform-tools:${PATH}"
PACKAGE="kit.camera.demo"
ACTIVITY="kit.camera.demo.MainActivity"

if ! adb get-state >/dev/null 2>&1; then
  echo "prove-emulator: no adb device reachable - boot an emulator first (emulator -avd <name>)"
  exit 1
fi

echo "prove-emulator: building camerakit for android"
(cd ../.. && zig build android)

echo "prove-emulator: building and installing the demo app"
./gradlew :demo:installDebug

echo "prove-emulator: clearing logcat and launching in conformance mode"
adb logcat -c
adb shell am force-stop "${PACKAGE}"
adb shell am start -n "${PACKAGE}/${ACTIVITY}" --ez CKConformance true

echo "prove-emulator: waiting for the conformance result"
RESULT=""
for _ in $(seq 1 60); do
  LINE=$(adb logcat -d -s CKCONFORMANCE:V 2>/dev/null | grep -E "PROOF|FAIL" || true)
  if [ -n "${LINE}" ]; then
    RESULT="${LINE}"
    break
  fi
  sleep 2
done

adb shell am force-stop "${PACKAGE}"

if [ -z "${RESULT}" ]; then
  echo "prove-emulator: FAIL - no result reported within the timeout"
  adb logcat -d -s CKCONFORMANCE:V 2>/dev/null || true
  exit 1
fi

echo "${RESULT}"
if echo "${RESULT}" | grep -q "PROOF"; then
  echo "prove-emulator: PROOF (dev signal, emulator only - never device proof)"
  exit 0
fi
echo "prove-emulator: FAIL"
exit 1

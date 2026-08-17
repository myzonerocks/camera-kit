# Android demo

An Activity with a live camera preview through the real ABI - CameraX
capture, zero-copy into a GLES-backed renderer via AHardwareBuffer.

## Run it

Boot an emulator or connect a device first (`emulator -avd <name>`,
or plug in a device with USB debugging on). This machine runs close to
full disk and has 8GB RAM - check headroom before booting an emulator.

From the repo root:

    zig build android
    cd shells/kotlin
    ./gradlew :demo:installDebug
    adb shell am start -n kit.camera.demo/kit.camera.demo.MainActivity

Grant camera permission when the app asks.

## Proving it

    ./demo/prove-emulator.sh

Builds, installs, and launches the app in conformance mode against
whatever emulator/device adb already sees, driving the same ABI path
the live preview runs. Emulator output is a dev signal only, never
proof of on-device behavior - the emulator's own GLES support is real
but not every device's.

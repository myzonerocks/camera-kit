# iOS demo

A SwiftUI/UIKit app with a live camera preview through the real ABI -
AVFoundation capture, zero-copy into a Metal-backed renderer.

## Run on a device

From the repo root:

    zig build ios -Dios-sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
    cd sdk/swift/demo
    xcodegen generate
    open GosslensDemo.xcodeproj

Pick your connected iPhone as the run destination and hit Run. Signing
is automatic (team 9ZCMLRAW4V) once your Apple ID is added under Xcode
Settings > Accounts - a free personal team is enough for a dev install.

## Run in the Simulator

Same as above with `ios-simulator` instead of `ios`:

    zig build ios-simulator -Dios-simulator-sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    cd sdk/swift/demo
    xcodegen generate
    open GosslensDemo.xcodeproj

The Simulator has no real camera and no GLES-backed beauty context, so
this proves capture plumbing and tracking, not beauty effects - a
known Simulator limitation, not a bug (bgfx/tracking/lens activation
all report success; beauty correctly reports unsupported). The
Simulator's own synthetic camera feed can also die mid-session
(`FigCaptureSourceSimulator`/`FigCaptureSessionSimulator` errors,
capture state flips to failed after rendering fine for a while) -
also a Simulator-side limitation, not a regression. Simulator output
is a dev signal only, never proof of on-device behavior.

## Proving it

    ./prove-simulator.sh

Builds, installs, and launches the app in conformance mode on a real
Simulator, driving the same ABI path the live preview runs.

# MBSync — iOS companion app

Pairs with the macOS **Monitor Brightness Sync** app over LAN/TLS-PSK. Scans a QR code from the Mac, locks the camera's white balance and exposure, photographs each display's patch card, and sends the samples back so the Mac can compute a per-display white-point correction.

## Prerequisites

- **Xcode 16+** (the project targets Xcode 26.5 features; building from the command line requires the matching SDK)
- **xcodegen** — `brew install xcodegen`
- The `MBSync.xcodeproj` is git-ignored; you generate it locally (below)

## Generate project and open in Xcode

```sh
cd ios
xcodegen generate
open MBSync.xcodeproj
```

Re-run `xcodegen generate` any time `project.yml` changes (e.g. after a pull).

## Signing

1. Select the **MBSync** target → **Signing & Capabilities**.
2. Set your **Team**. The generated project uses bundle id `com.rick.mbsync`; rename it to one under your team if needed.
3. A **free personal Apple ID** is sufficient for running on your own device (7-day re-sign cycle). A **paid Apple Developer account** is required for TestFlight distribution.

## Run on device

Select your iPhone as the destination and hit **Run** (⌘R). On first launch, accept the two permission prompts — **Camera** (for the patch card photos) and **Local Network** (for the TLS-PSK connection to the Mac).

## Compile-only check (no device, no signing)

Useful in CI or to verify the build after pulling shared sources:

```sh
cd ios
xcodegen generate
xcodebuild \
  -project MBSync.xcodeproj \
  -scheme MBSync \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  build \
  CODE_SIGNING_ALLOWED=NO
```

## Distribute via TestFlight

1. In Xcode: **Product → Archive**.
2. In the Organizer: **Distribute App → App Store Connect → TestFlight**.
3. Requires a paid Apple Developer account and an **App Store Connect app record** whose bundle id matches the one you set in Signing above.

## Device bring-up checklist

- [ ] Mac and iPhone on the **same Wi-Fi network**. Guest networks and networks with AP/client isolation will block the peer-to-peer TLS connection — use a private network with isolation off.
- [ ] On the Mac: open Monitor Brightness Sync → **Settings → Color Sync (beta)** to display the pairing QR code.
- [ ] Open MBSync on the iPhone and tap **Scan QR**. Point the camera at the Mac's QR.
- [ ] If the connection fails after scanning, the most likely mismatch is the PSK derivation: both sides take the UTF-8 bytes of the percent-decoded base64 PSK string and use TLS-PSK identity `"colorsync"`. Verify both sides are on the same build if you suspect a mismatch.
- [ ] **Lock step:** with the connection established, aim the iPhone at the reference display showing a mid-gray patch card and tap **Lock & Start**. This locks white balance and exposure.
- [ ] Aim at each display's patch card in turn. The app auto-captures when the frame is steady; tap **Capture manually** if you prefer.
- [ ] After all displays are sampled, the Mac applies the corrections automatically. Use the **before/after toggle** and warm/cool sliders in the Mac's Color Sync panel to verify.

## Architecture note

The iOS target does **not** have a separate Swift package. It compiles the following shared, Cocoa-free Swift files directly from `../Sources/SyncBrightness/` (declared in `project.yml`):

- `ColorCorrection` — white-point math
- `ColorSyncMessages` — wire protocol types
- `PatchCardLayout` — patch card geometry
- `PatchCardAnalyzer` — frame analysis
- `PairingPayload` — QR payload encoding/decoding
- `FrameCodec` — message framing
- `CaptureGate` — steady-frame gating

The iOS-specific code lives in `ios/Sources/` (SwiftUI views, `CameraController`, `ColorSyncClient`, `SessionCoordinator`).

## Known device risks

These only manifest on a real device (the camera doesn't run in the simulator), so verify them during device bring-up:

- **Confirm white balance lock actually engages.** `CameraController.lock()` prefers `.locked` WB mode; if your iPhone's camera doesn't support locked WB it falls back to pinning the current custom device gains (`setWhiteBalanceModeLocked(with:)`). Either way, verify colors stop drifting between displays after **Lock & Start** — if the patches shift hue as you pan between displays, the lock isn't holding.
- **Hold the phone upright (portrait) when capturing.** The video connection is pinned to portrait, and the patch-card analyzer expects a roughly portrait, axis-aligned framing (its white-fiducial quadrant assumption depends on it). Tilted or landscape framing can cause the analyzer to miss the card.

# MBSync — iOS companion app

The phone half of **Monitor Brightness Sync**'s "Color Sync" feature. It pairs with
the macOS app over the LAN (TLS-PSK), locks the camera, and measures a fullscreen
gray field on each display so the Mac can compute a per-display **white-point**
correction (and, optionally, a gamma correction). Think Apple TV's color balance,
adapted to the back camera.

You need **both** halves running on the same machine/LAN: the macOS menu-bar app
(the "server" that drives the displays and shows the QR) and this iOS app (the
camera client).

---

## 1. Prerequisites

- **macOS on Apple Silicon**, macOS 13+ (for the desktop app).
- **Xcode 16+** with the iOS SDK (this was built against Xcode 26.5 / iOS 26.5).
- **xcodegen** — `brew install xcodegen` (the iOS `.xcodeproj` is generated, not committed).
- An **Apple ID** for signing. A free personal team runs it on your own iPhone
  (7-day re-sign cycle); a **paid Apple Developer account** is only needed for TestFlight.
- An **iPhone** (the camera doesn't exist in the Simulator — device required to actually use it).

---

## 2. Build & run the macOS app (the "server")

From the repo root:

```sh
./build.sh
open "build/Monitor Brightness Sync.app"
```

It launches as a **menu-bar agent** (no Dock icon — look in the menu bar). `build.sh`
needs only the Command Line Tools; full Xcode is not required for this half. See the
top-level `README.md` and `CLAUDE.md` for more on the desktop app.

> Build **both** halves from the **same checkout**. The two apps share source files
> (wire protocol, PSK derivation, measurement math), so same-checkout builds are
> guaranteed compatible. Mismatched builds can fail to pair.

---

## 3. Generate the iOS project & open it

```sh
cd ios
xcodegen generate
open MBSync.xcodeproj
```

Re-run `xcodegen generate` any time `project.yml` changes (e.g. after a `git pull`).
The generated `MBSync.xcodeproj/` is git-ignored.

---

## 4. Signing

1. In Xcode: select the **MBSync** target → **Signing & Capabilities**.
2. Check **Automatically manage signing** and pick your **Team** (your Apple ID).
3. Bundle id defaults to **`com.rick.mbsync`**. If it's unavailable under your account
   (or you're not on the `rick` team), change `PRODUCT_BUNDLE_IDENTIFIER` in
   `ios/project.yml` to something under your team, then re-run `xcodegen generate`.

---

## 5. Run on your iPhone

1. Plug in the iPhone, select it as the run destination, **⌘R**.
2. First run: if the phone says "Untrusted Developer," go to **Settings → General →
   VPN & Device Management → [your Apple ID] → Trust**, then ⌘R again.
3. On launch, **allow** the two prompts: **Camera** and **Local Network**.

### Compile-only check (no device / no signing)

```sh
cd ios && xcodegen generate
xcodebuild -project MBSync.xcodeproj -scheme MBSync \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

---

## 6. Using it end-to-end

1. **Same Wi-Fi.** Put the Mac and iPhone on the same network with **no AP/client
   isolation** (guest networks usually block peer-to-peer traffic).
2. **Mac:** menu bar → **Open Settings… → General → "Color Sync (beta)…"** → a QR appears.
   (Opening this also pins every display to **50% brightness** so they're measured at
   the same operating point; it restores your brightness when the window closes.)
3. **iPhone:** open MBSync, scan the QR. (You can also scan the Mac's QR with the system
   Camera app — the `mbsync://` URL scheme will offer to open MBSync.)
4. **Lock:** the Mac shows gray on the reference display. **Press the camera flat against
   that screen** and tap **Lock & Start** — this locks white balance/exposure so all
   measurements share one camera transform.
5. **Each display, one tap:** the Mac says "press the camera to <display>." Press the
   camera flat against that screen, tap **Capture this screen** once, and **hold it
   there** — the Mac auto-cycles a dark→25%→50%→80% gray ramp while the phone measures.
   Then move to the next display and repeat.
6. **Done.** The Mac applies the correction and shows a per-display readout.

### Settings → General (Mac)

- **Apply color sync correction** — live on/off toggle (instant A/B of the saved correction).
- **Match gamma (experimental)** — **off by default.** Gamma matching can wash out
  mid-tones; white-point matching is the dependable part. Toggle on to experiment.
- **Reset color sync** — clears the saved correction.
- **Toggle test field (all displays)** — fills every display with a gray A/B field
  (dismiss by clicking it or pressing **Esc**).

### Side-by-side verify (debug)

After a session reaches **Done**, tap **"Verify side-by-side"** on the phone (or the
"Side-by-side check (debug)" button on the pairing screen). The Mac shows an **A/B**
field on every display; **photograph both screens in one frame**, then **tap each
screen** in the photo. The two RGBs go to the Mac, which prints a **chroma** verdict
in the Color Sync window (`color matched ✓` / `close` / `still off`) plus the
brightness difference (brightness is the brightness-sync feature's job, not color).
Because it's a single frame, the camera transform is identical for both screens, so
the comparison is ground truth. Exit the check with the **✕** (top-right) or **Esc**.

---

## 7. Distribute via TestFlight (optional)

1. Xcode: **Product → Archive**.
2. Organizer: **Distribute App → App Store Connect → TestFlight**.
3. Requires a paid Apple Developer account and an App Store Connect app record whose
   bundle id matches your signing bundle id.

---

## 8. Architecture note

The iOS target has **no separate Swift package**. It compiles these shared, Cocoa-free
files directly from `../Sources/SyncBrightness/` (listed in `project.yml`):

- `ColorCorrection` — value types (`RGB`, `PatchSamples`, `ColorCorrection`)
- `ColorSyncMessages` — wire protocol (`MacToPhone` / `PhoneToMac`)
- `PairingPayload` — QR `mbsync://` URL encode/decode
- `FrameCodec` — length-prefixed JSON framing (matches the Mac transport)
- `FieldSampler` — fullscreen-field + point sampling (the active measurement path)
- `CaptureGate` — steady-frame gating (legacy auto-capture helper)
- `PatchCardLayout`, `PatchCardAnalyzer` — legacy fiducial-card analysis (compiled but
  no longer used; the current flow uses `FieldSampler`)

iOS-specific code is in `ios/Sources/`: `MBSyncApp`, `PairingView`, `QRScannerView`,
`CameraController`, `CameraPreviewView`, `ColorSyncClient` (NWConnection TLS-PSK),
`SessionCoordinator`, `CaptureView`, `DoneView`, `SideBySideView`.

---

## 9. Device gotchas (only show up on real hardware)

- **Confirm the WB lock engages.** `CameraController.lock()` prefers `.locked` WB; if
  unsupported it pins the current custom device gains. After **Lock & Start**, colors
  shouldn't drift as you move between displays. (The side-by-side check doesn't need the
  lock — it's a single frame — and re-enables autofocus for a sharp image to tap.)
- **Press the camera flat to the screen.** Focus is irrelevant for measuring a uniform
  field's average color, so a defocused flush shot is fine — and it kills glare and keeps
  the distance constant.
- **Same Wi-Fi, isolation off.** If pairing fails right after scanning, this is the usual
  cause. The PSK is the UTF-8 bytes of the percent-decoded base64 string from the QR,
  with TLS-PSK identity `"colorsync"` — both sides match by sharing source, so build both
  from the same checkout.

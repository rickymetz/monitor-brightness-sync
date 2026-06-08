# Native Color Sync — Design (revised)

**Date:** 2026-06-08
**Status:** Approved (brainstorm) — ready for implementation planning
**Supersedes:** `2026-06-08-phone-camera-color-sync-design.md` (web-based approach — abandoned; see "Why the web approach was abandoned").

**Feature:** Match colors across displays using an iPhone camera, Apple-TV-style. A native iOS companion app captures each display with **locked white balance + exposure**; the macOS app coordinates the session, computes a per-display color correction, and applies it via the gamma table.

---

## 1. Why the web approach was abandoned

The original plan served a web page to the phone and photographed each display one at a time. During implementation we proved this **cannot work** for the user-visible goal:

A photographed patch = `cameraGain ⊗ displayEmits(patch)`, where `cameraGain` (the phone's auto white-balance/exposure) is an unknown per-channel multiplier. Within one photo, gray÷white ratios cancel `cameraGain` but recover only the per-channel **gamma shape** — *not* the white point. Across two photos the camera gains differ, so comparing whites gives `(camGain_B/camGain_A) × (displayWhite_B/displayWhite_A)` — the camera ratio permanently contaminates the display ratio. **White point — the thing users actually notice ("this screen is bluer") — is mathematically unrecoverable when each photo has a different, uncontrolled camera gain.** iOS Safari ignores the `getUserMedia` constraints that would lock the camera, so the web route can't escape this.

**The fix is a native app.** `AVCaptureDevice` can lock white balance and exposure, so the camera transform `G` is **constant across every shot**. Then comparing displays cancels `G` directly (not via within-photo ratios): `measured_ref,c / measured_target,c = emit_ref,c / emit_target,c`. White point becomes recoverable. This is exactly how Apple TV's color balance works — a native app with a controlled camera.

---

## 2. Goal & scope

Make all connected displays **look like each other** (relative matching), with the built-in display as the reference when present. Per-channel **white-point** matching is now the reliable core (it was impossible before). Brightness stays owned by the existing brightness-sync feature; color sync corrects **chroma only** (attenuate-only, peak channel normalized to 1) so the two don't fight.

**Decisions locked during brainstorm:**

| Decision | Choice |
|---|---|
| Approach | Native iOS companion app with locked WB/exposure (not a web page) |
| Capture model | One screen at a time, lock-once-then-shoot |
| Distribution | iOS app via **TestFlight** (paid Apple Developer account, owner-provided) |
| Repo structure | macOS app unchanged (SwiftPM + `build.sh`); new iOS Xcode project under `ios/`; shared pure code in a `ColorSyncCore` SwiftPM package |
| Transport | QR pairing + `Network.framework` TLS-PSK over the LAN |
| Analysis location | On iOS (shared `PatchCardAnalyzer`); only `PatchSamples` JSON crosses the wire |
| Matching | Direct cross-photo per-channel white ratios; v1 = white-point gains (gamma=1) |

Note: the paid developer account also lets the **macOS** app be Developer ID–signed + notarized later, which would fix the TCC/Accessibility-grant-persistence issue described in the README. Out of scope for this feature; noted as a follow-up.

---

## 3. Architecture & components

Three components, with the pure logic shared:

### 3a. `ColorSyncCore` (new SwiftPM package, platform-agnostic, pure)
Depended on by both apps; unit-tested in isolation via the project's framework-free harness.
- `ColorCorrection`, `RGB`, `PatchSamples` — **reused from Task 1 (already built)**, moved into the package.
- `PatchCardLayout` — the canonical patch/fiducial geometry, shared so the macOS renderer and the iOS analyzer agree.
- `PatchCardAnalyzer` — photo (CGImage) → `PatchSamples` (corner-fiducial detection + sampling). Runs on iOS.
- `ColorMatcher` — `[DisplayMeasurement]` + referenceID → `[String: ColorCorrection]`, **locked-camera direct-ratio model** (rewritten; replaces the reverted web-era matcher).

### 3b. macOS app (existing SwiftPM app + `build.sh`)
- `DisplayColorState` — **reused from Task 2 (already built)**; composes color correction + dim factor into one gamma write.
- `PatchCardWindow` — fullscreen patch card on a chosen display (uses `PatchCardLayout`).
- `ColorSyncCoordinator` — `NWListener` (TLS-PSK), QR generation, the session state machine driving capture per display, receiving `PatchSamples`.
- `ColorSyncWindowController` — the Mac UI: QR to pair, live status, before/after toggle, per-display warm↔cool / brightness sliders, Save.
- Persistence: `[String: ColorCorrection]` in `UserDefaults` keyed by `ExternalDisplay.id`, applied via `SyncController` on its serial queue (and re-applied on wake/reconnect), mirroring brightness profiles.
- Entry point: a "Color Sync (beta)" button in `ControlWindowController`.

### 3c. iOS app (new Xcode project under `ios/`, SwiftUI + AVFoundation)
Deliberately thin — most logic is in `ColorSyncCore`.
- **Pair** screen: QR scanner (AVFoundation metadata).
- **Capture** screen: live preview, alignment/steady overlay, Mac-pushed instruction, auto-capture on stable card detection, progress. Locks WB/exposure once; runs the shared analyzer on-device; sends `PatchSamples`.
- **Done** screen.

### Threading / integration invariants
All gamma/correction mutations go through `SyncController`'s serial queue (project invariant). Network callbacks marshal to main. The coordinator's session logic is independent of the socket so it can be driven by a simulated in-process peer in tests.

---

## 4. Transport & pairing

- Mac runs an `NWListener` secured with a **pre-shared key**. It displays a **QR** encoding `{host, port, psk}` (via `CIQRCodeGenerator`).
- iOS scans the QR, opens an `NWConnection` with **TLS-PSK** — authenticated, encrypted, and addressed to the right Mac. Both ends must be on the same Wi-Fi/LAN (no client/AP isolation).
- Wire format: **length-prefixed JSON frames**, bidirectional. The Mac is the coordinator; iOS is a driven client.
- Server is **session-scoped**: starts when the Color Sync window opens, stops on finish/cancel/close.

### Message types (illustrative)
- Mac→iOS: `prepareLock` (reference display showing mid-gray), `capture {displayID, label}`, `done`, `retake {hint}`.
- iOS→Mac: `paired`, `locked`, `samples {displayID, PatchSamples}`, `error {reason}`.

---

## 5. Capture protocol (lock-then-shoot)

1. **Pair** via QR; connection opens.
2. **Lock:** Mac shows a neutral **mid-gray** fullscreen on the reference display (built-in when present). iOS shows live preview + alignment overlay; when the user is aimed and steady, it **locks WB + exposure** on that mid-gray (mid-gray so the brightest display's white won't clip) and replies `locked`. `G` is frozen for the session.
3. **Per display** (reference first): Mac shows the **patch card** fullscreen on display *d* and sends `capture {d}`. iOS auto-detects the card, captures with locked settings, runs `PatchCardAnalyzer` → `PatchSamples`, replies `samples {d, …}`. No card / glare → `error`; Mac re-issues `capture {d}` with a `retake` hint.
4. **Compute & apply:** after the last display, the Mac runs `ColorMatcher`, applies corrections live via `DisplayColorState`, and shows before/after + per-display fine-tune sliders. **Save** persists.
5. **Teardown:** connection closes; patch windows hidden.

---

## 6. `ColorMatcher` algorithm (locked-camera)

Given `PatchSamples` per display (all under the same frozen `G`) and a reference id:

- For each non-reference display *t*, per channel `c ∈ {r,g,b}`:
  `gain_c = measured_white_ref,c / measured_white_t,c` (the constant `G_c` cancels).
- **Normalize attenuate-only:** divide the three gains so the peak = 1 (gamma-table output can't exceed native; this corrects chroma while preserving level, leaving brightness to the brightness-sync feature).
- Reference → `.identity`.
- v1 keeps `gamma = 1`. (Optional future: refine per-channel gamma from the gray ramp white/gray50/gray25.)

### Tests (pure, framework-free)
- Synthetic displays with known emitted whites; apply **one shared constant** `G` to all → assert the matcher equalizes white points and reference → identity.
- A **warm** target (red-hot white) → blue gain > red gain (attenuates the warm cast).
- Re-run with a **different but still constant** `G` → identical corrections (proves `G` cancels).
- Gains normalized so the peak channel == 1.

---

## 7. Patch card & analyzer

- `PatchCardLayout`: a grid of patches — 100% white, 50% gray, 25% gray, 100% R, 100% G, 100% B — with four distinctly-marked corner fiducials. Single source of truth in `ColorSyncCore` so the macOS renderer and iOS analyzer agree on geometry.
- `PatchCardWindow` (macOS) renders it fullscreen on the target display.
- `PatchCardAnalyzer` (iOS, shared): locate the four fiducials → map the quad → sample each patch cell's **median** (rejects glare). Returns `PatchSamples`, or nil if the card can't be located (→ retake).

---

## 8. Persistence, lifecycle, security, caveats

- **Persistence:** per-display correction (3 gains + gamma + manual nudge) in `UserDefaults`, keyed by `ExternalDisplay.id`. Re-applied on launch/wake/reconnect, like brightness profiles. Per-display "reset color" + global "reset all".
- **Lifecycle:** coordinator/listener runs only while the Color Sync window is open.
- **Security:** TLS-PSK; the PSK is random per session and only present in the QR. Connection is encrypted and authenticated. `PatchSamples` are tiny and processed in memory.
- **Caveats:** same Wi-Fi/LAN, no client/AP isolation; lighting must not change mid-session (locked exposure); color correction composes with sub-floor dimming and the non-DDC gamma-follow via the single per-display gamma write; the iOS app uses only the camera (no private APIs).

---

## 9. Testing & distribution

- **Without hardware:** `ColorSyncCore` (matcher, analyzer) via the framework-free harness (`run-tests.sh`); the macOS coordinator via a **simulated in-process peer** feeding `PatchSamples` — exercises the full session state machine, matching, applying, and persistence with no phone.
- **With hardware:** a brief on-device smoke test of the iOS capture (lock, detect, send). The iOS app is thin, so little logic is device-only.
- **Distribution:** iOS via TestFlight (signing in the `ios/` Xcode project, bundle ID under the team). macOS app build unchanged.

---

## 10. What carries over vs. changes

- **Reused as-is:** `ColorCorrection`/`RGB`/`PatchSamples` (Task 1), `DisplayColorState` (Task 2). These move/stay and are depended upon.
- **Rewritten:** `ColorMatcher` (locked-camera direct ratios; the web-era version was reverted).
- **New:** `ColorSyncCore` package, `PatchCardAnalyzer`, `PatchCardLayout`, `PatchCardWindow`, `ColorSyncCoordinator`, `ColorSyncWindowController` (macOS), the entire iOS app, the `ios/` Xcode project + TestFlight signing.
- **Dropped:** web server, served HTML page, `<input capture>` upload, HTTPS/cert considerations.

---

## 11. Out of scope (v1)

- Per-channel gamma-curve matching (only white-point gains in v1).
- Absolute calibration to a standard (6500K/sRGB) or hardware-colorimeter support.
- Developer ID signing/notarization of the macOS app (separate follow-up the account enables).
- Public App Store listing (TestFlight only).

---

## 12. Future enhancements

- Gamma-curve matching from the gray ramp.
- Peer-to-peer transport fallback (`Network.framework` `includePeerToPeer`) when not on shared Wi-Fi.
- Re-sign + notarize the macOS app to drop the local-identity TCC hack.

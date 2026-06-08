# Phone-Camera Color Sync — Design

**Date:** 2026-06-08
**Status:** Approved (brainstorm) — ready for implementation planning
**Feature:** Calibrate color across multiple displays using the phone's camera,
Apple-TV-style: the app spins up a local web server, shows a QR code, and the
phone photographs each display so the app can match their colors.

---

## 1. Goal & scope

Make all connected displays **look like each other** (relative matching), using
the built-in display as the reference when it is present. This is *not* absolute
calibration to a standard (e.g. 6500K/sRGB) — that is not achievable over a phone
web page and is explicitly out of scope.

The correction mechanism already exists in the app: per-channel R/G/B gamma via
`CGSetDisplayTransferByFormula` (see `GammaDimmer.swift`), which works on any
display, built-in or external, independent of DDC. The new work is **measurement**
(phone camera) and **deriving + composing** the correction.

### What v1 delivers (and the honest limits)

- ✅ **Per-channel response & gamma matching.** Within a single photo, the ratio
  of each color patch to white is *intrinsic to the display* — the camera's
  unknown gain/white-balance transform cancels out. Matching these ratios across
  displays is the reliable core.
- ✅ **Luminance / contrast matching** across displays.
- ⚠️ **White-point (warm/cool) matching is best-effort.** The phone's auto white
  balance actively neutralizes the white it sees — i.e. it eats the very cast we
  want to measure. We recover whatever residual signal survives and apply it
  *damped*. Accept that residual error survives (inherent to one-at-a-time
  capture; only side-by-side capture removes it, which was rejected for
  ergonomics).
- 🛟 **Manual fine-tune safety net.** After the automatic pass, the user nudges
  each display with warm↔cool + brightness sliders, eyeballed against the
  reference. Camera gets ~80%; the eye closes the gap.

### Decisions locked during brainstorm

| Decision | Choice | Why |
|---|---|---|
| Calibration goal | Relative matching (screens match each other) | Achievable over a web page; absolute is not |
| Capture model | One screen at a time (Apple-TV-like) | Familiar, comfortable; accepted residual error |
| Auto-WB defense | Many color patches in one frame; measure ratios *within* the frame | Camera gain cancels in within-frame ratios |
| Camera method | Native camera via `<input capture>` over plain http | No HTTPS, no cert install; sharper stills |
| Serving model | **http v1 now, HTTPS live-preview later** | Validate the pipeline cheaply first |

### Why not HTTPS / live preview in v1

iOS Safari only grants `getUserMedia` (live camera) on a **secure context** —
`https://` with a *trusted* cert, or `localhost`. A LAN `http://192.168.x.x` page
is blocked from the live camera. Merely tapping through a self-signed cert warning
lets you *view* the page but does **not** unlock the camera. Real HTTPS over LAN
therefore requires a one-time CA-profile install + trust-enable on each phone
(~6 taps, scary prompt). Deferred. The `<input type="file" accept="image/*"
capture="environment">` route launches the native Camera app and returns a still
photo with **no secure-context requirement**, so v1 uses that over plain http.

---

## 2. Architecture & components

All system frameworks — **no new third-party dependencies** (matches the
project's zero-dep, hand-rolled ethos, including the framework-free test harness).

| Component | Role | Framework |
|---|---|---|
| `CalibrationServer` | Tiny HTTP server. Runs **only** during a session, token-gated, bound to the LAN interface, ephemeral port. Serves the phone page (GET) and handles photo uploads (POST); phone polls for the next step. | Network.framework (`NWListener`) |
| QR generation | Encodes `http://<lan-ip>:<port>/?token=…`, displayed in the Color Sync window. | CoreImage (`CIQRCodeGenerator`) |
| Phone page | Self-contained HTML/JS/CSS served inline. Shows the current instruction, an `<input capture>` button, uploads the photo, polls for the next step. A dumb capture+upload client — no analysis on the phone. | — |
| Patch-card window | Fullscreen Cocoa window the app throws onto the *target* display showing the patch grid + corner fiducials. | Cocoa |
| `PatchCardAnalyzer` | **On the Mac.** Locates the card in the uploaded photo (corner fiducials → homography → rectify), samples each patch cell (median). All CV in Swift. | Vision / CoreImage / Accelerate |
| `ColorMatcher` | **Pure logic.** Patch samples (per display) → per-display per-channel correction relative to the reference. Unit-testable. | — |
| `DisplayColorState` | Generalization of today's `GammaDimmer`: per display holds 3 channel gains + optional gamma **and** the dim factor; composes them into one `CGSetDisplayTransferByFormula` write. | CoreGraphics |

### Key integration point: composing with existing gamma usage

Color correction, sub-floor dimming, and the non-DDC gamma-follow all write the
**same** per-display gamma table, so they must compose, not overwrite each other.
Refactor `GammaDimmer` → `DisplayColorState`: a single source of truth per display
(channel gains + gamma + dim factor) that produces one combined transfer write.
Owned by `SyncController` and mutated only on its serial `queue`, consistent with
the project's threading invariant (all sync state and all gamma/DDC calls on that
queue; UI callbacks dispatched to main).

Dim-only behavior must remain byte-identical to today's `GammaDimmer` output
(regression-checked) so existing dimming is unaffected.

---

## 3. Measurement & correction algorithm

### Patch card

A grid shown fullscreen on the target display: **100% white, 50% gray, 25% gray,
100% R, 100% G, 100% B**, with four **distinctly-marked corner fiducials** for
location and perspective correction. (Multiple patches in one frame is required —
a single full-screen color would be neutralized by auto-WB; the within-frame
ratios are what survive.)

### Per-display analysis (on the Mac)

1. Detect the 4 corner fiducials → compute homography → rectify the card to a flat
   grid.
2. Sample the **median** color of each patch cell (median rejects glare / dead
   pixels / moiré).
3. Result: measured RGB per patch under that photo's unknown camera transform
   `G_d`.

### Deriving the correction

- **Intrinsic ratios (camera-independent):** within one photo, `R/W`, `G/W`,
  `B/W` and the gray steps cancel `G_d` (measured = `G_d · emitted`, so the ratio
  is `emitted_primary / emitted_white`). These give each display's true per-channel
  response and gamma. Matching them across displays is the reliable core.
- **White point (best-effort):** compare each display's measured-white chroma to
  the reference's and apply a **damped** fraction (auto-WB ate most of it). Damping
  factor is a tunable constant.
- **Output per display:** 3 channel gains + a gamma tweak, **relative to the
  reference** display. The reference itself gets identity (never corrected).

### Applying

`ColorMatcher` emits a `DisplayColorState` per display; `SyncController` composes
it with any active dim factor into one gamma write on its serial queue.

### Reference selection

Built-in display is the reference when present (lid open). In clamshell (no
built-in) the user picks which external is the reference; default is the
first/largest external.

---

## 4. User flow

1. **Settings → "Color Sync (beta)"** opens a Mac window with a QR code and a
   "make sure your phone is on the same Wi-Fi" hint. The server goes live.
2. Phone scans the QR → opens the token-gated page.
3. Page: *"Photograph Display 1 (built-in)."* The app throws the patch card
   fullscreen onto Display 1. User taps → native camera → snaps → uploads.
4. Mac analyzes. On failure (corners not found / too much glare) →
   *"Couldn't read it — try again with less angle, avoid reflections."* On success
   → advance: *"Now Display 2,"* and so on for each display.
5. After the last display: Mac computes corrections, applies them live, and shows a
   **before/after toggle** plus per-display **warm↔cool / brightness** fine-tune
   sliders. User nudges by eye and taps **Save**.
6. Corrections persist per display; the server shuts down.

---

## 5. Persistence, lifecycle, security, caveats

- **Persistence:** per-display correction (3 gains + gamma + manual nudge) saved in
  `UserDefaults`, keyed by the display identity `DDC.swift` already derives.
  Re-applied on launch, wake, and reconnect — same lifecycle as the brightness
  curves. Provide per-display "reset color" and global "reset all."
- **Server lifecycle:** runs only while the Color Sync window is open; stops on
  finish / cancel / window-close. Bound to the LAN interface, ephemeral port.
- **Security:** random per-session token in the QR URL; requests without it get
  404. Surface area is one HTML page + one upload endpoint, alive for minutes.
  Photos are processed in memory and discarded — never written to disk.
- **Caveats (to document in README):**
  - Phone and Mac must share a LAN with no client/AP isolation (guest Wi-Fi often
    blocks peer-to-peer traffic).
  - White-point matching is assisted, not absolute.
  - Color correction composes with sub-floor dimming and the non-DDC gamma-follow;
    all three share the single per-display gamma write.

---

## 6. Test plan

Framework-free, consistent with `run-tests.sh` (each driver compiled with the real
source it checks).

- **`ColorMatcher` (pure):** synthetic patches × synthetic camera transforms `G_d`
  → assert intrinsic ratios recover the display's true response and that `G_d`
  cancels; assert the reference maps to identity.
- **Homography / sampling:** synthetic rendered patch cards at known perspectives →
  assert corner detection + cell sampling return the planted colors.
- **`DisplayColorState` composition:** assert color gains × dim factor produce the
  expected combined transfer formula, and that dim-only output is byte-identical to
  today's `GammaDimmer` (no regression).

---

## 7. Out of scope (v1)

- HTTPS / live `getUserMedia` preview with aiming overlay and auto-capture
  (planned later; needs the on-phone CA-trust flow).
- Side-by-side single-frame capture (rejected for ergonomics).
- Absolute calibration to a color standard.
- Hardware-colorimeter support.

---

## 8. Future enhancements

- HTTPS + live preview path (CA `.mobileconfig` install flow on the phone).
- Optional side-by-side "precise" pass for displays that fit in one frame.
- Richer patch set / full transfer-curve (not just gains) matching.

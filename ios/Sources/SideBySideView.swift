import SwiftUI

/// Debug check: photograph both displays in ONE frame, tap each, and compare.
/// Because it's a single frame, the camera transform is identical for both, so
/// the delta between the two taps is ground truth ("are these actually matched?").
struct SideBySideView: View {
  @ObservedObject var camera: CameraController
  var client: ColorSyncClient? = nil          // when connected, results go to the Mac
  var onClose: () -> Void

  @State private var frozen: CGImage?
  @State private var taps: [CGPoint] = []     // normalized, top-left origin
  @State private var samples: [RGB] = []
  @State private var sentToMac = false

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 16) {
        Text("Side-by-side check").font(.headline)
        Spacer()
        if frozen != nil {
          Button("Retake") { reset() }
        }
        Button { close() } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.title2)
            .foregroundStyle(.secondary)
        }
        .keyboardShortcut(.cancelAction)   // Escape (with an attached keyboard)
        .accessibilityLabel("Close")
      }
      .padding(.horizontal)
      .padding(.top, 8)

      if let img = frozen {
        GeometryReader { geo in
          let rect = fittedRect(imageW: img.width, imageH: img.height, in: geo.size)
          ZStack(alignment: .topLeading) {
            Image(decorative: img, scale: 1, orientation: .up)
              .resizable().scaledToFit()
            ForEach(Array(taps.enumerated()), id: \.offset) { i, p in
              Circle().strokeBorder(i == 0 ? Color.yellow : Color.cyan, lineWidth: 3)
                .frame(width: 26, height: 26)
                .position(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
            }
          }
          .contentShape(Rectangle())
          .onTapGesture(coordinateSpace: .local) { loc in addTap(loc, rect: rect) }
        }
        Text(taps.count < 2 ? "Tap screen \(taps.count == 0 ? "A" : "B") in the photo." : "")
          .foregroundStyle(.secondary).font(.footnote)
        readout
      } else {
        CameraPreviewView(session: camera.session)
        Text("Aim so both screens are in one frame, then Capture.")
          .foregroundStyle(.secondary).font(.footnote)
        Button("Capture") { frozen = camera.lastImage; taps = []; samples = [] }
          .buttonStyle(.borderedProminent).disabled(camera.lastImage == nil)
      }
    }
    .onAppear {
      camera.start()
      camera.enableAutofocus()   // sharp image to tap; safe (single-frame comparison)
      if let client, client.status == .connected { client.send(.beginVerify) }
    }
  }

  @ViewBuilder private var readout: some View {
    if samples.count == 2 {
      let a = samples[0], b = samples[1]
      let m = SideBySideMetric.compare(a, b)   // same calculation the Mac uses
      VStack(spacing: 4) {
        Text(String(format: "A  R %.3f  G %.3f  B %.3f", a.r, a.g, a.b)).foregroundStyle(.yellow)
        Text(String(format: "B  R %.3f  G %.3f  B %.3f", b.r, b.g, b.b)).foregroundStyle(.cyan)
        Text(String(format: "Color Δ %.3f — %@", m.chroma, m.verdict)).bold()
        Text(String(format: "Brightness differs %.3f", m.brightness)).foregroundStyle(.secondary)
        if sentToMac {
          Text("Sent to Mac — see the Color Sync window too.")
            .font(.footnote).foregroundStyle(.green)
        }
      }
      .font(.system(.body, design: .monospaced))
      .padding(.bottom, 8)
    }
  }

  private func addTap(_ loc: CGPoint, rect: CGRect) {
    guard let img = frozen, taps.count < 2, rect.contains(loc) else { return }
    let np = CGPoint(x: (loc.x - rect.minX) / rect.width, y: (loc.y - rect.minY) / rect.height)
    taps.append(np)
    samples.append(FieldSampler.average(image: img, atNormalized: np))
    if samples.count == 2, let client, client.status == .connected {
      let a = samples[0], b = samples[1]
      client.send(.sideBySide(aR: a.r, aG: a.g, aB: a.b, bR: b.r, bG: b.g, bB: b.b))
      sentToMac = true
    }
  }

  private func reset() { frozen = nil; taps = []; samples = []; sentToMac = false }

  private func close() { camera.stop(); onClose() }

  private func fittedRect(imageW: Int, imageH: Int, in size: CGSize) -> CGRect {
    let ar = CGFloat(imageW) / CGFloat(imageH)
    let car = size.width / size.height
    var w = size.width, h = size.height
    if ar > car { h = size.width / ar } else { w = size.height * ar }
    return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
  }
}

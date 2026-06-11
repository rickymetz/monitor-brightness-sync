import SwiftUI

struct DoneView: View {
  var onVerify: () -> Void = {}
  var onSampleAmbient: () -> Void = {}
  var ambientStatus: String? = nil
  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
      Text("Colors matched").font(.title2)
      Text("You can put your phone down.").foregroundStyle(.secondary)
      Button("Verify side-by-side", action: onVerify)
        .buttonStyle(.bordered)
      Divider().padding(.vertical, 4)
      Button("Match to room lighting", action: onSampleAmbient)
        .buttonStyle(.bordered)
      Text("Optional: bias the match toward your room's color temperature.")
        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if let ambientStatus {
        Text(ambientStatus).font(.caption).foregroundStyle(.blue).multilineTextAlignment(.center)
      }
    }.padding()
  }
}

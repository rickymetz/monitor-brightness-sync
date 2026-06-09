import SwiftUI

struct PairingView: View {
  @ObservedObject var client: ColorSyncClient
  @State private var error: String?

  var body: some View {
    VStack(spacing: 16) {
      Text("Scan the code on your Mac").font(.headline)
      QRScannerView { code in
        guard let payload = PairingPayload.parse(code) else {
          error = "That QR code isn't a Color Sync pairing code."
          return
        }
        client.connect(payload)
      }
      .frame(height: 320)
      .clipShape(RoundedRectangle(cornerRadius: 16))
      if let error { Text(error).foregroundStyle(.red).font(.footnote) }
    }
    .padding()
  }
}
